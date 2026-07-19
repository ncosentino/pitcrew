#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "${ROOT}/manager/reconciliation.sh"
. "${ROOT}/manager/observability.sh"

TEMP_DIRECTORY=$(mktemp -d)
trap 'rm -rf "${TEMP_DIRECTORY}"' EXIT
ASSERTIONS=0

fail() {
    echo "ERROR: $1" >&2
    exit 1
}

assert_equals() {
    expected="$1"
    actual="$2"
    message="$3"
    ASSERTIONS=$((ASSERTIONS + 1))
    [ "${expected}" = "${actual}" ] || fail "${message} Expected '${expected}', got '${actual}'."
}

assert_true() {
    message="$1"
    shift
    ASSERTIONS=$((ASSERTIONS + 1))
    "$@" || fail "${message}"
}

assert_false() {
    message="$1"
    shift
    ASSERTIONS=$((ASSERTIONS + 1))
    if "$@"; then
        fail "${message}"
    fi
}

contains_access_token_field() {
    jq -e '[.. | objects | has("accessToken")] | any' "$1" >/dev/null
}

contains_runner_identity_field() {
    jq -e '[.slots[] | has("tag") or has("runnerName")] | any' "$1" >/dev/null
}

write_repo_state() {
    path="$1"
    generation="$2"
    repositories_json="$3"
    cat > "${path}" <<EOF
{
  "schemaVersion": 1,
  "generation": ${generation},
  "scope": "repo",
  "repositories": ${repositories_json},
  "replicas": null
}
EOF
}

state_five="${TEMP_DIRECTORY}/five.json"
state_six="${TEMP_DIRECTORY}/six.json"
slots_five="${TEMP_DIRECTORY}/five.tsv"
slots_six="${TEMP_DIRECTORY}/six.tsv"
write_repo_state \
    "${state_five}" \
    4 \
    '[{"url":"https://github.com/example/project","workers":5}]'
write_repo_state \
    "${state_six}" \
    5 \
    '[{"url":"https://github.com/example/project","workers":6}]'

assert_true "Five-worker desired state was rejected." desired_state_is_valid "${state_five}"
assert_true "Six-worker desired state was rejected." desired_state_is_valid "${state_six}"
render_desired_slots "${state_five}" "${slots_five}"
render_desired_slots "${state_six}" "${slots_six}"
assert_equals "5" "$(wc -l < "${slots_five}" | tr -d ' ')" "Five workers did not render five stable keys."
assert_equals "6" "$(wc -l < "${slots_six}" | tr -d ' ')" "Six workers did not render six stable keys."
assert_equals "1" "$(comm -13 "${slots_five}" "${slots_six}" | wc -l | tr -d ' ')" "Scaling from five to six did not add exactly one slot."
assert_equals "0" "$(comm -23 "${slots_five}" "${slots_six}" | wc -l | tr -d ' ')" "Scaling from five to six removed an existing slot."
assert_true \
    "Scaling from six to five did not remove the highest ordinal." \
    grep -Eq '^repo-[0-9a-f]{16}-000006	' "${slots_six}"
removed_key=$(comm -23 "${slots_six}" "${slots_five}" | cut -f1)
case "${removed_key}" in
    *-000006) ;;
    *) fail "Scaling from six to five did not drain ordinal six." ;;
esac
ASSERTIONS=$((ASSERTIONS + 1))

active_keys="${TEMP_DIRECTORY}/active-keys.txt"
undesired_keys="${TEMP_DIRECTORY}/undesired-keys.txt"
cut -f1 "${slots_six}" > "${active_keys}"
printf '%s\n' 'orphan-slot' >> "${active_keys}"
write_undesired_slot_keys "${slots_five}" "${active_keys}" "${undesired_keys}"
assert_equals "2" "$(wc -l < "${undesired_keys}" | tr -d ' ')" "Linear desired-key lookup returned the wrong drain set."
assert_true "Linear desired-key lookup missed the removed ordinal." grep -Fqx "${removed_key}" "${undesired_keys}"
assert_true "Linear desired-key lookup missed an orphaned slot." grep -Fqx 'orphan-slot' "${undesired_keys}"

multi_initial="${TEMP_DIRECTORY}/multi-initial.json"
multi_changed="${TEMP_DIRECTORY}/multi-changed.json"
multi_removed="${TEMP_DIRECTORY}/multi-removed.json"
multi_initial_slots="${TEMP_DIRECTORY}/multi-initial.tsv"
multi_changed_slots="${TEMP_DIRECTORY}/multi-changed.tsv"
multi_removed_slots="${TEMP_DIRECTORY}/multi-removed.tsv"
write_repo_state \
    "${multi_initial}" \
    6 \
    '[{"url":"https://github.com/example/alpha","workers":2},{"url":"https://github.com/example/beta","workers":2}]'
write_repo_state \
    "${multi_changed}" \
    7 \
    '[{"url":"https://github.com/example/alpha","workers":3},{"url":"https://github.com/example/beta","workers":1}]'
write_repo_state \
    "${multi_removed}" \
    8 \
    '[{"url":"https://github.com/example/alpha","workers":3}]'
render_desired_slots "${multi_initial}" "${multi_initial_slots}"
render_desired_slots "${multi_changed}" "${multi_changed_slots}"
render_desired_slots "${multi_removed}" "${multi_removed_slots}"
assert_equals "1" "$(comm -13 "${multi_initial_slots}" "${multi_changed_slots}" | grep -c '	alpha-' || true)" "Increasing one repository did not add only its slot."
assert_equals "1" "$(comm -23 "${multi_initial_slots}" "${multi_changed_slots}" | grep -c '	beta-' || true)" "Decreasing one repository did not drain only its slot."
assert_equals "1" "$(comm -23 "${multi_changed_slots}" "${multi_removed_slots}" | grep -c 'https://github.com/example/beta' || true)" "Removing a repository did not drain only that repository's remaining slot."
assert_equals "0" "$(comm -23 "${multi_changed_slots}" "${multi_removed_slots}" | grep -c 'https://github.com/example/alpha' || true)" "Removing a repository drained another repository's slot."

five_hash=$(desired_state_hash "${state_five}")
assert_equals "unchanged" "$(classify_desired_state "${state_five}" 4 "${five_hash}")" "Identical state was not idempotent."
assert_equals "new" "$(classify_desired_state "${state_six}" 4 "${five_hash}")" "Higher-generation state was not accepted as new."

stale_state="${TEMP_DIRECTORY}/stale.json"
write_repo_state \
    "${stale_state}" \
    3 \
    '[{"url":"https://github.com/example/project","workers":5}]'
assert_equals "stale" "$(classify_desired_state "${stale_state}" 4 "${five_hash}")" "Lower-generation state was not rejected."

conflict_state="${TEMP_DIRECTORY}/conflict.json"
write_repo_state \
    "${conflict_state}" \
    4 \
    '[{"url":"https://github.com/example/project","workers":6}]'
assert_equals "conflict" "$(classify_desired_state "${conflict_state}" 4 "${five_hash}")" "Same-generation changed state was not rejected."

malformed_state="${TEMP_DIRECTORY}/malformed.json"
printf '{"schemaVersion":1,"generation":9' > "${malformed_state}"
assert_equals "invalid" "$(classify_desired_state "${malformed_state}" 4 "${five_hash}")" "Malformed state was not rejected."

duplicate_state="${TEMP_DIRECTORY}/duplicate.json"
write_repo_state \
    "${duplicate_state}" \
    9 \
    '[{"url":"https://github.com/example/project","workers":1},{"url":"https://github.com/example/project","workers":2}]'
assert_equals "invalid" "$(classify_desired_state "${duplicate_state}" 4 "${five_hash}")" "Duplicate repository state was not rejected."

sentinel_state="${TEMP_DIRECTORY}/sentinel.json"
write_repo_state \
    "${sentinel_state}" \
    9 \
    '[{"url":"-","workers":1}]'
assert_equals "invalid" "$(classify_desired_state "${sentinel_state}" 4 "${five_hash}")" "The scope sentinel was accepted as a repository URL."

credential_url_state="${TEMP_DIRECTORY}/credential-url.json"
write_repo_state \
    "${credential_url_state}" \
    9 \
    '[{"url":"https://token@github.com/example/project","workers":1}]'
assert_equals "invalid" "$(classify_desired_state "${credential_url_state}" 4 "${five_hash}")" "Repository URL credentials were accepted."

query_url_state="${TEMP_DIRECTORY}/query-url.json"
write_repo_state \
    "${query_url_state}" \
    9 \
    '[{"url":"https://github.com/example/project?token=secret","workers":1}]'
assert_equals "invalid" "$(classify_desired_state "${query_url_state}" 4 "${five_hash}")" "Repository URL query parameters were accepted."

whitespace_url_state="${TEMP_DIRECTORY}/whitespace-url.json"
write_repo_state \
    "${whitespace_url_state}" \
    9 \
    '[{"url":" https://token@github.com/example/project","workers":1}]'
assert_equals "invalid" "$(classify_desired_state "${whitespace_url_state}" 4 "${five_hash}")" "Repository URL leading whitespace was accepted."

relative_url_state="${TEMP_DIRECTORY}/relative-url.json"
write_repo_state \
    "${relative_url_state}" \
    9 \
    '[{"url":"github.com/example/project","workers":1}]'
assert_equals "invalid" "$(classify_desired_state "${relative_url_state}" 4 "${five_hash}")" "A relative repository URL was accepted."

legacy_repo_state="${TEMP_DIRECTORY}/legacy-repo.json"
write_legacy_desired_state \
    "${legacy_repo_state}" \
    repo \
    'https://github.com/example/alpha=2,https://github.com/example/beta' \
    99
assert_true "Legacy repository capacity was not converted into valid desired state." desired_state_is_valid "${legacy_repo_state}"
assert_equals "2" "$(jq -r '.repositories | length' "${legacy_repo_state}")" "Legacy repository conversion lost a target."
assert_equals "2" "$(jq -r '.repositories[] | select(.url == "https://github.com/example/alpha") | .workers' "${legacy_repo_state}")" "Legacy explicit worker count changed during conversion."
assert_equals "1" "$(jq -r '.repositories[] | select(.url == "https://github.com/example/beta") | .workers' "${legacy_repo_state}")" "Legacy implicit worker count did not preserve the original default."

legacy_org_state="${TEMP_DIRECTORY}/legacy-org.json"
write_legacy_desired_state "${legacy_org_state}" org '' 4
assert_true "Legacy organization capacity was not converted into valid desired state." desired_state_is_valid "${legacy_org_state}"
assert_equals "4" "$(jq -r '.replicas' "${legacy_org_state}")" "Legacy organization replicas changed during conversion."

assert_false \
    "Legacy conversion accepted a zero worker count." \
    write_legacy_desired_state \
    "${TEMP_DIRECTORY}/legacy-invalid.json" \
    repo \
    'https://github.com/example/project=0' \
    1

observed_slots_directory="${TEMP_DIRECTORY}/observed-slots"
observed_slots_json="${TEMP_DIRECTORY}/observed-slots.json"
observed_state_json="${TEMP_DIRECTORY}/observed-state.json"
observed_dirty="${TEMP_DIRECTORY}/observed-dirty"
mkdir -p \
    "${observed_slots_directory}/repo-example-000001" \
    "${observed_slots_directory}/repo-example-000002"
printf '%s\n' "$$" > "${observed_slots_directory}/repo-example-000001/pid"
printf '%s\n' "$$" > "${observed_slots_directory}/repo-example-000002/pid"
printf '%s\n' 'https://token@example.com/example/project?secret=value' > "${observed_slots_directory}/repo-example-000001/repo"
printf '%s\n' 'https://github.com/example/project' > "${observed_slots_directory}/repo-example-000002/repo"
write_slot_runtime_state \
    "${observed_slots_directory}/repo-example-000001" \
    "${observed_dirty}" \
    online \
    runner-project-1 \
    0 \
    0
write_slot_runtime_state \
    "${observed_slots_directory}/repo-example-000002" \
    "${observed_dirty}" \
    backoff \
    runner-project-2 \
    2 \
    12
: > "${observed_slots_directory}/repo-example-000002/drain"
render_observed_slots "${observed_slots_directory}" "${observed_slots_json}"
write_manager_observed_state \
    "${observed_state_json}" \
    default \
    manager-instance \
    5 \
    running \
    repo \
    9 \
    state-hash \
    accepted \
    2 \
    "${observed_slots_json}"
assert_true "Observed manager state was rejected." observed_state_is_valid "${observed_state_json}"
assert_equals "2" "$(jq -r '.activeSlots' "${observed_state_json}")" "Observed state reported the wrong active slot count."
assert_equals "1" "$(jq -r '.drainingSlots' "${observed_state_json}")" "Observed state reported the wrong draining slot count."
assert_equals "online" "$(jq -r '.slots[] | select(.key == "repo-example-000001") | .state' "${observed_state_json}")" "Observed state lost an online slot."
assert_equals "draining" "$(jq -r '.slots[] | select(.key == "repo-example-000002") | .state' "${observed_state_json}")" "Drain state did not override runtime backoff."
assert_equals "2" "$(jq -r '.slots[] | select(.key == "repo-example-000002") | .failureCount' "${observed_state_json}")" "Observed state lost the slot failure count."
assert_equals "https://example.com/example/project" "$(jq -r '.slots[] | select(.key == "repo-example-000001") | .repository' "${observed_state_json}")" "Observed state did not strip repository credentials and query parameters."
assert_false "Observed state exposed an access token field." contains_access_token_field "${observed_state_json}"
assert_false "Observed state exposed runner names or derived tags." contains_runner_identity_field "${observed_state_json}"

echo "Manager reconciliation contracts passed: ${ASSERTIONS} assertions."
