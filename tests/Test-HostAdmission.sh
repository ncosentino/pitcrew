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
while [ "$#" -gt 0 ]; do
    case "$1" in
        --profile) profile="$2"; shift 2 ;;
        --slot) slot="$2"; shift 2 ;;
        --demand) demand="$2"; shift 2 ;;
        --socket) shift 2 ;;
        --evidence) shift 2 ;;
        *) shift ;;
    esac
done
printf '%s|%s|%s|%s\n' "${command}" "${profile}" "${slot}" "${demand}" \
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
    "Fixed manager recovery clears the coordinator fence before tracked adoptions finish." \
    grep -Fq 'while host_admission_adoption_pending' "${manager_source}"
assert_true \
    "Fixed manager recovery ignores created worker containers." \
    grep -Fq 'docker ps -aq --filter "label=${MANAGED_LABEL}"' "${manager_source}"
assert_true \
    "Fixed manager drain can hang forever while the coordinator is unavailable." \
    grep -Fq 'active lease remains fenced' "${manager_source}"
assert_true \
    "Recovered draining slots do not clear pending host demand before return." \
    grep -Fq 'host_admission_end_wait \' "${manager_source}"
assert_true \
    "Fixed admission implementation did not activate manager contract eighteen." \
    grep -Fq 'MANAGER_CONTRACT_VERSION=18' "${manager_source}"

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
    grep -Fqx 'set-demand|control||1' "${admission_calls}"
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
assert_true \
    "Fixed running-worker adoption did not retry after a transient coordinator outage." \
    host_admission_adopt_running \
        "${admission_slot}" \
        "control-1" \
        "legacy-container" \
        0
assert_equals \
    "2" \
    "$(grep -c '^adopt|control|control-1|' "${admission_calls}")" \
    "Fixed running-worker adoption did not retry the same deterministic slot identity."
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
            "withheldUnits": 0
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
    jq -e '.accounting.heldUnits == 2 and .accounting.borrowedUnits == 0' \
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

echo "Host admission contracts passed: ${ASSERTIONS} assertions."
