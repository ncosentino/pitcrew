#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "${ROOT}/manager/reconciliation.sh"
. "${ROOT}/manager/observability.sh"
. "${ROOT}/manager/registration.sh"

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
    jq -e \
        '[.. | objects | has("tag") or has("runnerName") or has("containerId") or has("containerName")] | any' \
        "$1" >/dev/null
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
    9 \
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

assert_equals \
    "/repos/example/project/actions/runners" \
    "$(github_runner_endpoint repo 'https://github.com/example/project' '' '')" \
    "Repository runner endpoint was constructed incorrectly."
assert_equals \
    "/orgs/example-org/actions/runners" \
    "$(github_runner_endpoint org '' 'example-org' '')" \
    "Organization runner endpoint was constructed incorrectly."
assert_equals \
    "/enterprises/example-enterprise/actions/runners" \
    "$(github_runner_endpoint ent '' '' 'example-enterprise')" \
    "Enterprise runner endpoint was constructed incorrectly."
assert_false \
    "Repository runner endpoint accepted a malformed repository URL." \
    github_runner_endpoint repo 'https://github.com/example' '' ''

runner_inventory="${TEMP_DIRECTORY}/runner-inventory.json"
cat > "${runner_inventory}" <<'EOF'
{
  "totalCount": 4,
  "runners": [
    {"name":"runner-idle","status":"online","busy":false},
    {"name":"runner-busy","status":"online","busy":true},
    {"name":"runner-offline","status":"offline","busy":false},
    {"name":"runner-offline-busy","status":"offline","busy":true}
  ]
}
EOF
assert_equals \
    "connected	idle	0" \
    "$(classify_github_runner_registration "${runner_inventory}" runner-idle)" \
    "Online idle runner classification changed."
assert_equals \
    "connected	busy	0" \
    "$(classify_github_runner_registration "${runner_inventory}" runner-busy)" \
    "Online busy runner classification changed."
assert_equals \
    "disconnected	unknown	1" \
    "$(classify_github_runner_registration "${runner_inventory}" runner-offline)" \
    "Offline idle runner did not become a cleanup candidate."
assert_equals \
    "disconnected	busy	0" \
    "$(classify_github_runner_registration "${runner_inventory}" runner-offline-busy)" \
    "Offline busy runner was not preserved."
assert_equals \
    "registration-missing	unknown	1" \
    "$(classify_github_runner_registration "${runner_inventory}" runner-missing)" \
    "Missing runner did not become a cleanup candidate."
assert_equals \
    "unknown	unknown	0" \
    "$(classify_github_runner_registration "${runner_inventory}" '')" \
    "Unknown runner identity became a cleanup candidate."
ambiguous_runner_inventory="${TEMP_DIRECTORY}/ambiguous-runner-inventory.json"
cat > "${ambiguous_runner_inventory}" <<'EOF'
{
  "totalCount": 2,
  "runners": [
    {"name":"duplicate-runner","status":"offline","busy":false},
    {"name":"duplicate-runner","status":"offline","busy":false}
  ]
}
EOF
assert_equals \
    "unknown	unknown	0" \
    "$(classify_github_runner_registration "${ambiguous_runner_inventory}" duplicate-runner)" \
    "Ambiguous runner inventory became a cleanup candidate."

registration_slot="${TEMP_DIRECTORY}/registration-slot"
registration_dirty="${TEMP_DIRECTORY}/registration-dirty"
mkdir -p "${registration_slot}"
write_registration_observation \
    "${registration_slot}" \
    "${registration_dirty}" \
    disconnected \
    unknown \
    1
assert_equals \
    "1" \
    "$(jq -r '.cleanupEvidenceCount' "${registration_slot}/registration-state.json")" \
    "Registration observation lost its evidence count."
assert_true \
    "Registration observation did not mark observed state dirty." \
    test -f "${registration_dirty}"
assert_equals \
    "2" \
    "$(registration_evidence_count "${registration_slot}" disconnected 1)" \
    "Consecutive unusable observations did not advance cleanup evidence."
assert_equals \
    "1" \
    "$(registration_evidence_count "${registration_slot}" registration-missing 1)" \
    "Changed unusable evidence did not restart its confirmation count."
assert_equals \
    "0" \
    "$(registration_evidence_count "${registration_slot}" connected 0)" \
    "Usable registration state retained cleanup evidence."

ghost_slot="${TEMP_DIRECTORY}/ghost-slot"
fake_cleanup_docker_directory="${TEMP_DIRECTORY}/fake-cleanup-docker"
cleanup_log="${TEMP_DIRECTORY}/cleanup.log"
mkdir -p "${ghost_slot}" "${fake_cleanup_docker_directory}"
printf '%s\n' "container-ghost" > "${ghost_slot}/container-id"
printf '%s\n' "runner-ghost" > "${ghost_slot}/container-name"
printf '%s\n' "0" > "${ghost_slot}/registration-grace-until"
cat > "${fake_cleanup_docker_directory}/docker" <<'EOF'
#!/bin/sh
case "$1" in
    inspect)
        printf '%s\n' '[{"Name":"/runner-ghost","State":{"Running":true},"Config":{"Labels":{"ephemeral-managed-runner-profile":"default","ephemeral-managed-runner-slot":"ghost-slot"}}}]'
        ;;
    stop)
        printf '%s\n' "$*" >> "${PITCREW_TEST_CLEANUP_LOG}"
        ;;
    *)
        exit 1
        ;;
esac
EOF
chmod +x "${fake_cleanup_docker_directory}/docker"
PITCREW_TEST_CLEANUP_LOG="${cleanup_log}" \
PATH="${fake_cleanup_docker_directory}:${PATH}" \
    stop_confirmed_ghost \
        "${ghost_slot}" \
        "runner-ghost" \
        "default" \
        "ephemeral-managed-runner-profile" \
        "ephemeral-managed-runner-slot" \
        20 \
        2
assert_equals \
    "stop --time 20 container-ghost" \
    "$(cat "${cleanup_log}")" \
    "Confirmed ghost cleanup did not stop the exact classified container."
: > "${cleanup_log}"
printf '%s\n' "runner-replacement" > "${ghost_slot}/container-name"
PITCREW_TEST_CLEANUP_LOG="${cleanup_log}" \
PATH="${fake_cleanup_docker_directory}:${PATH}" \
    stop_confirmed_ghost \
        "${ghost_slot}" \
        "runner-ghost" \
        "default" \
        "ephemeral-managed-runner-profile" \
        "ephemeral-managed-runner-slot" \
        20 \
        2
assert_equals \
    "0" \
    "$(wc -c < "${cleanup_log}" | tr -d ' ')" \
    "Cleanup stopped a replacement container after runner identity changed."
printf '%s\n' "runner-ghost" > "${ghost_slot}/container-name"
printf '%s\n' "$(( $(date +%s) + 60 ))" > "${ghost_slot}/registration-grace-until"
PITCREW_TEST_CLEANUP_LOG="${cleanup_log}" \
PATH="${fake_cleanup_docker_directory}:${PATH}" \
    stop_confirmed_ghost \
        "${ghost_slot}" \
        "runner-ghost" \
        "default" \
        "ephemeral-managed-runner-profile" \
        "ephemeral-managed-runner-slot" \
        20 \
        2
assert_equals \
    "0" \
    "$(wc -c < "${cleanup_log}" | tr -d ' ')" \
    "Cleanup stopped a runner whose replacement grace period had restarted."

fake_wget_directory="${TEMP_DIRECTORY}/fake-wget"
mkdir -p "${fake_wget_directory}"
cat > "${fake_wget_directory}/wget" <<'EOF'
#!/bin/sh
output=""
url=""
authorization=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -O)
            output="$2"
            shift 2
            ;;
        --header)
            case "$2" in
                Authorization:*) authorization="$2" ;;
            esac
            shift 2
            ;;
        -T)
            shift 2
            ;;
        -q)
            shift
            ;;
        *)
            url="$1"
            shift
            ;;
    esac
done
[ "${authorization}" = "Authorization: Bearer test-token" ] || exit 1
if [ "${PITCREW_TEST_INCOMPLETE_INVENTORY:-0}" = "1" ]; then
    printf '%s\n' \
        '{"total_count":2,"runners":[{"name":"runner-only","status":"online","busy":false}]}' \
        > "${output}"
    exit 0
fi
case "${url}" in
    *page=1)
        jq -n '{
            total_count: 101,
            runners: [
                range(0; 100) as $index
                | {
                    name: ("runner-" + ($index | tostring)),
                    status: "online",
                    busy: false
                }
            ]
        }' > "${output}"
        ;;
    *page=2)
        printf '%s\n' \
            '{"total_count":101,"runners":[{"name":"runner-final","status":"online","busy":true}]}' \
            > "${output}"
        ;;
    *)
        exit 1
        ;;
esac
EOF
chmod +x "${fake_wget_directory}/wget"
fetched_inventory="${TEMP_DIRECTORY}/fetched-runner-inventory.json"
PATH="${fake_wget_directory}:${PATH}" \
    fetch_github_runner_inventory \
        "${fetched_inventory}" \
        "/repos/example/project/actions/runners" \
        "test-token" \
        1
assert_equals \
    "101" \
    "$(jq -r '.runners | length' "${fetched_inventory}")" \
    "Runner inventory pagination lost records."
assert_equals \
    "connected	busy	0" \
    "$(classify_github_runner_registration "${fetched_inventory}" runner-final)" \
    "Paginated runner inventory was not classifiable."
assert_false \
    "Incomplete runner inventory was accepted as authoritative." \
    env \
    PATH="${fake_wget_directory}:${PATH}" \
    PITCREW_TEST_INCOMPLETE_INVENTORY=1 \
    sh -c \
    '. "'"${ROOT}"'/manager/registration.sh"; fetch_github_runner_inventory "$1" "$2" "$3" "$4"' \
    sh \
    "${TEMP_DIRECTORY}/incomplete-runner-inventory.json" \
    "/repos/example/project/actions/runners" \
    "test-token" \
    1

fake_docker_directory="${TEMP_DIRECTORY}/fake-docker"
collected_resources="${TEMP_DIRECTORY}/collected-resources.json"
partial_resources="${TEMP_DIRECTORY}/partial-resources.json"
timed_resources="${TEMP_DIRECTORY}/timed-resources.json"
host_partial_resources="${TEMP_DIRECTORY}/host-partial-resources.json"
mkdir -p "${fake_docker_directory}"
cat > "${fake_docker_directory}/docker" <<'EOF'
#!/bin/sh
case "$1" in
    info)
        if [ "${PITCREW_TEST_INFO_FAIL:-0}" = "1" ]; then
            exit 1
        fi
        printf '%s\n' '{"logicalProcessorCount":16,"memoryBytes":34359738368}'
        ;;
    ps)
        printf '%s\n' 'worker123 slot-one runner-one'
        ;;
    stats)
        if [ "${PITCREW_TEST_STATS_SLEEP:-0}" != "0" ]; then
            sleep "${PITCREW_TEST_STATS_SLEEP}"
        fi
        if [ "${PITCREW_TEST_STATS_FAIL:-0}" = "1" ]; then
            exit 1
        fi
        printf '%s\n' \
            '{"CPUPerc":"1.25%","ID":"manager123","MemUsage":"32MiB / 32GiB","PIDs":"7"}' \
            '{"CPUPerc":"25.00%","ID":"worker123","MemUsage":"128MiB / 32GiB","PIDs":"12"}'
        ;;
    *)
        exit 1
        ;;
esac
EOF
chmod +x "${fake_docker_directory}/docker"

HOSTNAME=manager123 \
PATH="${fake_docker_directory}:${PATH}" \
    collect_resource_telemetry \
        "${collected_resources}" \
        'ephemeral-managed-runner-profile=default' \
        'ephemeral-runner-manager-profile=default' \
        'ephemeral-managed-runner-slot' \
        1
assert_equals "available" "$(jq -r '.status' "${collected_resources}")" "Complete Docker stats did not produce available resource telemetry."
assert_equals "0.0125" "$(jq -r '.manager.cpuCores' "${collected_resources}")" "Manager CPU telemetry was normalized incorrectly."
assert_equals "134217728" "$(jq -r '.slots["slot-one"].usage.memoryWorkingSetBytes' "${collected_resources}")" "Worker memory telemetry was normalized incorrectly."

PITCREW_TEST_STATS_FAIL=1 \
HOSTNAME=manager123 \
PATH="${fake_docker_directory}:${PATH}" \
    collect_resource_telemetry \
        "${partial_resources}" \
        'ephemeral-managed-runner-profile=default' \
        'ephemeral-runner-manager-profile=default' \
        'ephemeral-managed-runner-slot' \
        1
assert_equals "partial" "$(jq -r '.status' "${partial_resources}")" "A Docker stats failure was not surfaced as partial telemetry."
assert_equals "null" "$(jq -r '.manager' "${partial_resources}")" "A failed stats sample emitted success-shaped manager usage."

PITCREW_TEST_INFO_FAIL=1 \
HOSTNAME=manager123 \
PATH="${fake_docker_directory}:${PATH}" \
    collect_resource_telemetry \
        "${host_partial_resources}" \
        'ephemeral-managed-runner-profile=default' \
        'ephemeral-runner-manager-profile=default' \
        'ephemeral-managed-runner-slot' \
        1
assert_equals "partial" "$(jq -r '.status' "${host_partial_resources}")" "Missing host capacity was not surfaced as partial telemetry."
assert_equals "null" "$(jq -r '.host' "${host_partial_resources}")" "A failed host-capacity sample emitted success-shaped capacity."
assert_equals "0.0125" "$(jq -r '.manager.cpuCores' "${host_partial_resources}")" "Host-capacity failure discarded valid manager telemetry."
assert_equals "134217728" "$(jq -r '.slots["slot-one"].usage.memoryWorkingSetBytes' "${host_partial_resources}")" "Host-capacity failure discarded valid worker telemetry."

timeout_started=$(date +%s)
PITCREW_TEST_STATS_SLEEP=5 \
HOSTNAME=manager123 \
PATH="${fake_docker_directory}:${PATH}" \
    collect_resource_telemetry \
        "${timed_resources}" \
        'ephemeral-managed-runner-profile=default' \
        'ephemeral-runner-manager-profile=default' \
        'ephemeral-managed-runner-slot' \
        1
timeout_elapsed=$(($(date +%s) - timeout_started))
assert_true \
    "A stalled Docker stats request blocked telemetry collection for ${timeout_elapsed} seconds." \
    test "${timeout_elapsed}" -lt 4
assert_equals "partial" "$(jq -r '.status' "${timed_resources}")" "A timed-out stats sample was not surfaced as partial telemetry."

observed_slots_directory="${TEMP_DIRECTORY}/observed-slots"
observed_slots_json="${TEMP_DIRECTORY}/observed-slots.json"
observed_state_json="${TEMP_DIRECTORY}/observed-state.json"
resource_telemetry_json="${TEMP_DIRECTORY}/resource-telemetry.json"
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
write_registration_observation \
    "${observed_slots_directory}/repo-example-000001" \
    "${observed_dirty}" \
    connected \
    idle \
    0
write_slot_runtime_state \
    "${observed_slots_directory}/repo-example-000002" \
    "${observed_dirty}" \
    backoff \
    runner-project-2 \
    2 \
    12
write_registration_observation \
    "${observed_slots_directory}/repo-example-000002" \
    "${observed_dirty}" \
    disconnected \
    busy \
    0
: > "${observed_slots_directory}/repo-example-000002/drain"
cat > "${resource_telemetry_json}" <<'EOF'
{
  "sampledAt": "2026-01-01T00:00:00Z",
  "status": "available",
  "host": {
    "logicalProcessorCount": 16,
    "memoryBytes": 34359738368
  },
  "manager": {
    "cpuCores": 0.01,
    "memoryWorkingSetBytes": 33554432,
    "pids": 7
  },
  "slots": {
    "repo-example-000001": {
      "runnerName": "runner-project-1",
      "usage": {
        "cpuCores": 0.25,
        "memoryWorkingSetBytes": 134217728,
        "pids": 12
      }
    },
    "repo-example-000002": {
      "runnerName": "runner-project-2",
      "usage": {
        "cpuCores": 0.5,
        "memoryWorkingSetBytes": 268435456,
        "pids": 20
      }
    }
  }
}
EOF
render_observed_slots \
    "${observed_slots_directory}" \
    "${observed_slots_json}" \
    "${resource_telemetry_json}"
write_manager_observed_state \
    "${observed_state_json}" \
    default \
    manager-instance \
    10 \
    running \
    repo \
    9 \
    state-hash \
    accepted \
    2 \
    "${observed_slots_json}" \
    "${resource_telemetry_json}" \
    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    1
assert_true "Observed manager state was rejected." observed_state_is_valid "${observed_state_json}"
assert_equals "10" "$(jq -r '.managerContractVersion' "${observed_state_json}")" "Observed state reported the wrong manager contract."
assert_equals "2" "$(jq -r '.activeSlots' "${observed_state_json}")" "Observed state reported the wrong active slot count."
assert_equals "1" "$(jq -r '.eligibleSlots' "${observed_state_json}")" "Observed state reported the wrong GitHub-eligible slot count."
assert_equals "2" "$(jq -r '.configuredSlots' "${observed_state_json}")" "Observed state reported the wrong configured slot count."
assert_equals "null" "$(jq -r '.autoscaling' "${observed_state_json}")" "Fixed observed state reported autoscaling metadata."
assert_equals "rolling" "$(jq -r '.update.status' "${observed_state_json}")" "Fixed observed state lost rolling-update status."
assert_equals "1" "$(jq -r '.update.staleWorkers' "${observed_state_json}")" "Fixed observed state reported the wrong stale-worker count."
assert_equals "1" "$(jq -r '.drainingSlots' "${observed_state_json}")" "Observed state reported the wrong draining slot count."
assert_equals "online" "$(jq -r '.slots[] | select(.key == "repo-example-000001") | .state' "${observed_state_json}")" "Observed state lost an online slot."
assert_equals "connected" "$(jq -r '.slots[] | select(.key == "repo-example-000001") | .registrationStatus' "${observed_state_json}")" "Observed state lost connected registration status."
assert_equals "idle" "$(jq -r '.slots[] | select(.key == "repo-example-000001") | .activity' "${observed_state_json}")" "Observed state lost server-side idle activity."
assert_equals "draining" "$(jq -r '.slots[] | select(.key == "repo-example-000002") | .state' "${observed_state_json}")" "Drain state did not override runtime backoff."
assert_equals "disconnected" "$(jq -r '.slots[] | select(.key == "repo-example-000002") | .registrationStatus' "${observed_state_json}")" "Observed state lost disconnected registration status."
assert_equals "2" "$(jq -r '.slots[] | select(.key == "repo-example-000002") | .failureCount' "${observed_state_json}")" "Observed state lost the slot failure count."
assert_equals "https://example.com/example/project" "$(jq -r '.slots[] | select(.key == "repo-example-000001") | .repository' "${observed_state_json}")" "Observed state did not strip repository credentials and query parameters."
assert_equals "16" "$(jq -r '.resourceTelemetry.host.logicalProcessorCount' "${observed_state_json}")" "Observed state lost host processor capacity."
assert_equals "33554432" "$(jq -r '.resourceTelemetry.manager.memoryWorkingSetBytes' "${observed_state_json}")" "Observed state lost manager memory telemetry."
assert_equals "0.25" "$(jq -r '.slots[] | select(.key == "repo-example-000001") | .resources.cpuCores' "${observed_state_json}")" "Observed state lost online slot CPU telemetry."
assert_equals "0.5" "$(jq -r '.slots[] | select(.key == "repo-example-000002") | .resources.cpuCores' "${observed_state_json}")" "Observed state lost draining slot CPU telemetry."
assert_false "Observed state exposed an access token field." contains_access_token_field "${observed_state_json}"
assert_false "Observed state exposed runner names or derived tags." contains_runner_identity_field "${observed_state_json}"

invalid_resource_state="${TEMP_DIRECTORY}/invalid-resource-state.json"
jq 'del(.configuredSlots)' "${observed_state_json}" > "${invalid_resource_state}"
assert_false "Manager contract eight accepted missing configured capacity." observed_state_is_valid "${invalid_resource_state}"
jq 'del(.autoscaling)' "${observed_state_json}" > "${invalid_resource_state}"
assert_false "Manager contract eight accepted missing autoscaling mode state." observed_state_is_valid "${invalid_resource_state}"
jq '.slots[0].resources.cpuCores = -1' "${observed_state_json}" > "${invalid_resource_state}"
assert_false "Observed state accepted negative CPU telemetry." observed_state_is_valid "${invalid_resource_state}"
jq 'del(.resourceTelemetry)' "${observed_state_json}" > "${invalid_resource_state}"
assert_false "Manager contract eight accepted missing resource telemetry." observed_state_is_valid "${invalid_resource_state}"
jq '.resourceTelemetry = null' "${observed_state_json}" > "${invalid_resource_state}"
assert_false "Manager contract eight accepted null resource telemetry." observed_state_is_valid "${invalid_resource_state}"
jq 'del(.slots[0].resources)' "${observed_state_json}" > "${invalid_resource_state}"
assert_false "Manager contract eight accepted a slot without a resources field." observed_state_is_valid "${invalid_resource_state}"
jq 'del(.update)' "${observed_state_json}" > "${invalid_resource_state}"
assert_false "Manager contract nine accepted missing rolling-update state." observed_state_is_valid "${invalid_resource_state}"
jq 'del(.eligibleSlots)' "${observed_state_json}" > "${invalid_resource_state}"
assert_false "Manager contract ten accepted missing eligible capacity." observed_state_is_valid "${invalid_resource_state}"
jq 'del(.slots[0].registrationStatus)' "${observed_state_json}" > "${invalid_resource_state}"
assert_false "Manager contract ten accepted missing registration status." observed_state_is_valid "${invalid_resource_state}"
jq '.eligibleSlots = 2' "${observed_state_json}" > "${invalid_resource_state}"
assert_false "Manager contract ten accepted inconsistent eligible capacity." observed_state_is_valid "${invalid_resource_state}"
jq '.resourceTelemetry.host = null' "${observed_state_json}" > "${invalid_resource_state}"
assert_false "Available telemetry accepted missing host capacity." observed_state_is_valid "${invalid_resource_state}"
jq '
    .resourceTelemetry.status = "partial"
    | .resourceTelemetry.host = null
    | .resourceTelemetry.manager = null
    | .slots |= map(.resources = null)
' "${observed_state_json}" > "${invalid_resource_state}"
assert_false "Partial telemetry accepted an empty resource sample." observed_state_is_valid "${invalid_resource_state}"
jq '
    .resourceTelemetry.status = "unavailable"
    | .resourceTelemetry.host = null
    | .resourceTelemetry.manager = null
' "${observed_state_json}" > "${invalid_resource_state}"
assert_false "Unavailable telemetry accepted worker resource values." observed_state_is_valid "${invalid_resource_state}"
jq '
    .resourceTelemetry.status = "unavailable"
    | .resourceTelemetry.host = null
    | .resourceTelemetry.manager = null
    | .slots |= map(.resources = null)
    | del(.resourceTelemetry.host)
' "${observed_state_json}" > "${invalid_resource_state}"
assert_false "Unavailable telemetry accepted a missing host field." observed_state_is_valid "${invalid_resource_state}"
jq '
    .resourceTelemetry.status = "unavailable"
    | .resourceTelemetry.host = null
    | .resourceTelemetry.manager = null
    | .slots |= map(.resources = null)
    | del(.resourceTelemetry.manager)
' "${observed_state_json}" > "${invalid_resource_state}"
assert_false "Unavailable telemetry accepted a missing manager field." observed_state_is_valid "${invalid_resource_state}"
legacy_observed_state="${TEMP_DIRECTORY}/legacy-observed-state.json"
jq '
    .managerContractVersion = 9
    | del(.eligibleSlots)
    | del(.slots[].registrationStatus)
' "${observed_state_json}" > "${legacy_observed_state}"
assert_true "Observed-state validation rejected a pre-registration manager contract." observed_state_is_valid "${legacy_observed_state}"

assert_equals "0" "$(parse_size_bytes '0B')" "Byte parsing changed zero bytes."
assert_equals "44312822" "$(parse_size_bytes '42.26MiB')" "Byte parsing did not preserve Docker binary units."
assert_equals "0.125" "$(parse_cpu_cores '12.5%')" "CPU parsing did not convert Docker percent to cores."

echo "Manager reconciliation contracts passed: ${ASSERTIONS} assertions."
