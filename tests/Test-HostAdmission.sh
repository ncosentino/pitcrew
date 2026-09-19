#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
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
    [ "${expected}" = "${actual}" ] ||
        fail "${message} Expected '${expected}', got '${actual}'."
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

admission_cli="${TEMP_DIRECTORY}/pitcrew-admission"
admission_calls="${TEMP_DIRECTORY}/admission-calls.log"
adoption_attempt="${TEMP_DIRECTORY}/adoption-attempt"
cat > "${admission_cli}" <<'EOF'
#!/bin/sh
command="$1"
shift
profile=""
slot=""
demand=""
runner_name=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --profile) profile="$2"; shift 2 ;;
        --slot) slot="$2"; shift 2 ;;
        --demand) demand="$2"; shift 2 ;;
        --runner-name) runner_name="$2"; shift 2 ;;
        --socket) shift 2 ;;
        --evidence) shift 2 ;;
        *) shift ;;
    esac
done
printf '%s|%s|%s|%s|%s\n' \
    "${command}" "${profile}" "${slot}" "${demand}" "${runner_name}" \
    >> "${PITCREW_TEST_ADMISSION_CALLS}"
case "${command}:${PITCREW_TEST_ADMISSION_MODE:-success}" in
    acquire:withheld) exit 3 ;;
    acquire:degraded|activate:degraded|adopt:degraded) exit 5 ;;
    acquire:error|adopt:error|release:error|reconcile:error) exit 1 ;;
    adopt:flaky)
        if [ ! -f "${PITCREW_TEST_ADOPTION_ATTEMPT}" ]; then
            : > "${PITCREW_TEST_ADOPTION_ATTEMPT}"
            exit 1
        fi
        ;;
    release:not-found|reconcile:not-found) exit 4 ;;
esac
case "${command}" in
    acquire)
        printf '{"profileId":"%s","slotKey":"%s","leaseId":"lease-1","units":2,"status":"provisional"}\n' \
            "${profile}" "${slot}"
        ;;
    status)
        if [ -n "${PITCREW_TEST_STATUS_SNAPSHOT:-}" ]; then
            cat "${PITCREW_TEST_STATUS_SNAPSHOT}"
        else
            exit 1
        fi
        ;;
    activate|adopt)
        printf '{"profileId":"%s","slotKey":"%s","leaseId":"lease-1","units":2,"status":"active"}\n' \
            "${profile}" "${slot}"
        ;;
esac
EOF
chmod +x "${admission_cli}"

docker_calls="${TEMP_DIRECTORY}/docker-calls.log"
cat > "${TEMP_DIRECTORY}/docker" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${PITCREW_TEST_DOCKER_CALLS}"
if [ "${PITCREW_TEST_DOCKER_SLEEP:-0}" -gt 0 ]; then
    sleep "${PITCREW_TEST_DOCKER_SLEEP}"
fi
if [ "$1" = "inspect" ]; then
    printf '%s\n' "true"
    exit 0
fi
exit 1
EOF
chmod +x "${TEMP_DIRECTORY}/docker"

PROFILE_ID="control"
PITCREW_HOST_ADMISSION_NAMESPACE="primary"
PITCREW_HOST_ADMISSION_SOCKET="/var/lib/pitcrew-admission/coordinator.sock"
PITCREW_HOST_ADMISSION_CLI="${admission_cli}"
PITCREW_HOST_ADMISSION_CLI_TIMEOUT=2
PITCREW_HOST_ADMISSION_RELEASE_DIRECTORY="${TEMP_DIRECTORY}/pending-releases"
PITCREW_HOST_ADMISSION_ADOPTION_DIRECTORY="${TEMP_DIRECTORY}/pending-adoptions"
PITCREW_TEST_ADMISSION_CALLS="${admission_calls}"
PITCREW_TEST_ADOPTION_ATTEMPT="${adoption_attempt}"
PITCREW_TEST_DOCKER_CALLS="${docker_calls}"
export \
    PROFILE_ID \
    PITCREW_HOST_ADMISSION_NAMESPACE \
    PITCREW_HOST_ADMISSION_SOCKET \
    PITCREW_HOST_ADMISSION_CLI \
    PITCREW_HOST_ADMISSION_CLI_TIMEOUT \
    PITCREW_HOST_ADMISSION_RELEASE_DIRECTORY \
    PITCREW_HOST_ADMISSION_ADOPTION_DIRECTORY \
    PITCREW_TEST_ADMISSION_CALLS \
    PITCREW_TEST_ADOPTION_ATTEMPT \
    PITCREW_TEST_DOCKER_CALLS
. "${ROOT}/manager/host-admission.sh"

manager_source="${ROOT}/manager/manage-runners.sh"
assert_true \
    "Fixed manager does not load the shared host-admission client." \
    grep -Fq '. "${SCRIPT_DIRECTORY}/host-admission.sh"' "${manager_source}"
assert_true \
    "Fixed manager does not validate host-admission environment before reconciliation." \
    grep -Fq 'host_admission_configuration_is_valid' "${manager_source}"
assert_true \
    "Fixed manager still starts admitted workers before lease activation." \
    grep -Fq 'set -- docker create --rm' "${manager_source}"
assert_true \
    "Fixed manager does not activate leases before Docker start." \
    grep -Fq 'host_admission_activate' "${manager_source}"
assert_true \
    "Fixed manager recovery does not adopt already-running workers." \
    grep -Fq 'host_admission_adopt_running' "${manager_source}"
assert_true \
    "Fixed manager recovery does not establish a coordinator adoption fence." \
    grep -Fq 'host_admission_begin_adoption' "${manager_source}"
assert_true \
    "Fixed manager does not bind exact runner registration identity to leases." \
    grep -Fq 'host_admission_bind_registration' "${manager_source}"
assert_true \
    "Fixed manager does not reconcile coordinator leases absent from Docker." \
    grep -Fq 'reconcile_orphaned_host_admission_leases' "${manager_source}"
assert_true \
    "Fixed manager recovery can block forever while tracked adoptions finish." \
    grep -Fq 'host_admission_wait_for_tracked_adoptions' "${manager_source}"
assert_false \
    "Fixed manager still has an unbounded tracked-adoption startup loop." \
    grep -Fq 'while host_admission_adoption_pending; do' "${manager_source}"
assert_true \
    "Fixed manager recovery ignores created worker containers." \
    grep -Fq 'docker ps -aq --filter "label=${MANAGED_LABEL}"' "${manager_source}"
assert_true \
    "Fixed manager recovery discovery can block forever on Docker." \
    grep -Fq 'host_admission_recovery_docker ps -aq' "${manager_source}"
assert_true \
    "Fixed manager retries orphan reconciliation while tracked adoption is unresolved." \
    grep -Fq 'if host_admission_adoption_pending; then' "${manager_source}"
assert_true \
    "Fixed manager drain can hang forever while the coordinator is unavailable." \
    grep -Fq 'active lease remains fenced' "${manager_source}"
assert_true \
    "Recovered draining slots do not clear pending host demand before return." \
    grep -Fq 'host_admission_end_wait \' "${manager_source}"
assert_true \
    "Fixed admission implementation did not activate manager contract twenty-one." \
    grep -Fq 'MANAGER_CONTRACT_VERSION=22' "${manager_source}"

mkdir -p "${PITCREW_HOST_ADMISSION_ADOPTION_DIRECTORY}"
: > "${PITCREW_HOST_ADMISSION_ADOPTION_DIRECTORY}/control-1.pending"
assert_false \
    "Tracked adoption wait accepted a still-pending marker after its deadline." \
    host_admission_wait_for_tracked_adoptions 0
rm -f "${PITCREW_HOST_ADMISSION_ADOPTION_DIRECTORY}/control-1.pending"
assert_true \
    "Tracked adoption wait rejected an empty marker set." \
    host_admission_wait_for_tracked_adoptions 0
: > "${PITCREW_HOST_ADMISSION_ADOPTION_DIRECTORY}/control-1.pending"
(
    sleep 1
    rm -f "${PITCREW_HOST_ADMISSION_ADOPTION_DIRECTORY}/control-1.pending"
) &
adoption_settle_pid=$!
assert_true \
    "Tracked adoption wait did not observe bounded convergence." \
    host_admission_wait_for_tracked_adoptions 2
wait "${adoption_settle_pid}"

disabled_calls="${TEMP_DIRECTORY}/disabled-calls.log"
: > "${disabled_calls}"
(
    unset \
        PITCREW_HOST_ADMISSION_NAMESPACE \
        PITCREW_HOST_ADMISSION_SOCKET
    PROFILE_ID="default"
    PITCREW_HOST_ADMISSION_CLI="${admission_cli}"
    PITCREW_TEST_ADMISSION_CALLS="${disabled_calls}"
    export PROFILE_ID PITCREW_HOST_ADMISSION_CLI PITCREW_TEST_ADMISSION_CALLS
    . "${ROOT}/manager/host-admission.sh"
    host_admission_configuration_is_valid
    disabled_slot="${TEMP_DIRECTORY}/disabled-slot"
    mkdir -p "${disabled_slot}"
    host_admission_acquire "${disabled_slot}" "default-1" "${TEMP_DIRECTORY}"
)
assert_false \
    "Disabled host admission invoked the coordinator client." \
    test -s "${disabled_calls}"

host_admission_bind_registration "control-1" "control-runner-1"
assert_true \
    "Registration binding did not carry the exact profile, lease, and runner name." \
    grep -Fq 'bind-registration|control|control-1||control-runner-1' \
        "${admission_calls}"

pending_snapshot="${TEMP_DIRECTORY}/pending-adoption-snapshot.json"
cat > "${pending_snapshot}" <<'EOF'
{
  "adoptionFences": [
    {
      "profileId": "control",
      "pendingLeaseKeys": ["control-1"]
    }
  ],
  "leases": [
    {
      "profileId": "control",
      "slotKey": "control-1",
      "leaseId": "lease-1",
      "registrationName": "control-runner-1",
      "units": 2,
      "status": "active"
    }
  ]
}
EOF
pending_inventory="${TEMP_DIRECTORY}/pending-adoption-inventory.json"
PITCREW_TEST_STATUS_SNAPSHOT="${pending_snapshot}"
export PITCREW_TEST_STATUS_SNAPSHOT
host_admission_pending_lease_inventory "${pending_inventory}"
assert_true \
    "Pending adoption inventory omitted the exact lease and registration binding." \
    jq -e '
        length == 1
        and .[0].slotKey == "control-1"
        and .[0].registrationName == "control-runner-1"
    ' "${pending_inventory}" >/dev/null

accounted_snapshot="${TEMP_DIRECTORY}/accounted-adoption-snapshot.json"
jq '.adoptionFences[0].pendingLeaseKeys = []' \
    "${pending_snapshot}" > "${accounted_snapshot}"
PITCREW_TEST_STATUS_SNAPSHOT="${accounted_snapshot}"
export PITCREW_TEST_STATUS_SNAPSHOT
host_admission_pending_lease_inventory "${pending_inventory}"
assert_true \
    "An accounted adoption fence did not expose an empty pending inventory." \
    jq -e 'type == "array" and length == 0' "${pending_inventory}" >/dev/null

malformed_pending_snapshot="${TEMP_DIRECTORY}/malformed-pending-adoption-snapshot.json"
jq '.leases = []' "${pending_snapshot}" > "${malformed_pending_snapshot}"
PITCREW_TEST_STATUS_SNAPSHOT="${malformed_pending_snapshot}"
export PITCREW_TEST_STATUS_SNAPSHOT
assert_false \
    "Pending adoption inventory accepted a fence without its active lease." \
    host_admission_pending_lease_inventory "${pending_inventory}"
unset PITCREW_TEST_STATUS_SNAPSHOT

assert_true \
    "Host-admission environment rejected a complete manager configuration." \
    host_admission_configuration_is_valid

admission_slots="${TEMP_DIRECTORY}/admission-slots"
admission_slot="${admission_slots}/control-1"
mkdir -p "${admission_slot}"
: > "${admission_calls}"
assert_true \
    "Fixed manager could not establish the host-wide adoption fence." \
    host_admission_begin_adoption
assert_true \
    "Fixed manager did not send the profile-scoped begin-adoption command." \
    grep -q '^begin-adoption|control||' "${admission_calls}"
assert_true \
    "Fixed manager could not clear the host-wide adoption fence." \
    host_admission_complete_adoption
assert_true \
    "Fixed manager did not send the profile-scoped complete-adoption command." \
    grep -q '^complete-adoption|control||' "${admission_calls}"

: > "${admission_calls}"
host_admission_begin_wait "${admission_slot}" "${admission_slots}"
assert_true \
    "Waiting fixed slot did not publish one unit of pending demand." \
    grep -Fqx 'set-demand|control||1|' "${admission_calls}"
assert_true \
    "Fixed slot could not acquire a synthetic host-admission lease." \
    host_admission_acquire "${admission_slot}" "control-1" "${admission_slots}"
assert_false \
    "Successful host admission retained the waiting marker." \
    test -f "${admission_slot}/${HOST_ADMISSION_WAIT_MARKER}"
assert_true \
    "Successful host admission did not persist its exact provisional lease." \
    jq -e '.profileId == "control" and .slotKey == "control-1" and .status == "provisional"' \
        "${admission_slot}/${HOST_ADMISSION_LEASE_FILE}"
assert_true \
    "Fixed slot could not activate its provisional host-admission lease." \
    host_admission_activate "${admission_slot}" "control-1"
assert_true \
    "Activated host-admission lease was not persisted." \
    jq -e '.status == "active"' "${admission_slot}/${HOST_ADMISSION_LEASE_FILE}"
assert_true \
    "Fixed slot could not release its active host-admission lease." \
    host_admission_release "${admission_slot}" "control-1"
assert_false \
    "Released host-admission lease file remained in slot state." \
    test -f "${admission_slot}/${HOST_ADMISSION_LEASE_FILE}"

: > "${admission_calls}"
rm -f "${adoption_attempt}"
PITCREW_TEST_ADMISSION_MODE="flaky"
export PITCREW_TEST_ADMISSION_MODE
PATH="${TEMP_DIRECTORY}:${PATH}"
export PATH
CONTAINER_MONITOR_KILL_AFTER_SECONDS=1
RECOVERY_DOCKER_COMMAND_TIMEOUT=1
PITCREW_TEST_DOCKER_SLEEP=3
export \
    CONTAINER_MONITOR_KILL_AFTER_SECONDS \
    RECOVERY_DOCKER_COMMAND_TIMEOUT \
    PITCREW_TEST_DOCKER_SLEEP
assert_false \
    "Recovered-worker Docker probes remained unbounded." \
    host_admission_recovery_docker inspect recovered-container
PITCREW_TEST_DOCKER_SLEEP=0
export PITCREW_TEST_DOCKER_SLEEP
assert_true \
    "Fixed running-worker adoption did not retry after a transient coordinator outage." \
    host_admission_adopt_running \
        "${admission_slot}" \
        "control-1" \
        "legacy-container" \
        "legacy-runner" \
        0
assert_equals \
    "2" \
    "$(grep -c '^adopt|control|control-1|' "${admission_calls}")" \
    "Fixed running-worker adoption did not retry the same deterministic slot identity."
assert_true \
    "Fixed running-worker adoption did not bind its exact registration name." \
    grep -Fq 'bind-registration|control|control-1||legacy-runner' \
        "${admission_calls}"
assert_true \
    "Fixed running-worker adoption did not persist an active lease." \
    jq -e '.slotKey == "control-1" and .status == "active"' \
        "${admission_slot}/${HOST_ADMISSION_LEASE_FILE}"
assert_false \
    "Fixed running-worker adoption attempted worker removal." \
    grep -Eq '(^| )rm( |$)|(^| )stop( |$)' "${docker_calls}"
PITCREW_TEST_ADMISSION_MODE="success"
export PITCREW_TEST_ADMISSION_MODE
assert_true \
    "Fixed adopted lease did not release on natural worker exit." \
    host_admission_release "${admission_slot}" "control-1"
assert_false \
    "Released fixed adopted lease remained in slot state." \
    test -f "${admission_slot}/${HOST_ADMISSION_LEASE_FILE}"

PITCREW_TEST_ADMISSION_MODE="withheld"
export PITCREW_TEST_ADMISSION_MODE
set +e
host_admission_acquire "${admission_slot}" "control-1" "${admission_slots}"
withheld_status=$?
set -e
assert_equals \
    "2" \
    "${withheld_status}" \
    "Host budget denial did not return the fixed-manager withheld status."
assert_true \
    "Withheld fixed slot lost its pending-demand marker." \
    test -f "${admission_slot}/${HOST_ADMISSION_WAIT_MARKER}"
assert_equals \
    "withheld" \
    "$(host_admission_wait_state "${admission_slots}")" \
    "Host budget denial did not retain a bounded withheld reason."

PITCREW_TEST_ADMISSION_MODE="error"
export PITCREW_TEST_ADMISSION_MODE
set +e
host_admission_acquire "${admission_slot}" "control-1" "${admission_slots}"
unavailable_status=$?
set -e
assert_equals \
    "1" \
    "${unavailable_status}" \
    "Coordinator failure did not return the fixed-manager unavailable status."
assert_equals \
    "unavailable" \
    "$(host_admission_wait_state "${admission_slots}")" \
    "Coordinator failure did not retain a bounded unavailable reason."

PITCREW_TEST_ADMISSION_MODE="degraded"
export PITCREW_TEST_ADMISSION_MODE
set +e
host_admission_acquire "${admission_slot}" "control-1" "${admission_slots}"
degraded_status=$?
set -e
assert_equals \
    "3" \
    "${degraded_status}" \
    "Policy mismatch did not return the fixed-manager degraded status."
assert_equals \
    "degraded" \
    "$(host_admission_wait_state "${admission_slots}")" \
    "Policy mismatch did not retain a bounded degraded reason."

PITCREW_TEST_ADMISSION_MODE="not-found"
export PITCREW_TEST_ADMISSION_MODE
assert_true \
    "Missing lease was not treated as already released." \
    host_admission_release "${admission_slot}" "control-1"
assert_true \
    "Missing lease was not treated as already reconciled." \
    host_admission_reconcile_absent "${admission_slot}" "control-1"

PITCREW_TEST_ADMISSION_MODE="error"
export PITCREW_TEST_ADMISSION_MODE
set +e
host_admission_release_or_queue "${admission_slot}" "control-1"
queued_status=$?
set -e
assert_equals \
    "1" \
    "${queued_status}" \
    "Coordinator release failure did not report a pending cleanup."
assert_true \
    "Coordinator release failure did not persist the exact slot key." \
    test -f "${PITCREW_HOST_ADMISSION_RELEASE_DIRECTORY}/control-1.pending"

PITCREW_TEST_ADMISSION_MODE="success"
export PITCREW_TEST_ADMISSION_MODE
host_admission_retry_releases
assert_false \
    "Successful pending release retry did not remove its durable record." \
    test -f "${PITCREW_HOST_ADMISSION_RELEASE_DIRECTORY}/control-1.pending"

status_snapshot="${TEMP_DIRECTORY}/status-snapshot.json"
status_output="${TEMP_DIRECTORY}/status-output.json"
cat > "${status_snapshot}" <<'EOF'
{
    "protocolVersion": 4,
    "namespace": "primary",
    "epoch": 3,
    "decisionSequence": 9,
    "capacityUnits": 10,
    "safetyMarginUnits": 1,
    "effectiveTotalUnits": 9,
    "availableUnits": 5,
    "hostPolicyFingerprint": "host-fingerprint-a",
    "accounting": [
        {
            "profileId": "control",
            "unitCost": 2,
            "reservedUnits": 4,
            "borrowable": false,
            "profilePolicyFingerprint": "profile-fingerprint-a",
            "activeUnits": 2,
            "provisionalUnits": 0,
            "heldUnits": 2,
            "borrowedUnits": 0,
            "pendingUnits": 0,
            "withheldUnits": 0,
            "allocatableUnits": 4,
            "allocatableWorkers": 2,
            "theoreticalMaximumUnits": 7,
            "theoreticalMaximumWorkers": 3,
            "withholdingReason": null
        }
    ],
    "lastDecision": {
        "profileId": "control",
        "sequence": 9,
        "command": "acquire",
        "granted": true,
        "failureCategory": null,
        "decidedAtUnixNano": 1700000000000000000
    }
}
EOF
(
    PITCREW_TEST_STATUS_SNAPSHOT="${status_snapshot}"
    PITCREW_HOST_ADMISSION_HOST_FINGERPRINT="host-fingerprint-a"
    PITCREW_HOST_ADMISSION_PROFILE_FINGERPRINT="profile-fingerprint-a"
    export \
        PITCREW_TEST_STATUS_SNAPSHOT \
        PITCREW_HOST_ADMISSION_HOST_FINGERPRINT \
        PITCREW_HOST_ADMISSION_PROFILE_FINGERPRINT
    . "${ROOT}/manager/host-admission.sh"
    host_admission_status "${status_output}"
)
assert_true \
    "Matching host and profile policy fingerprints did not report an available status." \
    jq -e '.status == "available" and .namespace == "primary" and .epoch == 3' \
        "${status_output}" >/dev/null
assert_true \
    "Available host-admission status did not report this profile's own accounting." \
    jq -e '
        .accounting.heldUnits == 2
        and .accounting.borrowedUnits == 0
        and .accounting.allocatableUnits == 4
        and .accounting.allocatableWorkers == 2
        and .accounting.theoreticalMaximumUnits == 7
        and .accounting.theoreticalMaximumWorkers == 3
        and .accounting.withholdingReason == null
    ' \
        "${status_output}" >/dev/null
assert_true \
    "Available host-admission status did not report its own scoped last decision." \
    jq -e '.lastDecision.command == "acquire" and .lastDecision.granted == true' \
        "${status_output}" >/dev/null

adoption_pending_snapshot="${TEMP_DIRECTORY}/status-adoption-pending.json"
jq '.adoptionFences = [{"profileId":"other-profile"}]' \
    "${status_snapshot}" > "${adoption_pending_snapshot}"
(
    PITCREW_TEST_STATUS_SNAPSHOT="${adoption_pending_snapshot}"
    PITCREW_HOST_ADMISSION_HOST_FINGERPRINT="host-fingerprint-a"
    PITCREW_HOST_ADMISSION_PROFILE_FINGERPRINT="profile-fingerprint-a"
    export \
        PITCREW_TEST_STATUS_SNAPSHOT \
        PITCREW_HOST_ADMISSION_HOST_FINGERPRINT \
        PITCREW_HOST_ADMISSION_PROFILE_FINGERPRINT
    . "${ROOT}/manager/host-admission.sh"
    host_admission_status "${status_output}"
)
assert_true \
    "A host-wide adoption fence was reported as available." \
    jq -e '.status == "degraded"' "${status_output}" >/dev/null

previous_protocol_snapshot="${TEMP_DIRECTORY}/status-previous-protocol.json"
jq '
    .protocolVersion = 2
    | del(
        .accounting[0].allocatableUnits,
        .accounting[0].allocatableWorkers,
        .accounting[0].theoreticalMaximumUnits,
        .accounting[0].theoreticalMaximumWorkers,
        .accounting[0].withholdingReason
    )
' "${status_snapshot}" > "${previous_protocol_snapshot}"
(
    PITCREW_TEST_STATUS_SNAPSHOT="${previous_protocol_snapshot}"
    PITCREW_HOST_ADMISSION_HOST_FINGERPRINT="host-fingerprint-a"
    PITCREW_HOST_ADMISSION_PROFILE_FINGERPRINT="profile-fingerprint-a"
    export \
        PITCREW_TEST_STATUS_SNAPSHOT \
        PITCREW_HOST_ADMISSION_HOST_FINGERPRINT \
        PITCREW_HOST_ADMISSION_PROFILE_FINGERPRINT
    . "${ROOT}/manager/host-admission.sh"
    host_admission_status "${status_output}"
)
assert_true \
    "Protocol-two coordinator compatibility did not remain explicit degraded evidence." \
    jq -e '
        .status == "degraded"
        and .accounting.allocatableUnits == null
        and .accounting.allocatableWorkers == null
        and .accounting.theoreticalMaximumUnits == null
        and .accounting.theoreticalMaximumWorkers == null
        and .accounting.withholdingReason == null
    ' "${status_output}" >/dev/null

missing_capacity_snapshot="${TEMP_DIRECTORY}/status-missing-capacity.json"
jq 'del(.accounting[0].allocatableUnits)' \
    "${status_snapshot}" > "${missing_capacity_snapshot}"
(
    PITCREW_TEST_STATUS_SNAPSHOT="${missing_capacity_snapshot}"
    PITCREW_HOST_ADMISSION_HOST_FINGERPRINT="host-fingerprint-a"
    PITCREW_HOST_ADMISSION_PROFILE_FINGERPRINT="profile-fingerprint-a"
    export \
        PITCREW_TEST_STATUS_SNAPSHOT \
        PITCREW_HOST_ADMISSION_HOST_FINGERPRINT \
        PITCREW_HOST_ADMISSION_PROFILE_FINGERPRINT
    . "${ROOT}/manager/host-admission.sh"
    host_admission_status "${status_output}"
)
assert_true \
    "Protocol-three status with missing capacity did not degrade without fabricating zero." \
    jq -e '
        .status == "degraded"
        and .accounting.allocatableUnits == null
        and .accounting.allocatableWorkers == null
        and .accounting.theoreticalMaximumUnits == null
        and .accounting.theoreticalMaximumWorkers == null
        and .accounting.withholdingReason == null
    ' "${status_output}" >/dev/null

(
    PITCREW_TEST_STATUS_SNAPSHOT="${status_snapshot}"
    PITCREW_HOST_ADMISSION_HOST_FINGERPRINT="host-fingerprint-mismatch"
    export PITCREW_TEST_STATUS_SNAPSHOT PITCREW_HOST_ADMISSION_HOST_FINGERPRINT
    . "${ROOT}/manager/host-admission.sh"
    host_admission_status "${status_output}"
)
assert_true \
    "A mismatched host policy fingerprint did not report a degraded status." \
    jq -e '.status == "degraded"' "${status_output}" >/dev/null

missing_identity_snapshot="${TEMP_DIRECTORY}/status-missing-identity.json"
jq 'del(.hostPolicyFingerprint)' "${status_snapshot}" > "${missing_identity_snapshot}"
(
    PITCREW_TEST_STATUS_SNAPSHOT="${missing_identity_snapshot}"
    PITCREW_HOST_ADMISSION_HOST_FINGERPRINT="host-fingerprint-a"
    export PITCREW_TEST_STATUS_SNAPSHOT PITCREW_HOST_ADMISSION_HOST_FINGERPRINT
    . "${ROOT}/manager/host-admission.sh"
    host_admission_status "${status_output}"
)
assert_true \
    "Missing coordinator identity was reported as available." \
    jq -e '.status == "degraded"' "${status_output}" >/dev/null

(
    PITCREW_TEST_STATUS_SNAPSHOT=""
    export PITCREW_TEST_STATUS_SNAPSHOT
    . "${ROOT}/manager/host-admission.sh"
    host_admission_status "${status_output}"
)
assert_true \
    "Coordinator status-command failure did not report an unavailable status." \
    jq -e '
        .status == "unavailable"
        and .namespace == "primary"
        and .epoch == null
        and .accounting == null
        and .lastDecision == null
    ' "${status_output}" >/dev/null

(
    unset \
        PITCREW_HOST_ADMISSION_NAMESPACE \
        PITCREW_HOST_ADMISSION_SOCKET
    PROFILE_ID="default"
    PITCREW_HOST_ADMISSION_CLI="${admission_cli}"
    PITCREW_TEST_ADMISSION_CALLS="${disabled_calls}"
    export PROFILE_ID PITCREW_HOST_ADMISSION_CLI PITCREW_TEST_ADMISSION_CALLS
    . "${ROOT}/manager/host-admission.sh"
    host_admission_status "${status_output}"
)
assert_true \
    "Disabled host admission did not report a fully null disabled status." \
    jq -e '
        .status == "disabled"
        and .namespace == null
        and .epoch == null
        and .accounting == null
        and .lastDecision == null
    ' "${status_output}" >/dev/null

. "${ROOT}/manager/registration.sh"
. "${ROOT}/manager/host-admission-recovery.sh"

registration_cli="${TEMP_DIRECTORY}/pitcrew-github-runner"
registration_cli_log="${TEMP_DIRECTORY}/registration-cli.log"
cat > "${registration_cli}" <<'EOF'
#!/bin/sh
[ "${ACCESS_TOKEN:-}" = "test-token" ] || exit 1
printf '%s\n' "$*" > "${PITCREW_TEST_REGISTRATION_CLI_LOG}"
EOF
chmod +x "${registration_cli}"
PITCREW_GITHUB_RUNNER_CLI="${registration_cli}"
PITCREW_TEST_REGISTRATION_CLI_LOG="${registration_cli_log}"
export PITCREW_GITHUB_RUNNER_CLI PITCREW_TEST_REGISTRATION_CLI_LOG
assert_true \
    "Fixed manager could not invoke the bounded runner deletion helper." \
    remove_github_runner_registration \
        "/repos/example/project/actions/runners" \
        77 \
        "test-token" \
        5
assert_equals \
    "delete-github-runner --endpoint /repos/example/project/actions/runners --runner-id 77 --timeout-seconds 5" \
    "$(cat "${registration_cli_log}")" \
    "Fixed manager changed the exact runner deletion command."

HOST_ADMISSION_RECOVERY_DIRECTORY="${TEMP_DIRECTORY}/host-admission-recovery"
HOST_ADMISSION_LAST_RECOVERY_STATE=""
CURRENT_DESIRED_SLOTS="${TEMP_DIRECTORY}/desired-slots.tsv"
LABELS="control,general-purpose"
PREFIX="testhost"
RUNNER_SCOPE="repo"
ACCESS_TOKEN="test-token"
REGISTRATION_API_TIMEOUT=5
printf 'repo-key\thttps://github.com/example/project\tproject-1\n' \
    > "${CURRENT_DESIRED_SLOTS}"
export \
    HOST_ADMISSION_RECOVERY_DIRECTORY \
    HOST_ADMISSION_LAST_RECOVERY_STATE \
    CURRENT_DESIRED_SLOTS \
    LABELS \
    PREFIX \
    RUNNER_SCOPE \
    ACCESS_TOKEN \
    REGISTRATION_API_TIMEOUT

registration_endpoint_for_slot() {
    printf '/repos/example/project/actions/runners\n'
}
slot_path() {
    printf '%s/slot-%s\n' "${TEMP_DIRECTORY}" "$1"
}
record_manager_diagnostic() {
    :
}
mark_observed_state_dirty() {
    :
}
fetch_github_runner_inventory() {
    [ "${PITCREW_TEST_FETCH_FAILURE:-0}" = "0" ] || return 1
    cp "${PITCREW_TEST_RECOVERY_INVENTORY}" "$1"
}
remove_github_runner_registration() {
    [ "${PITCREW_TEST_REMOVE_FAILURE:-0}" = "0" ] || return 1
    printf '%s\n' "$2" >> "${PITCREW_TEST_REMOVED_REGISTRATIONS}"
    [ "${PITCREW_TEST_REMOVE_STALE:-0}" = "0" ] || return 0
    temporary="${PITCREW_TEST_RECOVERY_INVENTORY}.$$"
    jq \
        --argjson runnerId "$2" \
        '
            .runners = [.runners[] | select(.id != $runnerId)]
            | .totalCount = (.runners | length)
        ' "${PITCREW_TEST_RECOVERY_INVENTORY}" > "${temporary}"
    mv -f "${temporary}" "${PITCREW_TEST_RECOVERY_INVENTORY}"
}

recovery_snapshot="${TEMP_DIRECTORY}/recovery-snapshot.json"
cat > "${recovery_snapshot}" <<'EOF'
{
  "adoptionFences": [
    {
      "profileId": "control",
      "pendingLeaseKeys": ["repo-key"]
    }
  ],
  "leases": [
    {
      "profileId": "control",
      "slotKey": "repo-key",
      "leaseId": "lease-recovery",
      "registrationName": "testhost-project-1-123-abcdef",
      "units": 1,
      "status": "active"
    }
  ]
}
EOF
recovery_inventory="${TEMP_DIRECTORY}/recovery-inventory.json"
removed_registrations="${TEMP_DIRECTORY}/removed-registrations.log"
PITCREW_TEST_STATUS_SNAPSHOT="${recovery_snapshot}"
PITCREW_TEST_RECOVERY_INVENTORY="${recovery_inventory}"
PITCREW_TEST_REMOVED_REGISTRATIONS="${removed_registrations}"
export \
    PITCREW_TEST_STATUS_SNAPSHOT \
    PITCREW_TEST_RECOVERY_INVENTORY \
    PITCREW_TEST_REMOVED_REGISTRATIONS

printf '{"totalCount":0,"runners":[]}\n' > "${recovery_inventory}"
: > "${admission_calls}"
: > "${removed_registrations}"
assert_true \
    "A bound lease with no registration was not reconciled." \
    reconcile_orphaned_host_admission_leases
assert_true \
    "Absent registration recovery did not reconcile the exact lease." \
    grep -Fq 'reconcile|control|repo-key||' "${admission_calls}"
assert_false \
    "Absent registration recovery attempted a runner deletion." \
    test -s "${removed_registrations}"

PITCREW_TEST_FETCH_FAILURE=1
: > "${admission_calls}"
assert_false \
    "Incomplete GitHub inventory released an active lease." \
    reconcile_orphaned_host_admission_leases
assert_false \
    "Incomplete GitHub inventory reconciled the active lease." \
    grep -Fq 'reconcile|control|repo-key||' "${admission_calls}"
PITCREW_TEST_FETCH_FAILURE=0

printf '%s\n' \
    '{"totalCount":1,"runners":[{"id":77,"name":"testhost-project-1-123-abcdef","status":"offline","busy":false,"labels":["control","general-purpose"]}]}' \
    > "${recovery_inventory}"
: > "${admission_calls}"
: > "${removed_registrations}"
assert_true \
    "A bound orphaned registration was not removed and reconciled." \
    reconcile_orphaned_host_admission_leases
assert_equals \
    "77" \
    "$(cat "${removed_registrations}")" \
    "Recovery removed the wrong runner registration."
assert_true \
    "Registration removal did not reconcile the exact lease." \
    grep -Fq 'reconcile|control|repo-key||' "${admission_calls}"

printf '%s\n' \
    '{"totalCount":1,"runners":[{"id":77,"name":"testhost-project-1-123-abcdef","status":"offline","busy":false,"labels":["control","general-purpose"]}]}' \
    > "${recovery_inventory}"
PITCREW_TEST_REMOVE_FAILURE=1
: > "${admission_calls}"
: > "${removed_registrations}"
assert_false \
    "Failed exact registration removal released an active lease." \
    reconcile_orphaned_host_admission_leases
assert_false \
    "Failed exact registration removal reconciled the active lease." \
    grep -Fq 'reconcile|control|repo-key||' "${admission_calls}"
PITCREW_TEST_REMOVE_FAILURE=0

PITCREW_TEST_REMOVE_STALE=1
: > "${admission_calls}"
: > "${removed_registrations}"
assert_false \
    "A registration still present after deletion released an active lease." \
    reconcile_orphaned_host_admission_leases
assert_false \
    "Stale post-deletion inventory reconciled the active lease." \
    grep -Fq 'reconcile|control|repo-key||' "${admission_calls}"
PITCREW_TEST_REMOVE_STALE=0

legacy_recovery_snapshot="${TEMP_DIRECTORY}/legacy-recovery-snapshot.json"
jq 'del(.leases[0].registrationName)' \
    "${recovery_snapshot}" > "${legacy_recovery_snapshot}"
printf '%s\n' \
    '{"totalCount":1,"runners":[{"id":88,"name":"testhost-project-1-456-abcdef","status":"offline","busy":false,"labels":["control","general-purpose"]}]}' \
    > "${recovery_inventory}"
PITCREW_TEST_STATUS_SNAPSHOT="${legacy_recovery_snapshot}"
export PITCREW_TEST_STATUS_SNAPSHOT
: > "${admission_calls}"
: > "${removed_registrations}"
assert_true \
    "Unique offline legacy registration was not removed and reconciled." \
    reconcile_orphaned_host_admission_leases
assert_equals \
    "88" \
    "$(cat "${removed_registrations}")" \
    "Legacy recovery removed the wrong runner registration."
assert_true \
    "Legacy exact registration removal did not reconcile the lease." \
    grep -Fq 'reconcile|control|repo-key||' "${admission_calls}"

printf '%s\n' \
    '{"totalCount":1,"runners":[{"id":88,"name":"testhost-project-1-456-abcdef","status":"offline","busy":false,"labels":["mutated-label"]}]}' \
    > "${recovery_inventory}"
: > "${admission_calls}"
: > "${removed_registrations}"
assert_false \
    "Legacy registration with mutable labels released an active lease." \
    reconcile_orphaned_host_admission_leases
assert_false \
    "Legacy ambiguous recovery removed a non-bound registration." \
    test -s "${removed_registrations}"
assert_false \
    "Legacy ambiguous recovery reconciled the active lease." \
    grep -Fq 'reconcile|control|repo-key||' "${admission_calls}"

printf '%s\n' \
    '{"totalCount":1,"runners":[{"id":88,"name":"testhost-project-1-456-abcdef","status":"online","busy":true,"labels":["control","general-purpose"]}]}' \
    > "${recovery_inventory}"
: > "${admission_calls}"
: > "${removed_registrations}"
assert_false \
    "Busy legacy registration was removed during recovery." \
    reconcile_orphaned_host_admission_leases
assert_false \
    "Busy legacy recovery invoked registration deletion." \
    test -s "${removed_registrations}"
assert_false \
    "Busy legacy recovery reconciled the active lease." \
    grep -Fq 'reconcile|control|repo-key||' "${admission_calls}"

printf '{"totalCount":0,"runners":[]}\n' > "${recovery_inventory}"
: > "${admission_calls}"
: > "${removed_registrations}"
assert_true \
    "Legacy lease with no possible registration was not reconciled." \
    reconcile_orphaned_host_admission_leases
assert_false \
    "Legacy absence recovery attempted an unbound registration deletion." \
    test -s "${removed_registrations}"
assert_true \
    "Legacy absence recovery did not reconcile the exact lease." \
    grep -Fq 'reconcile|control|repo-key||' "${admission_calls}"

default_legacy_snapshot="${TEMP_DIRECTORY}/default-legacy-recovery-snapshot.json"
jq '
    .adoptionFences[0].profileId = "default"
    | .leases[0].profileId = "default"
' "${legacy_recovery_snapshot}" > "${default_legacy_snapshot}"
PROFILE_ID="default"
LABELS="general-purpose"
PITCREW_TEST_STATUS_SNAPSHOT="${default_legacy_snapshot}"
printf '%s\n' \
    '{"totalCount":1,"runners":[{"id":99,"name":"testhost-project-1-789-abcdef","status":"offline","busy":false,"labels":["general-purpose"]}]}' \
    > "${recovery_inventory}"
: > "${admission_calls}"
: > "${removed_registrations}"
assert_true \
    "Default-profile legacy registration did not use its canonical label." \
    reconcile_orphaned_host_admission_leases
assert_equals \
    "99" \
    "$(cat "${removed_registrations}")" \
    "Default-profile recovery removed the wrong runner registration."
assert_true \
    "Default-profile recovery did not reconcile the exact lease." \
    grep -Fq 'reconcile|default|repo-key||' "${admission_calls}"

echo "Host admission contracts passed: ${ASSERTIONS} assertions."
