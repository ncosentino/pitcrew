#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "${ROOT}/manager/reconciliation.sh"
. "${ROOT}/manager/observability.sh"
. "${ROOT}/manager/registration.sh"
. "${ROOT}/manager/diagnostics.sh"

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
host_hardware="${TEMP_DIRECTORY}/host-hardware.json"
unavailable_host_hardware="${TEMP_DIRECTORY}/unavailable-host-hardware.json"
cpuinfo_fixture="${TEMP_DIRECTORY}/cpuinfo"
kernel_fixture="${TEMP_DIRECTORY}/kernel-version"
mkdir -p "${fake_docker_directory}"
cat > "${cpuinfo_fixture}" <<'EOF'
processor : 0
physical id : 0
core id : 0
model name : Example Processor 9000

processor : 1
physical id : 0
core id : 0
model name : Example Processor 9000

processor : 2
physical id : 0
core id : 1
model name : Example Processor 9000
EOF
printf '%s\n' '6.12.34-test' > "${kernel_fixture}"
cat > "${fake_docker_directory}/docker" <<'EOF'
#!/bin/sh
case "$1" in
    info)
        if [ "${PITCREW_TEST_INFO_FAIL:-0}" = "1" ]; then
            exit 1
        fi
        case "$*" in
            *Backing\ Filesystem*)
                printf '%s\n' 'extfs'
                ;;
            *operatingSystem*)
                printf '%s\n' \
                    '{"logicalProcessorCount":16,"memoryBytes":34359738368,"operatingSystem":"Docker Desktop","dockerServerVersion":"28.3.3","dockerStorageDriver":"overlayfs"}'
                ;;
            *)
                printf '%s\n' '{"logicalProcessorCount":16,"memoryBytes":34359738368}'
                ;;
        esac
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

PATH="${fake_docker_directory}:${PATH}" \
    collect_host_hardware \
        "${host_hardware}" \
        1 \
        "${cpuinfo_fixture}" \
        "${kernel_fixture}" \
        x86_64
assert_equals "current" "$(jq -r '.status' "${host_hardware}")" "Complete hardware collection did not report current."
assert_equals "Example Processor 9000" "$(jq -r '.processorModel' "${host_hardware}")" "Hardware collection lost the processor model."
assert_equals "amd64" "$(jq -r '.architecture' "${host_hardware}")" "Hardware collection did not normalize architecture."
assert_equals "2" "$(jq -r '.physicalCoreCount' "${host_hardware}")" "Hardware collection derived the wrong physical core count."
assert_equals "16" "$(jq -r '.logicalProcessorCount' "${host_hardware}")" "Hardware collection lost Docker logical capacity."
assert_equals "null" "$(jq -r '.performanceCoreCount' "${host_hardware}")" "Hardware collection guessed a performance-core count."
assert_equals "null" "$(jq -r '.efficiencyCoreCount' "${host_hardware}")" "Hardware collection guessed an efficiency-core count."
assert_equals "extfs" "$(jq -r '.dockerBackingFilesystem' "${host_hardware}")" "Hardware collection lost Docker backing filesystem."
assert_true "Collected host hardware did not satisfy its persisted contract." host_hardware_inventory_is_valid "${host_hardware}"
initial_hardware_hash=$(jq -r '.inventoryHash' "${host_hardware}")
initial_hardware_collected_at=$(jq -r '.collectedAt' "${host_hardware}")

PATH="${fake_docker_directory}:${PATH}" \
    collect_host_hardware \
        "${host_hardware}" \
        1 \
        "${cpuinfo_fixture}" \
        "${kernel_fixture}" \
        x86_64
assert_equals "${initial_hardware_hash}" "$(jq -r '.inventoryHash' "${host_hardware}")" "Stable hardware changed its inventory hash."
assert_equals "${initial_hardware_collected_at}" "$(jq -r '.collectedAt' "${host_hardware}")" "Stable hardware changed its collection identity."

PITCREW_TEST_INFO_FAIL=1 \
PATH="${fake_docker_directory}:${PATH}" \
    collect_host_hardware \
        "${host_hardware}" \
        1 \
        "${cpuinfo_fixture}" \
        "${kernel_fixture}" \
        x86_64
assert_equals "stale" "$(jq -r '.status' "${host_hardware}")" "A failed hardware refresh did not preserve stale inventory."
assert_equals "${initial_hardware_hash}" "$(jq -r '.inventoryHash' "${host_hardware}")" "A failed hardware refresh discarded the last valid inventory."

PITCREW_TEST_INFO_FAIL=1 \
PATH="${fake_docker_directory}:${PATH}" \
    collect_host_hardware \
        "${unavailable_host_hardware}" \
        1 \
        "${cpuinfo_fixture}" \
        "${kernel_fixture}" \
        x86_64
assert_equals "unavailable" "$(jq -r '.status' "${unavailable_host_hardware}")" "A failed initial hardware probe was not unavailable."
assert_equals "null" "$(jq -r '.inventoryHash' "${unavailable_host_hardware}")" "Unavailable hardware published an inventory hash."

tampered_host_hardware="${TEMP_DIRECTORY}/tampered-host-hardware.json"
jq '.architecture = "arm64"' "${host_hardware}" > "${tampered_host_hardware}"
assert_false "Tampered host hardware inventory was accepted." host_hardware_inventory_is_valid "${tampered_host_hardware}"
invalid_timestamp_hardware="${TEMP_DIRECTORY}/invalid-timestamp-hardware.json"
jq '.attemptedAt = "not-a-timestamp"' "${host_hardware}" > "${invalid_timestamp_hardware}"
assert_false "Host hardware accepted a malformed attempt timestamp." host_hardware_inventory_is_valid "${invalid_timestamp_hardware}"
fallback_host_hardware="${TEMP_DIRECTORY}/fallback-host-hardware.json"
write_stale_or_unavailable_host_hardware \
    "${host_hardware}" \
    "${fallback_host_hardware}" \
    2026-08-04T00:10:00Z
assert_equals "stale" "$(jq -r '.status' "${fallback_host_hardware}")" "Hardware persistence fallback did not retain stale inventory."
assert_equals "${initial_hardware_hash}" "$(jq -r '.inventoryHash' "${fallback_host_hardware}")" "Hardware persistence fallback changed inventory identity."

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

launched_marker_slot="${TEMP_DIRECTORY}/connect-marker-launched"
recovered_marker_slot="${TEMP_DIRECTORY}/connect-marker-recovered"
mkdir -p "${launched_marker_slot}" "${recovered_marker_slot}"
reset_slot_connect_marker "${launched_marker_slot}"
assert_true \
    "A freshly launched slot could not observe its own connect marker." \
    slot_connect_marker_is_pending "${launched_marker_slot}"
consume_slot_connect_marker "${launched_marker_slot}"
assert_false \
    "A connect marker stayed pending after it promoted its slot." \
    slot_connect_marker_is_pending "${launched_marker_slot}"
consume_slot_connect_marker "${recovered_marker_slot}"
assert_false \
    "An adopted slot could be reported online by worker output produced before adoption." \
    slot_connect_marker_is_pending "${recovered_marker_slot}"
reset_slot_connect_marker "${recovered_marker_slot}"
assert_true \
    "A replacement runner launched by the adopting manager could not report its own connect marker." \
    slot_connect_marker_is_pending "${recovered_marker_slot}"

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
    1 \
    "" \
    "" \
    "" \
    "" \
    example/runner:1.0 \
    sha256:1111111111111111111111111111111111111111111111111111111111111111
assert_true "Observed manager state was rejected." observed_state_is_valid "${observed_state_json}"
assert_equals "10" "$(jq -r '.managerContractVersion' "${observed_state_json}")" "Observed state reported the wrong manager contract."
assert_equals "2" "$(jq -r '.activeSlots' "${observed_state_json}")" "Observed state reported the wrong active slot count."
assert_equals "1" "$(jq -r '.eligibleSlots' "${observed_state_json}")" "Observed state reported the wrong GitHub-eligible slot count."
assert_equals "2" "$(jq -r '.configuredSlots' "${observed_state_json}")" "Observed state reported the wrong configured slot count."
assert_equals "null" "$(jq -r '.autoscaling' "${observed_state_json}")" "Fixed observed state reported autoscaling metadata."
assert_equals "rolling" "$(jq -r '.update.status' "${observed_state_json}")" "Fixed observed state lost rolling-update status."
assert_equals "example/runner:1.0" "$(jq -r '.update.targetImage' "${observed_state_json}")" "Fixed observed state lost the target image reference."
assert_equals "sha256:1111111111111111111111111111111111111111111111111111111111111111" "$(jq -r '.update.targetImageId' "${observed_state_json}")" "Fixed observed state lost the target image identity."
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

assert_equals \
    "15" \
    "$(sed -n 's/^MANAGER_CONTRACT_VERSION=\([0-9][0-9]*\)$/\1/p' "${ROOT}/manager/manage-runners.sh")" \
    "The fixed manager does not declare the activated contract."

contract_eleven_state_json="${TEMP_DIRECTORY}/contract-eleven-state.json"
contract_eleven_slots_json="${TEMP_DIRECTORY}/contract-eleven-slots.json"
contract_eleven_policy_json="${TEMP_DIRECTORY}/contract-eleven-policy.json"
contract_eleven_telemetry_json="${TEMP_DIRECTORY}/contract-eleven-telemetry.json"
worker_image_id="sha256:1111111111111111111111111111111111111111111111111111111111111111"
printf '%s\n' "${worker_image_id}" > "${observed_slots_directory}/repo-example-000001/image-id"
printf '%s\n' "not-an-image-identity" > "${observed_slots_directory}/repo-example-000002/image-id"
write_slot_exit_evidence \
    "${observed_slots_directory}/repo-example-000002" \
    "${observed_dirty}" \
    docker-inspect \
    137 \
    true
printf '%s\n' '{"classification":"guessed"}' \
    > "${observed_slots_directory}/repo-example-000001/last-exit.json"
jq '
    .slots["repo-example-000001"].usage += {
        networkRxBytes: 1048576,
        networkTxBytes: 262144,
        blockReadBytes: 536870912,
        blockWriteBytes: 134217728
    }
    | .slots["repo-example-000002"].usage += {
        networkRxBytes: null,
        networkTxBytes: null,
        blockReadBytes: null,
        blockWriteBytes: null
    }
' "${resource_telemetry_json}" > "${contract_eleven_telemetry_json}"
write_worker_resource_policy "${contract_eleven_policy_json}" 536870912 1073741824 2.5 256
render_observed_slots \
    "${observed_slots_directory}" \
    "${contract_eleven_slots_json}" \
    "${contract_eleven_telemetry_json}"
write_manager_observed_state \
    "${contract_eleven_state_json}" \
    default \
    manager-instance \
    11 \
    running \
    repo \
    9 \
    state-hash \
    accepted \
    2 \
    "${contract_eleven_slots_json}" \
    "${contract_eleven_telemetry_json}" \
    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    1 \
    "${contract_eleven_policy_json}"
assert_true "Contract-eleven observed manager state was rejected." observed_state_is_valid "${contract_eleven_state_json}"
assert_equals "536870912" "$(jq -r '.resourcePolicy.memoryBytes' "${contract_eleven_state_json}")" "Observed state lost the configured memory policy."
assert_equals "2.5" "$(jq -r '.resourcePolicy.cpuCores' "${contract_eleven_state_json}")" "Observed state lost the configured CPU policy."
assert_equals \
    "${worker_image_id}" \
    "$(jq -r '.slots[] | select(.key == "repo-example-000001") | .imageId' "${contract_eleven_state_json}")" \
    "Observed state lost immutable worker image identity."
assert_equals \
    "null" \
    "$(jq -r '.slots[] | select(.key == "repo-example-000002") | .imageId' "${contract_eleven_state_json}")" \
    "Observed state published a malformed worker image identity."
assert_equals \
    "1048576" \
    "$(jq -r '.slots[] | select(.key == "repo-example-000001") | .resources.networkRxBytes' "${contract_eleven_state_json}")" \
    "Observed state lost cumulative worker network counters."
assert_equals \
    "null" \
    "$(jq -r '.slots[] | select(.key == "repo-example-000002") | .resources.blockWriteBytes' "${contract_eleven_state_json}")" \
    "Unavailable worker block I/O was reported as zero."
assert_equals \
    "oom-killed" \
    "$(jq -r '.slots[] | select(.key == "repo-example-000002") | .lastExit.classification' "${contract_eleven_state_json}")" \
    "Observed state lost Docker-confirmed exit evidence."
assert_equals \
    "null" \
    "$(jq -r '.slots[] | select(.key == "repo-example-000001") | .lastExit' "${contract_eleven_state_json}")" \
    "Observed state published malformed exit evidence."
assert_false "Contract-eleven observed state exposed runner names or derived tags." \
    contains_runner_identity_field "${contract_eleven_state_json}"

invalid_contract_eleven_state="${TEMP_DIRECTORY}/invalid-contract-eleven-state.json"
jq 'del(.resourcePolicy)' "${contract_eleven_state_json}" > "${invalid_contract_eleven_state}"
assert_false "Manager contract eleven accepted a missing resource policy." observed_state_is_valid "${invalid_contract_eleven_state}"
jq 'del(.slots[0].imageId)' "${contract_eleven_state_json}" > "${invalid_contract_eleven_state}"
assert_false "Manager contract eleven accepted a slot without image identity." observed_state_is_valid "${invalid_contract_eleven_state}"
jq 'del(.slots[0].lastExit)' "${contract_eleven_state_json}" > "${invalid_contract_eleven_state}"
assert_false "Manager contract eleven accepted a slot without exit evidence." observed_state_is_valid "${invalid_contract_eleven_state}"
jq 'del(.slots[0].resources.networkRxBytes)' "${contract_eleven_state_json}" > "${invalid_contract_eleven_state}"
assert_false "Manager contract eleven accepted worker resources without I/O counters." observed_state_is_valid "${invalid_contract_eleven_state}"
jq '.slots[0].resources.networkRxBytes = -1' "${contract_eleven_state_json}" > "${invalid_contract_eleven_state}"
assert_false "Observed state accepted a negative I/O counter." observed_state_is_valid "${invalid_contract_eleven_state}"
jq '.resourcePolicy.memorySwapBytes = 268435456' "${contract_eleven_state_json}" > "${invalid_contract_eleven_state}"
assert_false "Observed state accepted a memory-swap limit below the memory limit." observed_state_is_valid "${invalid_contract_eleven_state}"
jq '.resourcePolicy = {memoryBytes: null, memorySwapBytes: null, cpuCores: null, pids: null}' \
    "${contract_eleven_state_json}" > "${invalid_contract_eleven_state}"
assert_false "Observed state accepted an empty resource policy object." observed_state_is_valid "${invalid_contract_eleven_state}"
jq '.resourcePolicy.cpuCores = 2.5' "${contract_eleven_state_json}" > "${invalid_contract_eleven_state}"
assert_false "Observed state accepted a non-canonical CPU policy value." observed_state_is_valid "${invalid_contract_eleven_state}"
jq '.slots[1].lastExit.classification = "guessed"' "${contract_eleven_state_json}" > "${invalid_contract_eleven_state}"
assert_false "Observed state accepted an unknown exit classification." observed_state_is_valid "${invalid_contract_eleven_state}"
rm -f \
    "${observed_slots_directory}/repo-example-000001/image-id" \
    "${observed_slots_directory}/repo-example-000002/image-id" \
    "${observed_slots_directory}/repo-example-000001/last-exit.json" \
    "${observed_slots_directory}/repo-example-000002/last-exit.json"

assert_equals "null" "$(jq -r '.resourcePolicy' "${observed_state_json}")" "A profile without a resource policy published a policy object."
assert_equals "null" "$(jq -r '.slots[0].lastExit' "${observed_state_json}")" "A slot without exit evidence published a last-exit diagnostic."
assert_equals "null" "$(jq -r '.slots[0].imageId' "${observed_state_json}")" "A slot without image evidence published an image identity."

assert_true \
    "A complete canonical resource policy was rejected." \
    worker_resource_policy_is_valid 536870912 1073741824 2.5 256
assert_true \
    "An unlimited resource policy was rejected." \
    worker_resource_policy_is_valid '' '' '' ''
assert_true \
    "A fractional CPU-only policy was rejected." \
    worker_resource_policy_is_valid '' '' 0.5 ''
assert_false \
    "A memory limit below Docker's minimum was accepted." \
    worker_resource_policy_is_valid 1048576 '' '' ''
assert_false \
    "A memory-swap limit without a memory limit was accepted." \
    worker_resource_policy_is_valid '' 1073741824 '' ''
assert_false \
    "A memory-swap limit below the memory limit was accepted." \
    worker_resource_policy_is_valid 1073741824 536870912 '' ''
assert_false \
    "A zero CPU limit was accepted." \
    worker_resource_policy_is_valid '' '' 0 ''
assert_false \
    "A non-numeric CPU limit was accepted." \
    worker_resource_policy_is_valid '' '' unlimited ''
assert_false \
    "A zero PID limit was accepted." \
    worker_resource_policy_is_valid '' '' '' 0
assert_false \
    "A PID limit above Docker's maximum was accepted." \
    worker_resource_policy_is_valid '' '' '' 2147483648

assert_equals \
    "--memory 536870912 --memory-swap 1073741824 --cpus 2.5 --pids-limit 256" \
    "$(render_worker_resource_arguments 536870912 1073741824 2.5 256)" \
    "Canonical policy values did not reach the exact Docker arguments."
assert_equals \
    "--cpus 0.5" \
    "$(render_worker_resource_arguments '' '' 0.5 '')" \
    "A partial policy emitted arguments for unconfigured dimensions."
assert_equals \
    "" \
    "$(render_worker_resource_arguments '' '' '' '')" \
    "An unlimited policy emitted Docker resource arguments."
assert_false \
    "An invalid policy rendered Docker resource arguments." \
    render_worker_resource_arguments 1048576 '' '' ''

resource_policy_json="${TEMP_DIRECTORY}/resource-policy.json"
write_worker_resource_policy "${resource_policy_json}" '' '' '' ''
assert_equals "null" "$(jq -r '.' "${resource_policy_json}")" "An unlimited policy was published as a policy object."
write_worker_resource_policy "${resource_policy_json}" 536870912 1073741824 2.5 256
assert_equals "536870912" "$(jq -r '.memoryBytes' "${resource_policy_json}")" "The published policy lost its memory limit."
assert_equals "1073741824" "$(jq -r '.memorySwapBytes' "${resource_policy_json}")" "The published policy lost its memory-swap limit."
assert_equals "2.5" "$(jq -r '.cpuCores' "${resource_policy_json}")" "The published policy did not keep canonical CPU cores as a string."
assert_equals "256" "$(jq -r '.pids' "${resource_policy_json}")" "The published policy lost its PID limit."
write_worker_resource_policy "${resource_policy_json}" '' '' '' 512
assert_equals "null" "$(jq -r '.memoryBytes' "${resource_policy_json}")" "An unconfigured memory limit was published as zero."
assert_equals "512" "$(jq -r '.pids' "${resource_policy_json}")" "A PID-only policy lost its configured limit."
assert_false \
    "An invalid policy was published." \
    write_worker_resource_policy "${resource_policy_json}" 1073741824 536870912 '' ''

exit_slot_directory="${TEMP_DIRECTORY}/exit-slot"
mkdir -p "${exit_slot_directory}"
exit_evidence_json="${exit_slot_directory}/last-exit.json"
classify_exit() {
    write_slot_exit_evidence "${exit_slot_directory}" "" "$1" "$2" "$3"
    jq -r '[.classification, (.exitCode | tostring), (.signal | tostring), (.dockerOomKilled | tostring), .evidence] | join(" ")' \
        "${exit_evidence_json}"
}
assert_equals \
    "clean 0 null false docker-inspect" \
    "$(classify_exit docker-inspect 0 false)" \
    "A clean worker exit was misclassified."
assert_equals \
    "error 2 null false docker-inspect" \
    "$(classify_exit docker-inspect 2 false)" \
    "An ordinary nonzero worker exit was misclassified."
assert_equals \
    "oom-killed 137 9 true docker-inspect" \
    "$(classify_exit docker-inspect 137 true)" \
    "A Docker-confirmed out-of-memory kill was misclassified."
assert_equals \
    "sigkill 137 9 false docker-inspect" \
    "$(classify_exit docker-inspect 137 false)" \
    "Status 137 without Docker out-of-memory evidence was not classified as a signal kill."
assert_equals \
    "sigkill 137 9 null docker-wait" \
    "$(classify_exit docker-wait 137 '')" \
    "Status 137 without Docker inspection evidence was claimed as an out-of-memory kill."
assert_equals \
    "signal 143 15 false docker-inspect" \
    "$(classify_exit docker-inspect 143 false)" \
    "A terminating signal exit was misclassified."
assert_equals \
    "launch-failure null null null launch" \
    "$(classify_exit launch '' '')" \
    "A worker launch failure was misclassified."
assert_equals \
    "unknown null null null unavailable" \
    "$(classify_exit unavailable '' '')" \
    "Missing Docker exit evidence was not surfaced as unknown."
assert_false \
    "Malformed Docker exit output was accepted as evidence." \
    write_slot_exit_evidence "${exit_slot_directory}" "" docker-wait "not-a-status" ""
assert_false \
    "An unknown exit evidence source was accepted." \
    write_slot_exit_evidence "${exit_slot_directory}" "" guessed 0 ""

assert_equals \
    "1450 0 0 8390" \
    "$(normalize_container_resource_usage \
        '{"CPUPerc":"1.00%","ID":"worker123","MemUsage":"32MiB / 32GiB","PIDs":"7","NetIO":"1.45kB / 0B","BlockIO":"0B / 8.39kB"}' |
        jq -r '[.networkRxBytes, .networkTxBytes, .blockReadBytes, .blockWriteBytes] | join(" ")')" \
    "Container I/O counters were not normalized to cumulative bytes."
assert_equals \
    "null null null null" \
    "$(normalize_container_resource_usage \
        '{"CPUPerc":"1.00%","ID":"worker123","MemUsage":"32MiB / 32GiB","PIDs":"7","NetIO":"-- / --","BlockIO":"--"}' |
        jq -r '[.networkRxBytes, .networkTxBytes, .blockReadBytes, .blockWriteBytes] | map(tostring) | join(" ")')" \
    "Unavailable container I/O counters were reported as zero."

assert_equals "0" "$(parse_size_bytes '0B')" "Byte parsing changed zero bytes."
assert_equals "44312822" "$(parse_size_bytes '42.26MiB')" "Byte parsing did not preserve Docker binary units."
assert_equals "0.125" "$(parse_cpu_cores '12.5%')" "CPU parsing did not convert Docker percent to cores."

json_condition_holds() {
    jq -e --argjson expected "${3:-null}" "$2" "$1" >/dev/null 2>&1
}

diagnostics_directory="${TEMP_DIRECTORY}/diagnostics"
journal_state="${diagnostics_directory}/journal.json"
docker_health_state="${diagnostics_directory}/subsystem-docker.json"
github_health_state="${diagnostics_directory}/subsystem-github.json"
assert_true "Operation diagnostics could not be initialized." \
    diagnostics_initialize "${diagnostics_directory}" manager-instance-a
assert_equals "current" "$(jq -r '.status' "${journal_state}")" "A fresh operation journal was not reported as current."
assert_equals "0" "$(jq -r '.events | length' "${journal_state}")" "A fresh operation journal retained events."
assert_equals "unknown" "$(jq -r '.state' "${docker_health_state}")" "A manager without Docker evidence claimed Docker health."
assert_equals "unknown" "$(jq -r '.state' "${github_health_state}")" "A manager without GitHub evidence claimed GitHub health."

record_manager_event "${diagnostics_directory}" manager-instance-a \
    telemetry telemetry-sample "" succeeded 40 none "" || true
assert_equals "1" "$(jq -r '.events | length' "${journal_state}")" "The first Docker success was not journaled as a state transition."
assert_equals "healthy" "$(jq -r '.state' "${docker_health_state}")" "A successful Docker operation did not report healthy."
record_manager_event "${diagnostics_directory}" manager-instance-a \
    telemetry telemetry-sample "" succeeded 40 none "" || true
record_manager_event "${diagnostics_directory}" manager-instance-a \
    telemetry telemetry-sample "" succeeded 40 none "" || true
assert_equals "1" "$(jq -r '.events | length' "${journal_state}")" "Healthy reconciliation churned the operation journal."

record_manager_event "${diagnostics_directory}" manager-instance-a \
    docker docker-inspect "" timed-out 5000 timeout "Managed worker discovery exceeded its deadline" || true
assert_equals "2" "$(jq -r '.events | length' "${journal_state}")" "A Docker timeout was not journaled."
assert_equals "timed-out" "$(jq -r '.events[-1].outcome' "${journal_state}")" "A Docker timeout lost its outcome."
assert_equals "degraded" "$(jq -r '.state' "${docker_health_state}")" "A failed Docker operation did not degrade Docker health."
assert_equals "1" "$(jq -r '.consecutiveFailures' "${docker_health_state}")" "A failed Docker operation lost its failure count."

record_manager_event "${diagnostics_directory}" manager-instance-a \
    worker-launch worker-launch repo-example-000001 retry-scheduled "" retry-backoff \
    "Worker slot is waiting for its launch backoff window" "2026-07-27T00:00:30Z" || true
assert_equals "retry-scheduled" "$(jq -r '.events[-1].outcome' "${journal_state}")" "A scheduled retry was not journaled."
assert_equals "2026-07-27T00:00:30Z" "$(jq -r '.events[-1].retryAt' "${journal_state}")" "A scheduled retry lost its retry timestamp."
assert_equals "repo-example-000001" "$(jq -r '.events[-1].target' "${journal_state}")" "A slot-scoped event lost its slot key."
assert_false \
    "A scheduled retry without a retry timestamp was accepted." \
    record_manager_event "${diagnostics_directory}" manager-instance-a \
        worker-launch worker-launch repo-example-000001 retry-scheduled "" retry-backoff "Missing retry window" ""
assert_false \
    "An operation outside the closed contract vocabulary was accepted." \
    record_manager_event "${diagnostics_directory}" manager-instance-a \
        docker docker-freeze "" failed "" unknown "Invented operation"

record_manager_event "${diagnostics_directory}" manager-instance-a \
    telemetry telemetry-sample "" succeeded 20 none "" || true
assert_equals "succeeded" "$(jq -r '.events[-1].outcome' "${journal_state}")" "Recovery after failure was not journaled."
assert_equals "recovered" "$(jq -r '.events[-1].reason' "${journal_state}")" "Recovery after failure lost its recovery reason."
assert_equals "healthy" "$(jq -r '.state' "${docker_health_state}")" "Recovery did not restore Docker health."
assert_equals "0" "$(jq -r '.consecutiveFailures' "${docker_health_state}")" "Recovery did not clear the Docker failure count."

registration_evidence_endpoint="https://api.github.com/repos/example/project/actions/runners"
record_manager_event "${diagnostics_directory}" manager-instance-a \
    registration runner-registration "" failed 900 unknown \
    "Inventory request to ${registration_evidence_endpoint} failed" || true
assert_equals \
    "Inventory request to https api.github.com repos example project actions runners failed" \
    "$(jq -r '.events[-1].evidence' "${journal_state}")" \
    "Journal evidence did not strip credential and URL punctuation."
assert_false "The operation journal exposed an access token field." \
    contains_access_token_field "${journal_state}"

journal_sequence_before=$(jq -r '.highestSequence' "${journal_state}")
journal_events_before=$(jq -r '.events | length' "${journal_state}")
assert_true "A manager restart could not restore its operation journal." \
    diagnostics_initialize "${diagnostics_directory}" manager-instance-b
assert_equals "${journal_sequence_before}" "$(jq -r '.highestSequence' "${journal_state}")" "Manager restart lost the durable journal sequence."
assert_equals "${journal_events_before}" "$(jq -r '.events | length' "${journal_state}")" "Manager restart lost retained journal events."
record_manager_event "${diagnostics_directory}" manager-instance-b \
    recovery manager-start "" recovered "" recovered "Manager adopted managed workers left by its predecessor" || true
assert_equals \
    "$((journal_sequence_before + 1))" \
    "$(jq -r '.highestSequence' "${journal_state}")" \
    "Adoption after restart did not continue the durable sequence."
assert_equals \
    "$(jq -r '[.events[].sequence] | unique | length' "${journal_state}")" \
    "$(jq -r '.events | length' "${journal_state}")" \
    "Adoption duplicated journal events."

journal_events_bounded=0
while [ "${journal_events_bounded}" -lt 40 ]; do
    record_manager_event "${diagnostics_directory}" manager-instance-b \
        reconciliation desired-state-apply "" succeeded "" none "Accepted a new desired capacity generation" || true
    journal_events_bounded=$((journal_events_bounded + 1))
done
assert_equals "32" "$(jq -r '.events | length' "${journal_state}")" "The operation journal exceeded its retained window."
assert_equals "truncated" "$(jq -r '.status' "${journal_state}")" "A trimmed operation journal was not reported as truncated."
assert_true \
    "A trimmed operation journal did not count dropped events." \
    json_condition_holds "${journal_state}" '.droppedEvents >= 1' 
assert_true \
    "The serialized operation journal exceeded its byte budget." \
    json_condition_holds "${journal_state}" \
        '({status, capacity, highestSequence, droppedEvents, events} | tojson | length) <= 16384' 

jq '.events[0] = {"sequence":"not-a-sequence"}' "${journal_state}" > "${journal_state}.malformed"
mv -f "${journal_state}.malformed" "${journal_state}"
dropped_before=$(jq -r '.droppedEvents' "${journal_state}")
assert_true "A malformed journal entry stopped diagnostics restore." \
    diagnostics_initialize "${diagnostics_directory}" manager-instance-c
assert_true \
    "A malformed journal entry was retained instead of discarded." \
    json_condition_holds "${journal_state}" '.droppedEvents > $expected' "${dropped_before}"
assert_equals \
    "journal-restore" \
    "$(jq -r '.events[-1].operation' "${journal_state}")" \
    "Discarding malformed journal entries was not reported."

printf '%s' 'this is not json' > "${journal_state}"
assert_true "A corrupt journal blocked manager diagnostics restore." \
    diagnostics_initialize "${diagnostics_directory}" manager-instance-d
assert_true \
    "A corrupt journal was reset without reporting the loss." \
    json_condition_holds "${journal_state}" '.droppedEvents >= 1' 
assert_equals \
    "journal-restore" \
    "$(jq -r '.events[-1].operation' "${journal_state}")" \
    "A corrupt journal reset was not reported as a journal restore failure."
assert_equals "healthy" "$(jq -r '.state' "${docker_health_state}")" "A corrupt journal discarded durable subsystem health."

unreadable_journal_directory="${TEMP_DIRECTORY}/unreadable-diagnostics"
mkdir -p "${unreadable_journal_directory}"
printf '%s' 'not json' > "${unreadable_journal_directory}/journal.json"
unreadable_journal_projection="${TEMP_DIRECTORY}/unreadable-journal.json"
render_operation_journal "${unreadable_journal_directory}" "${unreadable_journal_projection}"
assert_equals "unavailable" "$(jq -r '.status' "${unreadable_journal_projection}")" "An unreadable journal was not projected as unavailable."
assert_equals "0" "$(jq -r '.events | length' "${unreadable_journal_projection}")" "An unavailable journal projected events."

diagnostics_journal_projection="${TEMP_DIRECTORY}/operation-journal.json"
diagnostics_health_projection="${TEMP_DIRECTORY}/subsystem-health.json"
diagnostics_capacity_projection="${TEMP_DIRECTORY}/capacity-evidence.json"
render_operation_journal "${diagnostics_directory}" "${diagnostics_journal_projection}"
render_subsystem_health "${diagnostics_directory}" "${diagnostics_health_projection}"
assert_equals "healthy" "$(jq -r '.docker.state' "${diagnostics_health_projection}")" "The published Docker summary lost its state."
assert_true \
    "The published subsystem summary exposed unexpected fields." \
    json_condition_holds "${diagnostics_health_projection}" \
        '[.docker, .github] | all(keys == ["consecutiveFailures", "lastFailure", "lastSuccess", "observedAt", "retryAt", "state"])' 

capacity_slots_json="${TEMP_DIRECTORY}/capacity-slots.json"
cat > "${capacity_slots_json}" <<'EOF'
[
  {"key":"repo-example-000001","desired":true,"processRunning":true,"state":"online","registrationStatus":"connected"},
  {"key":"repo-example-000002","desired":true,"processRunning":true,"state":"backoff","registrationStatus":"registration-missing"}
]
EOF
render_fixed_capacity_evidence \
    "${capacity_slots_json}" \
    2 \
    accepted \
    "${diagnostics_health_projection}" \
    "${diagnostics_capacity_projection}"
assert_equals "2" "$(jq -r '.fixed.targetSlots' "${diagnostics_capacity_projection}")" "Capacity evidence did not use the accepted desired slot count."
assert_equals "1" "$(jq -r '.fixed.activeWorkers' "${diagnostics_capacity_projection}")" "Capacity evidence miscounted local workers."
assert_equals "1" "$(jq -r '.fixed.localDeficit' "${diagnostics_capacity_projection}")" "Capacity evidence lost the local shortfall."
assert_equals "retry-backoff" "$(jq -r '.fixed.reason' "${diagnostics_capacity_projection}")" "A shortfall did not report the manager's observed blocking state."
assert_equals "1" "$(jq -r '.fixed.cleanupPendingWorkers' "${diagnostics_capacity_projection}")" "Capacity evidence lost cleanup-pending workers."
assert_equals "0" "$(jq -r '.fixed.targets | length' "${diagnostics_capacity_projection}")" "A fixed profile published autoscaling target evidence."

unknown_github_health="${TEMP_DIRECTORY}/unknown-github-health.json"
jq '.github = {state:"unknown", observedAt:"2026-07-27T00:00:00Z", consecutiveFailures:0, retryAt:null, lastSuccess:null, lastFailure:null}' \
    "${diagnostics_health_projection}" > "${unknown_github_health}"
render_fixed_capacity_evidence \
    "${capacity_slots_json}" \
    2 \
    accepted \
    "${unknown_github_health}" \
    "${diagnostics_capacity_projection}"
assert_equals "null" "$(jq -r '.fixed.eligibleWorkers' "${diagnostics_capacity_projection}")" "Unavailable GitHub eligibility was reported as an observed count."
assert_equals "null" "$(jq -r '.fixed.eligibilityDeficit' "${diagnostics_capacity_projection}")" "Unavailable GitHub eligibility produced an eligibility shortfall."

invalid_desired_capacity="${TEMP_DIRECTORY}/invalid-desired-capacity.json"
render_fixed_capacity_evidence \
    "${capacity_slots_json}" \
    2 \
    invalid \
    "${diagnostics_health_projection}" \
    "${invalid_desired_capacity}"
assert_equals "invalid-desired-state" "$(jq -r '.fixed.reason' "${invalid_desired_capacity}")" "A rejected desired state was not reported as the blocking reason."

satisfied_capacity="${TEMP_DIRECTORY}/satisfied-capacity.json"
satisfied_slots_json="${TEMP_DIRECTORY}/satisfied-slots.json"
jq '[.[0], (.[1] | .state = "online" | .registrationStatus = "connected")]' \
    "${capacity_slots_json}" > "${satisfied_slots_json}"
render_fixed_capacity_evidence \
    "${satisfied_slots_json}" \
    2 \
    accepted \
    "${diagnostics_health_projection}" \
    "${satisfied_capacity}"
assert_equals "none" "$(jq -r '.fixed.reason' "${satisfied_capacity}")" "Satisfied capacity reported a deficit reason."
assert_equals "0" "$(jq -r '.fixed.localDeficit' "${satisfied_capacity}")" "Satisfied capacity reported a local shortfall."
assert_equals "2" "$(jq -r '.fixed.eligibleWorkers' "${satisfied_capacity}")" "Satisfied capacity lost observed GitHub eligibility."

contract_twelve_state_json="${TEMP_DIRECTORY}/contract-twelve-state.json"
write_manager_observed_state \
    "${contract_twelve_state_json}" \
    default \
    manager-instance \
    12 \
    running \
    repo \
    9 \
    state-hash \
    accepted \
    2 \
    "${contract_eleven_slots_json}" \
    "${contract_eleven_telemetry_json}" \
    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    1 \
    "${contract_eleven_policy_json}" \
    "${diagnostics_journal_projection}" \
    "${diagnostics_health_projection}" \
    "${satisfied_capacity}"
assert_true "Contract-twelve observed manager state was rejected." observed_state_is_valid "${contract_twelve_state_json}"
assert_equals "truncated" "$(jq -r '.operationJournal.status' "${contract_twelve_state_json}")" "Observed state lost the operation journal status."
assert_equals "healthy" "$(jq -r '.subsystemHealth.docker.state' "${contract_twelve_state_json}")" "Observed state lost Docker subsystem health."
assert_equals "2" "$(jq -r '.capacityEvidence.fixed.targetSlots' "${contract_twelve_state_json}")" "Observed state lost fixed capacity evidence."
assert_false "Contract-twelve observed state exposed an access token field." \
    contains_access_token_field "${contract_twelve_state_json}"
assert_false "Contract-twelve observed state exposed runner names or derived tags." \
    contains_runner_identity_field "${contract_twelve_state_json}"

invalid_contract_twelve_state="${TEMP_DIRECTORY}/invalid-contract-twelve-state.json"
jq 'del(.operationJournal)' "${contract_twelve_state_json}" > "${invalid_contract_twelve_state}"
assert_false "Manager contract twelve accepted a missing operation journal." observed_state_is_valid "${invalid_contract_twelve_state}"
jq 'del(.subsystemHealth)' "${contract_twelve_state_json}" > "${invalid_contract_twelve_state}"
assert_false "Manager contract twelve accepted missing subsystem health." observed_state_is_valid "${invalid_contract_twelve_state}"
jq 'del(.capacityEvidence)' "${contract_twelve_state_json}" > "${invalid_contract_twelve_state}"
assert_false "Manager contract twelve accepted missing capacity evidence." observed_state_is_valid "${invalid_contract_twelve_state}"
jq '.capacityEvidence.fixed = null' "${contract_twelve_state_json}" > "${invalid_contract_twelve_state}"
assert_false "A fixed profile published null capacity evidence." observed_state_is_valid "${invalid_contract_twelve_state}"
jq '.operationJournal.events[0].evidence = "token: https://example.com?x=1"' \
    "${contract_twelve_state_json}" > "${invalid_contract_twelve_state}"
assert_false "Observed state accepted unsanitized journal evidence." observed_state_is_valid "${invalid_contract_twelve_state}"
jq '.operationJournal.events[0].operation = "docker-freeze"' \
    "${contract_twelve_state_json}" > "${invalid_contract_twelve_state}"
assert_false "Observed state accepted an operation outside the closed vocabulary." observed_state_is_valid "${invalid_contract_twelve_state}"
jq '.operationJournal.status = "unavailable"' "${contract_twelve_state_json}" > "${invalid_contract_twelve_state}"
assert_false "An unavailable journal published retained events." observed_state_is_valid "${invalid_contract_twelve_state}"
jq '.subsystemHealth.github.state = "healthy"' "${contract_twelve_state_json}" > "${invalid_contract_twelve_state}"
assert_false "A healthy subsystem summary was accepted without a last success." observed_state_is_valid "${invalid_contract_twelve_state}"
jq '.capacityEvidence.fixed.localDeficit = 1' "${contract_twelve_state_json}" > "${invalid_contract_twelve_state}"
assert_false "A shortfall was accepted without an observed reason." observed_state_is_valid "${invalid_contract_twelve_state}"
jq '.capacityEvidence.fixed.eligibleWorkers = null' "${contract_twelve_state_json}" > "${invalid_contract_twelve_state}"
assert_false "Unavailable eligibility was accepted with an eligibility shortfall." observed_state_is_valid "${invalid_contract_twelve_state}"

legacy_contract_twelve_state="${TEMP_DIRECTORY}/legacy-contract-twelve-state.json"
jq '.managerContractVersion = 10' "${contract_twelve_state_json}" > "${legacy_contract_twelve_state}"
assert_true \
    "Additive contract-twelve evidence was rejected for an older active contract." \
    observed_state_is_valid "${legacy_contract_twelve_state}"

PATH="${fake_docker_directory}:${PATH}" \
    collect_host_hardware \
        "${host_hardware}" \
        1 \
        "${cpuinfo_fixture}" \
        "${kernel_fixture}" \
        x86_64
contract_thirteen_state_json="${TEMP_DIRECTORY}/contract-thirteen-state.json"
write_manager_observed_state \
    "${contract_thirteen_state_json}" \
    default \
    manager-instance \
    13 \
    running \
    repo \
    9 \
    state-hash \
    accepted \
    2 \
    "${contract_eleven_slots_json}" \
    "${contract_eleven_telemetry_json}" \
    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    1 \
    "${contract_eleven_policy_json}" \
    "${diagnostics_journal_projection}" \
    "${diagnostics_health_projection}" \
    "${satisfied_capacity}" \
    example/runner:1.0 \
    sha256:1111111111111111111111111111111111111111111111111111111111111111 \
    "${host_hardware}"
assert_true "Contract-thirteen observed manager state was rejected." observed_state_is_valid "${contract_thirteen_state_json}"
assert_equals "current" "$(jq -r '.host.hardware.status' "${contract_thirteen_state_json}")" "Observed state lost hardware freshness."
assert_equals "Example Processor 9000" "$(jq -r '.host.hardware.processorModel' "${contract_thirteen_state_json}")" "Observed state lost processor identity."
assert_equals "16" "$(jq -r '.host.hardware.logicalProcessorCount' "${contract_thirteen_state_json}")" "Observed state lost logical processor topology."
assert_false "Contract-thirteen observed state exposed an access token field." \
    contains_access_token_field "${contract_thirteen_state_json}"
assert_false "Contract-thirteen observed state exposed runner names or derived tags." \
    contains_runner_identity_field "${contract_thirteen_state_json}"

invalid_contract_thirteen_state="${TEMP_DIRECTORY}/invalid-contract-thirteen-state.json"
jq 'del(.host)' "${contract_thirteen_state_json}" > "${invalid_contract_thirteen_state}"
assert_false "Manager contract thirteen accepted missing host hardware." observed_state_is_valid "${invalid_contract_thirteen_state}"
jq '.host.hardware.status = "unavailable"' "${contract_thirteen_state_json}" > "${invalid_contract_thirteen_state}"
assert_false "Unavailable hardware retained inventory values." observed_state_is_valid "${invalid_contract_thirteen_state}"
jq '.host.hardware.processorModel = "line\u000abreak"' "${contract_thirteen_state_json}" > "${invalid_contract_thirteen_state}"
assert_false "Host hardware accepted control characters." observed_state_is_valid "${invalid_contract_thirteen_state}"

legacy_contract_thirteen_state="${TEMP_DIRECTORY}/legacy-contract-thirteen-state.json"
jq '.managerContractVersion = 12' "${contract_thirteen_state_json}" > "${legacy_contract_thirteen_state}"
assert_true \
    "Additive host hardware was rejected for an older active contract." \
    observed_state_is_valid "${legacy_contract_thirteen_state}"

contract_fourteen_state_json="${TEMP_DIRECTORY}/contract-fourteen-state.json"
write_manager_observed_state \
    "${contract_fourteen_state_json}" \
    default \
    manager-instance \
    14 \
    running \
    repo \
    9 \
    state-hash \
    accepted \
    2 \
    "${contract_eleven_slots_json}" \
    "${contract_eleven_telemetry_json}" \
    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    1 \
    "${contract_eleven_policy_json}" \
    "${diagnostics_journal_projection}" \
    "${diagnostics_health_projection}" \
    "${satisfied_capacity}" \
    example/runner:1.0 \
    sha256:1111111111111111111111111111111111111111111111111111111111111111 \
    "${host_hardware}"
assert_true "Contract-fourteen observed manager state was rejected." \
    observed_state_is_valid "${contract_fourteen_state_json}"
assert_equals \
    "0727c7f1ee3b997f55b1e49ce0c39dac6d146e2af8803d1983d2d6ed2ac744b6" \
    "$(jq -r '.slots[] | select(.key == "repo-example-000001") | .runnerNameHash' "${contract_fourteen_state_json}")" \
    "Fixed observed state did not hash the exact first runner name."
assert_equals \
    "null" \
    "$(jq -r '.slots[] | select(.key == "repo-example-000002") | .runnerNameHash' "${contract_fourteen_state_json}")" \
    "A draining launch-backoff slot published a stale runner-name hash."
assert_false "Contract-fourteen observed state exposed raw runner or container identity." \
    contains_runner_identity_field "${contract_fourteen_state_json}"

invalid_contract_fourteen_state="${TEMP_DIRECTORY}/invalid-contract-fourteen-state.json"
jq 'del(.slots[0].runnerNameHash)' "${contract_fourteen_state_json}" > "${invalid_contract_fourteen_state}"
assert_false "Manager contract fourteen accepted a missing runner-name hash." \
    observed_state_is_valid "${invalid_contract_fourteen_state}"
jq '.slots[0].runnerNameHash = null' "${contract_fourteen_state_json}" > "${invalid_contract_fourteen_state}"
assert_true "Contract-fourteen rejected an explicitly unavailable runner-name hash." \
    observed_state_is_valid "${invalid_contract_fourteen_state}"
jq '.slots[0].runnerNameHash = "ABC"' "${contract_fourteen_state_json}" > "${invalid_contract_fourteen_state}"
assert_false "Manager contract fourteen accepted a malformed runner-name hash." \
    observed_state_is_valid "${invalid_contract_fourteen_state}"

legacy_contract_fourteen_state="${TEMP_DIRECTORY}/legacy-contract-fourteen-state.json"
jq '.managerContractVersion = 13 | del(.slots[].runnerNameHash)' \
    "${contract_fourteen_state_json}" > "${legacy_contract_fourteen_state}"
assert_true \
    "Observed-state validation rejected a contract-thirteen slot without runner correlation." \
    observed_state_is_valid "${legacy_contract_fourteen_state}"

contract_fifteen_state_json="${TEMP_DIRECTORY}/contract-fifteen-state.json"
write_manager_observed_state \
    "${contract_fifteen_state_json}" \
    default \
    manager-instance \
    15 \
    running \
    repo \
    9 \
    state-hash \
    accepted \
    2 \
    "${contract_eleven_slots_json}" \
    "${contract_eleven_telemetry_json}" \
    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    1 \
    "${contract_eleven_policy_json}" \
    "${diagnostics_journal_projection}" \
    "${diagnostics_health_projection}" \
    "${satisfied_capacity}" \
    example/runner:1.0 \
    sha256:1111111111111111111111111111111111111111111111111111111111111111 \
    "${host_hardware}"
assert_true "Contract-fifteen observed manager state was rejected." \
    observed_state_is_valid "${contract_fifteen_state_json}"
assert_equals \
    "0" \
    "$(jq '[.slots[] | select(.currentJob != null)] | length' "${contract_fifteen_state_json}")" \
    "Fixed manager fabricated active job context."

invalid_contract_fifteen_state="${TEMP_DIRECTORY}/invalid-contract-fifteen-state.json"
jq 'del(.slots[0].currentJob)' \
    "${contract_fifteen_state_json}" > "${invalid_contract_fifteen_state}"
assert_false "Manager contract fifteen accepted missing job availability." \
    observed_state_is_valid "${invalid_contract_fifteen_state}"
jq '
    .slots[0].activity = "busy"
    | .slots[0].currentJob = {
        repository: "https://github.com/example/project",
        workflowRunId: 31068390178,
        jobId: "92513140749",
        displayName: "Android debug build",
        eventName: "pull_request",
        queuedAt: "2026-08-06T03:40:00Z",
        scaleSetAssignedAt: "2026-08-06T03:41:00Z",
        runnerAssignedAt: "2026-08-06T03:41:30Z",
        startedAt: "2026-08-06T03:42:03Z",
        finishedAt: null,
        result: null
    }
' "${contract_fifteen_state_json}" > "${invalid_contract_fifteen_state}"
assert_true "Manager contract fifteen rejected bounded job context." \
    observed_state_is_valid "${invalid_contract_fifteen_state}"
jq '.slots[0].currentJob.workflowRef = "private-ref"' \
    "${invalid_contract_fifteen_state}" > "${invalid_contract_fifteen_state}.raw"
assert_false "Manager contract fifteen accepted an unsupported workflow payload." \
    observed_state_is_valid "${invalid_contract_fifteen_state}.raw"
jq '.slots[0].currentJob.jobId = "not-a-job-id"' \
    "${invalid_contract_fifteen_state}" > "${invalid_contract_fifteen_state}.bad-id"
assert_false "Manager contract fifteen accepted a malformed job identifier." \
    observed_state_is_valid "${invalid_contract_fifteen_state}.bad-id"

legacy_contract_fifteen_state="${TEMP_DIRECTORY}/legacy-contract-fifteen-state.json"
jq '.managerContractVersion = 14 | del(.slots[].currentJob)' \
    "${contract_fifteen_state_json}" > "${legacy_contract_fifteen_state}"
assert_true \
    "Observed-state validation rejected a contract-fourteen slot without job context." \
    observed_state_is_valid "${legacy_contract_fifteen_state}"

echo "Manager reconciliation contracts passed: ${ASSERTIONS} assertions."
