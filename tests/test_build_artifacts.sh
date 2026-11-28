#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Regression test for the build_artifacts input. Each lane's build job
# validates the input, downloads the named raw artefacts of this run
# into a staging directory and places them in the checkout, then
# unpacks each packed entry (one with an 'id') into the checkout with
# build-artifact-action, all before the images build. The test checks
# the three lanes define the input and the steps identically and in
# that order, and wires the unpack steps to same-run, add-only use of
# the action. It then extracts the validate, place and prepare step
# scripts and runs them as GitHub runs a 'shell: bash' step. A stand-in for actions/download-artifact fills the staging
# directory as that action does: the first name by name, into first/,
# and two or more names by pattern, into set/, where a single match
# unpacks straight into set/ and several into one directory per name.
#
# Usage: tests/test_build_artifacts.sh
# Needs bash, jq, coreutils and yq (either the Go or the Python
# implementation).

set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT

failures=0
lanes=(build-test merge build-test-release)
slots=(1 2 3 4)
step_ids=(build-artifacts download-build-artifacts
  download-build-artifacts-set place-build-artifacts
  prepare-packed-build-artifacts)
for slot in "${slots[@]}"; do
  step_ids+=("unpack-build-artifact-${slot}")
done

fail() {
  echo "FAIL: $*"
  failures=$((failures + 1))
}

# build_step LANE ID FIELD: one field of a build job step, by step id
build_step() {
  yq -r ".jobs.build.steps[] | select(.id == \"$2\") | .$3" \
    "${root}/.github/workflows/$1.yaml"
}

# input_block LANE: the build_artifacts input definition, verbatim
input_block() {
  sed -n '/^      build_artifacts:$/,/^        default:/p' \
    "${root}/.github/workflows/$1.yaml"
}

# --- Wiring: the same input and steps in every lane ---------------------

for lane in "${lanes[@]}"; do
  if [ -z "$(input_block "${lane}")" ]; then
    fail "${lane}: no build_artifacts input"
  fi
  for id in "${step_ids[@]}"; do
    if ! build_step "${lane}" "${id}" name | grep -qv '^null$'; then
      fail "${lane}: no '${id}' step in the build job"
    fi
  done
done
for lane in merge build-test-release; do
  if [ "$(input_block "${lane}")" != "$(input_block build-test)" ]; then
    fail "${lane}: build_artifacts input differs from build-test"
  fi
  for id in "${step_ids[@]}"; do
    for field in if run uses with env '["continue-on-error"]'; do
      if [ "$(build_step "${lane}" "${id}" "${field}")" != \
        "$(build_step build-test "${id}" "${field}")" ]; then
        fail "${lane}: step '${id}' ${field} differs from build-test"
      fi
    done
  done
done
echo "ok: the three lanes define build_artifacts alike"

# shellcheck disable=SC2016  # literal workflow expressions
expected_if="inputs.build_artifacts != '' && inputs.build_artifacts != '[]'"
for lane in "${lanes[@]}"; do
  actual=$(build_step "${lane}" build-artifacts if)
  if [ "${actual}" != "${expected_if}" ]; then
    fail "${lane}: the validate step runs on '${actual}'," \
      "so an empty or '[]' input would not skip it"
  fi
  # Same-run artefacts only: each download names its artefacts and a
  # staging path outside the checkout, and nothing else
  for spec in download-build-artifacts:name:first \
    download-build-artifacts-set:pattern:set; do
    IFS=: read -r id key dir <<< "${spec}"
    keys=$(build_step "${lane}" "${id}" 'with | keys | sort | join(",")')
    if [ "${keys}" != "${key},path" ] && [ "${keys}" != "path,${key}" ]
    then
      fail "${lane}: step '${id}' takes '${keys}', expected only" \
        "path and ${key} (no run-id, no github-token)"
    fi
    # shellcheck disable=SC2016
    if [ "$(build_step "${lane}" "${id}" with.path)" != \
      "\${{ runner.temp }}/build-artifacts/${dir}" ]; then
      fail "${lane}: step '${id}' does not stage under runner.temp"
    fi
    uses=$(build_step "${lane}" "${id}" uses)
    if [[ ! "${uses}" =~ ^actions/download-artifact@[0-9a-f]{40}$ ]]; then
      fail "${lane}: step '${id}' is not pinned by SHA ('${uses}')"
    fi
  done
  # A missing first artefact must reach the place step's error
  if [ "$(build_step "${lane}" download-build-artifacts \
    '["continue-on-error"]')" != true ]; then
    fail "${lane}: the by-name download does not continue on error"
  fi
  pinned=$(grep -o 'actions/download-artifact@[0-9a-f]\{40\}' \
    "${root}/.github/workflows/${lane}.yaml" | sort -u)
  if [ "$(wc -l <<< "${pinned}")" -ne 1 ]; then
    fail "${lane}: download-artifact is pinned at more than one SHA"
  fi
  # Order: after every checkout, before the build
  order=$(yq -r '.jobs.build.steps | to_entries[]
    | [.key, (.value.id // ""), (.value.name // "")] | @tsv' \
    "${root}/.github/workflows/${lane}.yaml")
  index() { awk -F'\t' -v k="$1" -v c="$2" '$c == k { print $1 }' \
    <<< "${order}"; }
  last_checkout=$(awk -F'\t' '$3 ~ /^Checkout( |$)/ { n = $1 } END { print n }' \
    <<< "${order}")
  validate=$(index build-artifacts 2)
  download=$(index download-build-artifacts 2)
  download_set=$(index download-build-artifacts-set 2)
  place=$(index place-build-artifacts 2)
  prepare=$(index prepare-packed-build-artifacts 2)
  build=$(index build 2)
  seen="${last_checkout} ${validate} ${download} ${download_set} ${place}"
  seen+=" ${prepare}"
  for slot in "${slots[@]}"; do
    seen+=" $(index "unpack-build-artifact-${slot}" 2)"
  done
  seen+=" ${build}"
  if [ "$(tr ' ' '\n' <<< "${seen}" | sort -n | paste -sd ' ')" != \
    "${seen}" ] || [ "$(wc -w <<< "${seen}")" -ne 11 ]; then
    fail "${lane}: expected checkout < validate < download <" \
      "download set < place < prepare < unpack 1..4 < build," \
      "got ${seen}"
  fi
  # Packed entries: one unpack step per slot, each taking its slot's
  # validated fields, adding to the checkout (overlay) and passing no
  # run-id or token, so only this run's artefacts qualify
  for slot in "${slots[@]}"; do
    id="unpack-build-artifact-${slot}"
    out="steps.build-artifacts.outputs.packed_${slot}"
    uses=$(build_step "${lane}" "${id}" uses)
    if [[ ! "${uses}" =~ ^lfreleng-actions/build-artifact-action@[0-9a-f]{40}$ ]]
    then
      fail "${lane}: step '${id}' is not pinned by SHA ('${uses}')"
    fi
    keys=$(build_step "${lane}" "${id}" 'with | keys | sort | join(",")')
    if [ "${keys}" != \
      'artifact-id,artifact-name,destination,expected-digest,mode,overlay' ]
    then
      fail "${lane}: step '${id}' takes '${keys}' (no run-id or token)"
    fi
    if [ "$(build_step "${lane}" "${id}" with.mode)" != unpack ] ||
      [ "$(build_step "${lane}" "${id}" with.overlay)" != true ]; then
      fail "${lane}: step '${id}' must unpack with overlay 'true'," \
        "so a packed artefact adds to the checkout and replaces nothing"
    fi
    if [ "$(build_step "${lane}" "${id}" if)" != "${out}_name != ''" ]; then
      fail "${lane}: step '${id}' does not run on its slot's name"
    fi
    for spec in artifact-name:name artifact-id:id \
      expected-digest:digest destination:destination; do
      if [ "$(build_step "${lane}" "${id}" "with.${spec%%:*}")" != \
        "\${{ ${out}_${spec#*:} }}" ]; then
        fail "${lane}: step '${id}' ${spec%%:*} is not its slot's" \
          "${spec#*:}"
      fi
    done
  done
  # shellcheck disable=SC2016
  if [ "$(build_step "${lane}" prepare-packed-build-artifacts if)" != \
    "steps.build-artifacts.outputs.packed_1_name != ''" ]; then
    fail "${lane}: the prepare step does not run on the first slot"
  fi
  # Only the build job reads build artefacts
  others=$(yq -r '[.jobs | to_entries[] | select(.key != "build")
    | .value.steps[]?.uses // ""
    | select(test("build-artifact-action"))] | length' \
    "${root}/.github/workflows/${lane}.yaml")
  if [ "${others}" != 0 ]; then
    fail "${lane}: a job other than build uses build-artifact-action"
  fi
  if [ "$(yq -r '.jobs.build.permissions.actions // "none"' \
    "${root}/.github/workflows/${lane}.yaml")" != 'none' ]; then
    fail "${lane}: the build job gained an actions permission"
  fi
done
pinned=$(grep -ho 'lfreleng-actions/build-artifact-action@[0-9a-f]\{40\}' \
  "${root}"/.github/workflows/*.yaml | sort -u)
if [ "$(wc -l <<< "${pinned}")" -ne 1 ]; then
  fail "build-artifact-action is pinned at more than one SHA"
fi
echo "ok: the steps run after the checkout and before the build"

# --- Behaviour: the step scripts ----------------------------------------

case_dir="${work}/case"
store="${work}/store"

# fresh: a checkout holding a Dockerfile and a script under proj/,
# and an empty artefact store
fresh() {
  rm -rf "${case_dir}" "${store}"
  mkdir -p "${case_dir}/ws/proj/scripts" "${case_dir}/tmp" "${store}"
  echo 'FROM scratch' > "${case_dir}/ws/proj/Dockerfile"
  echo 'echo hi' > "${case_dir}/ws/proj/scripts/run.sh"
  echo 'outside' > "${case_dir}/outside.txt"
}

# artefact NAME RELPATH CONTENT: an artefact uploaded earlier in the run
artefact() {
  local file="${store}/$1/$2"
  mkdir -p "${file%/*}"
  printf '%s\n' "$3" > "${file}"
}

# download FIRST PATTERN: what the two download-artifact steps leave in
# the staging directory, FIRST by name and PATTERN ('{a,b}') when set;
# sets outcome to the by-name step's outcome
download() {
  local staging="${case_dir}/tmp/build-artifacts" requested name
  local -a matched=()
  if [ -d "${store}/$1" ]; then
    mkdir -p "${staging}/first"
    cp -R "${store}/$1/." "${staging}/first/"
    outcome=success
  else
    outcome=failure
  fi
  if [ -z "$2" ]; then
    return 0
  fi
  staging+=/set
  requested="${2#\{}"
  requested="${requested%\}}"
  IFS=, read -r -a wanted <<< "${requested}"
  for name in "${wanted[@]}"; do
    if [ -d "${store}/${name}" ]; then
      matched+=("${name}")
    fi
  done
  if [ "${#matched[@]}" -eq 1 ]; then
    mkdir -p "${staging}"
    cp -R "${store}/${matched[0]}/." "${staging}/"
  else
    for name in "${matched[@]}"; do
      mkdir -p "${staging}/${name}"
      cp -R "${store}/${name}/." "${staging}/${name}/"
    done
  fi
}

# run_step SCRIPT SPEC: one step, as GitHub runs it, from the workspace
run_step() {
  (cd "${case_dir}/ws" &&
    env -i PATH="${PATH}" HOME="${work}" \
      GITHUB_OUTPUT="${case_dir}/output" RUNNER_TEMP="${case_dir}/tmp" \
      BUILD_ARTIFACTS="$2" PATH_PREFIX="${prefix}" \
      FIRST_OUTCOME="${outcome}" DESTINATIONS="${destinations}" \
      bash --noprofile --norc -eo pipefail "$1")
}

# tree: every file in the checkout and its content
tree() {
  (cd "${case_dir}/ws" && find . -type f -print0 | sort -z |
    xargs -0 -r grep -H '')
}

# run_case DESCRIPTION EXPECTED SPEC [PATTERN] [CHECK ...]
# EXPECTED is 'noop' (nothing downloads), 'ok', 'error:TEXT' where
# TEXT must appear on an ::error:: line and the checkout must be left
# as it was, or 'fail:TEXT', the same once raw placement has run.
# PATTERN is the download pattern an 'ok' case expects, empty for a
# single name. Each CHECK is FILE=CONTENT, a file under the workspace
# it must hold afterwards; dir:DIR, a directory it must hold; or
# out:KEY=VALUE, a line the validate step must output. When the
# validate step hands out a packed slot, the prepare step runs with
# the slots' destinations, as the workflow passes them.
run_case() {
  local description="$1" expected="$2" spec="$3" pattern="${4:-}"
  local status=0 first actual before after check
  shift 4 2> /dev/null || shift $#
  : > "${case_dir}/output"
  rm -rf "${case_dir}/tmp/build-artifacts"
  outcome=''
  before=$(tree)
  run_step "${work}/validate.sh" "${spec}" > "${case_dir}/log" 2>&1 ||
    status=$?
  first=$(sed -n 's/^first=//p' "${case_dir}/output")
  actual=$(sed -n 's/^pattern=//p' "${case_dir}/output")
  if [ "${status}" -eq 0 ] && [ -n "${first}" ]; then
    download "${first}" "${actual}"
    run_step "${work}/place.sh" '' >> "${case_dir}/log" 2>&1 ||
      status=$?
  fi
  destinations=$(sed -n 's/^packed_[1-4]_destination=//p' \
    "${case_dir}/output" | paste -sd ' ')
  if [ "${status}" -eq 0 ] && [ -n "${destinations}" ]; then
    run_step "${work}/prepare.sh" '' >> "${case_dir}/log" 2>&1 ||
      status=$?
  fi
  destinations=''
  after=$(tree)
  check=ok
  case "${expected}" in
    noop)
      if [ "${status}" -ne 0 ] || [ -n "${first}" ] ||
        [ -n "${actual}" ] || [ "${before}" != "${after}" ]; then
        check=bad
      fi
      ;;
    ok)
      if [ "${status}" -ne 0 ] || [ "${actual}" != "${pattern}" ]; then
        check=bad
      fi
      for file in "$@"; do
        case "${file}" in
          out:*)
            grep -qxF -- "${file#out:}" "${case_dir}/output" ||
              check=bad
            ;;
          dir:*)
            [ -d "${case_dir}/ws/${file#dir:}" ] || check=bad
            ;;
          *)
            if [ "$(cat "${case_dir}/ws/${file%%=*}" 2> /dev/null)" != \
              "${file#*=}" ]; then
              check=bad
            fi
            ;;
        esac
      done
      ;;
    error:* | fail:*)
      if [ "${status}" -eq 0 ] ||
        ! grep '^::error::' "${case_dir}/log" |
        grep -qF -- "${expected#*:}" ||
        { [ "${expected%%:*}" = error ] && [ "${before}" != "${after}" ]; }
      then
        check=bad
      fi
      ;;
  esac
  if [ "${check}" = ok ]; then
    echo "ok: ${lane}: ${description}"
  else
    fail "${lane}: ${description}: expected ${expected}," \
      "got exit ${status}, first '${first}', pattern '${actual}'"
    sed 's/^/  | /' "${case_dir}/log"
  fi
}

outcome=''
destinations=''
prefix=proj
digest=$(printf '0123456789abcdef%.0s' 1 2 3 4)
same_run='uploaded earlier in the same workflow run'
for lane in "${lanes[@]}"; do
  build_step "${lane}" build-artifacts run > "${work}/validate.sh"
  build_step "${lane}" place-build-artifacts run > "${work}/place.sh"
  build_step "${lane}" prepare-packed-build-artifacts run \
    > "${work}/prepare.sh"

  # No-ops
  fresh
  run_case 'an empty input downloads nothing' noop ''
  run_case "'[]' downloads nothing" noop '[]'
  run_case "a spaced '[ ]' downloads nothing" noop ' [ ] '

  # Placement
  fresh
  artefact app-jars app/target/app-1.0.jar jar
  run_case 'the default path places at path_prefix' ok \
    '[{"name": "app-jars"}]' '' \
    'proj/app/target/app-1.0.jar=jar'
  fresh
  artefact app-jars app-1.0.jar jar
  run_case 'a path places below path_prefix' ok \
    '[{"name": "app-jars", "path": "app/target"}]' '' \
    'proj/app/target/app-1.0.jar=jar'
  fresh
  artefact wheels dist/pkg.whl wheel
  artefact jars target/app.jar jar
  run_case 'several artefacts each place at their path' ok \
    '[{"name": "wheels", "path": "py"}, {"name": "jars", "path": ""}]' \
    '{jars,wheels}' 'proj/py/dist/pkg.whl=wheel' 'proj/target/app.jar=jar'
  fresh
  artefact jars app.jar jar
  run_case 'one artefact may place at two paths' ok \
    '[{"name": "jars", "path": "a"}, {"name": "jars", "path": "b"}]' \
    '' 'proj/a/app.jar=jar' 'proj/b/app.jar=jar'

  # Malformed input
  fresh
  run_case 'input that is not JSON fails' \
    'error:must be a JSON array' 'not json'
  run_case 'two JSON values fail' \
    'error:must be a JSON array' '[] []'
  run_case 'an object rather than an array fails' \
    'error:must be a JSON array' '{"name": "a"}'
  run_case 'an entry that is not an object fails' \
    'error:build_artifacts[0] "a": each entry must be an object' '["a"]'
  run_case 'an entry without a name fails' \
    "error:build_artifacts[1] {\"path\":\"x\"}: 'name' must be" \
    '[{"name": "a"}, {"path": "x"}]'
  run_case 'an empty name fails' \
    "error:build_artifacts[0] {\"name\":\"\"}: 'name' must be" \
    '[{"name": ""}]'
  run_case 'a name that is not a string fails' \
    "error:build_artifacts[0] {\"name\":5}: 'name' must be" \
    '[{"name": 5}]'
  run_case 'a name with a slash fails' \
    "error:build_artifacts[0] {\"name\":\"a/b\"}: 'name' may only" \
    '[{"name": "a/b"}]'
  run_case 'a name with a glob character fails' \
    "error:build_artifacts[0] {\"name\":\"a*\"}: 'name' may only" \
    '[{"name": "a*"}]'
  run_case 'a name with a trailing newline fails' \
    "error:build_artifacts[0] {\"name\":\"a\\n\"}: 'name' may only" \
    '[{"name": "a\n"}]'
  run_case "a name of '..' fails" \
    "error:build_artifacts[0] {\"name\":\"..\"}: 'name' may only" \
    '[{"name": ".."}]'
  run_case 'a path that is not a string fails' \
    "error:build_artifacts[0] {\"name\":\"a\",\"path\":5}: 'path'" \
    '[{"name": "a", "path": 5}]'
  run_case 'an absolute path fails' \
    "error:build_artifacts[0] {\"name\":\"a\",\"path\":\"/tmp\"}: 'path'" \
    '[{"name": "a", "path": "/tmp"}]'
  run_case "a leading '..' segment fails" \
    "error:build_artifacts[0] {\"name\":\"a\",\"path\":\"../x\"}: 'path'" \
    '[{"name": "a", "path": "../x"}]'
  run_case "an inner '..' segment fails, even inside path_prefix" \
    "error:build_artifacts[0] {\"name\":\"a\",\"path\":\"x/../y\"}" \
    '[{"name": "a", "path": "x/../y"}]'
  run_case 'a path with a control character fails' \
    "error:'path' must not contain control characters" \
    '[{"name": "a", "path": "x\ny"}]'
  ln -s "${case_dir}" "${case_dir}/ws/proj/escape"
  run_case 'a path through a symlink out of path_prefix fails' \
    "error:build_artifacts[0] {\"name\":\"a\",\"path\":\"escape\"}" \
    '[{"name": "a", "path": "escape"}]'

  # Missing artefacts
  fresh
  run_case 'a missing artefact fails, naming the same-run rule' \
    "error:entry 'jars': no artefact of that name exists in this run" \
    '[{"name": "jars"}]'
  run_case 'the missing-artefact error names needs:' \
    "error:must 'needs:' the job that uploads them" \
    '[{"name": "jars"}]'
  artefact jars app.jar jar
  artefact wheels pkg.whl wheel
  run_case 'one missing of three fails, naming it' \
    "error:entry 'docs': no artefact of that name exists" \
    '[{"name": "jars"}, {"name": "docs"}, {"name": "wheels"}]'
  run_case 'a missing name after the first fails, naming it' \
    "error:entry 'zzz': no artefact of that name exists" \
    '[{"name": "jars"}, {"name": "wheels"}, {"name": "zzz"}]'
  fresh
  artefact app app/target/app.jar jar
  artefact lib lib/target/lib.jar lib
  run_case 'module directories survive several artefacts' ok \
    '[{"name": "app"}, {"name": "lib"}]' '{app,lib}' \
    'proj/app/target/app.jar=jar' 'proj/lib/target/lib.jar=lib'
  # A lone match unpacks without its name, so these directories must
  # not pass for the artefacts they are named after
  fresh
  artefact app app/target/app.jar jar
  artefact app lib/target/lib.jar lib
  run_case 'directories named like the others do not stand in for them' \
    "error:entry 'lib': no artefact of that name exists in this run" \
    '[{"name": "app"}, {"name": "lib"}]'
  fresh
  artefact lib app/target/app.jar jar
  artefact lib lib/target/lib.jar lib
  run_case 'nor when the artefact present is not the first' \
    "error:entry 'app': no artefact of that name exists in this run" \
    '[{"name": "app"}, {"name": "lib"}]'
  fresh
  artefact jars app.jar jar
  run_case 'one found of two still fails' \
    "error:${same_run}" \
    '[{"name": "jars"}, {"name": "docs"}]'

  # Artefacts never replace the checkout
  fresh
  artefact evil Dockerfile 'FROM evil'
  run_case 'an artefact replacing the Dockerfile fails' \
    "error:build_artifacts[0] (name 'evil', path '.'): 'proj/Dockerfile'" \
    '[{"name": "evil"}]'
  fresh
  artefact evil run.sh 'rm -rf /'
  artefact good app.jar jar
  run_case 'an artefact replacing a script fails, placing nothing' \
    "error:build_artifacts[1] (name 'evil', path 'scripts')" \
    '[{"name": "good"}, {"name": "evil", "path": "scripts"}]'
  fresh
  artefact evil Dockerfile/x 'nested'
  run_case 'an artefact directory over a checkout file fails' \
    "error:would overwrite 'proj/Dockerfile' from the checkout" \
    '[{"name": "evil"}]'
  fresh
  artefact evil $'Dockerfile\n' 'FROM evil'
  run_case 'a name with a trailing newline cannot replace the Dockerfile' \
    ok '[{"name": "evil"}]' '' 'proj/Dockerfile=FROM scratch' \
    $'proj/Dockerfile\n=FROM evil'
  fresh
  artefact evil $'scripts\n/run.sh' 'rm -rf /'
  run_case 'a directory with a trailing newline cannot replace a script' \
    ok '[{"name": "evil"}]' '' 'proj/scripts/run.sh=echo hi' \
    $'proj/scripts\n/run.sh=rm -rf /'
  fresh
  artefact a app.jar one
  artefact b app.jar two
  run_case 'two artefacts placing the same file fail' \
    "error:build_artifacts[1] (name 'b', path '.'): 'proj/app.jar'" \
    '[{"name": "a"}, {"name": "b"}]'
  fresh
  artefact a lib 'a file'
  artefact b lib/x.jar 'below it'
  run_case 'one artefact file under another fails' \
    "error:collides with a file another build_artifacts entry places" \
    '[{"name": "a"}, {"name": "b"}]'
  fresh
  artefact a link.jar jar
  ln -sf "${case_dir}/outside.txt" "${store}/a/link.jar"
  run_case 'a symlink in an artefact fails' \
    "error:'link.jar' is not a regular file" '[{"name": "a"}]'
  fresh
  ln -s "${case_dir}" "${case_dir}/ws/proj/escape"
  artefact a escape/x.jar jar
  run_case 'a file through a checkout symlink out of path_prefix fails' \
    'error:resolves outside path_prefix' '[{"name": "a"}]'

  # Packed entries: an 'id' hands the entry to an unpack slot
  fresh
  run_case 'an entry with an id fills a slot and downloads nothing raw' \
    ok "[{\"name\": \"jars\", \"id\": \"42\", \"digest\": \"${digest}\"}]" \
    '' out:first= out:packed_1_name=jars out:packed_1_id=42 \
    "out:packed_1_digest=${digest}" out:packed_1_destination=proj
  run_case 'a numeric id and a path give the slot its destination' ok \
    '[{"name": "jars", "id": 7, "path": "app/target"}]' '' \
    out:packed_1_id=7 out:packed_1_digest= \
    out:packed_1_destination=proj/app/target dir:proj/app/target
  fresh
  artefact wheels pkg.whl wheel
  run_case 'raw and packed entries mix, each taking its own path' ok \
    '[{"name": "jars", "id": 9}, {"name": "wheels", "path": "py"}]' '' \
    out:first=wheels out:packed_1_name=jars out:packed_1_destination=proj \
    proj/py/pkg.whl=wheel
  fresh
  artefact jars app.jar jar
  run_case 'an empty id or digest reads the entry as raw' ok \
    '[{"name": "jars", "id": "", "digest": ""}]' '' out:first=jars \
    proj/app.jar=jar
  fresh
  artefact jars app.jar jar
  run_case 'a null id reads the entry as raw' ok \
    '[{"name": "jars", "id": null}]' '' out:first=jars proj/app.jar=jar
  fresh
  run_case 'one packed artefact may unpack at two paths' ok \
    '[{"name": "jars", "id": 1, "path": "a"},
      {"name": "jars", "id": 1, "path": "b"}]' '' \
    out:packed_1_destination=proj/a out:packed_2_destination=proj/b \
    dir:proj/a dir:proj/b
  run_case 'four packed entries fill the four slots' ok \
    '[{"name": "a", "id": 1}, {"name": "b", "id": 2},
      {"name": "c", "id": 3}, {"name": "d", "id": 4}]' '' \
    out:packed_4_name=d out:packed_4_id=4
  run_case 'a fifth packed entry fails' \
    "error:at most 4 entries may carry an 'id', found 5" \
    '[{"name": "a", "id": 1}, {"name": "b", "id": 2},
      {"name": "c", "id": 3}, {"name": "d", "id": 4},
      {"name": "e", "id": 5}]'
  run_case 'an id that is not a number fails' \
    "error:build_artifacts[0] {\"name\":\"a\",\"id\":\"x1\"}: 'id'" \
    '[{"name": "a", "id": "x1"}]'
  run_case 'an id of zero fails' "error:'id' must be a positive integer" \
    '[{"name": "a", "id": 0}]'
  run_case 'a fractional id fails' "error:'id' must be a positive integer" \
    '[{"name": "a", "id": 1.5}]'
  run_case 'a boolean id fails' "error:'id' must be a positive integer" \
    '[{"name": "a", "id": true}]'
  run_case 'an upper-case digest fails' "error:'digest' must be a SHA-256" \
    "[{\"name\": \"a\", \"id\": 1, \"digest\": \"${digest^^}\"}]"
  run_case 'a short digest fails' "error:'digest' must be a SHA-256" \
    '[{"name": "a", "id": 1, "digest": "abc"}]'
  run_case 'a digest without an id fails' "error:'digest' needs an 'id'" \
    "[{\"name\": \"a\", \"digest\": \"${digest}\"}]"
  artefact a app.jar jar
  run_case 'one name both with and without an id fails, before download' \
    "error:'a' appears both with and without an 'id'" \
    '[{"name": "a"}, {"name": "a", "id": 1, "path": "x"}]'
  run_case 'a packed path outside the action grammar fails' \
    "error:unpacks into 'proj/my dir', which must be" \
    '[{"name": "a", "id": 1, "path": "my dir"}]'
  run_case 'a packed path below a checkout file fails' \
    "error:'proj/Dockerfile' in the checkout is not a directory" \
    '[{"name": "a", "id": 1, "path": "Dockerfile/x"}]'
  ln -s scripts "${case_dir}/ws/proj/link"
  run_case 'a packed path through a symlink in the checkout fails' \
    "error:'proj/link' in the checkout is not a directory" \
    '[{"name": "a", "id": 1, "path": "link"}]'
  fresh
  artefact r out 'a file'
  run_case 'a raw file in the way of a packed destination fails' \
    "fail:cannot create 'proj/out' for a packed artefact" \
    '[{"name": "r"}, {"name": "p", "id": 1, "path": "out"}]'

  # path_prefix '.'
  prefix=.
  fresh
  artefact jars target/app.jar jar
  run_case "path_prefix '.' places at the workspace root" ok \
    '[{"name": "jars"}]' '' 'target/app.jar=jar'
  run_case "path_prefix '.' unpacks a packed entry at the workspace root" \
    ok '[{"name": "jars", "id": 3}]' '' out:packed_1_destination=.
  prefix=proj
done

if [ "${failures}" -gt 0 ]; then
  echo "${failures} failure(s)"
  exit 1
fi
echo "All build_artifacts cases passed"
