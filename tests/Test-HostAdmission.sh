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
    acquire:error) exit 1 ;;
    release:not-found|reconcile:not-found) exit 4 ;;
esac
case "${command}" in
    acquire)
        printf '{"profileId":"%s","slotKey":"%s","leaseId":"lease-1","units":2,"status":"provisional"}\n' \
            "${profile}" "${slot}"
        ;;
    activate)
        printf '{"profileId":"%s","slotKey":"%s","leaseId":"lease-1","units":2,"status":"active"}\n' \
            "${profile}" "${slot}"
        ;;
esac
EOF
chmod +x "${admission_cli}"

PROFILE_ID="control"
PITCREW_HOST_ADMISSION_NAMESPACE="primary"
PITCREW_HOST_ADMISSION_SOCKET="/var/lib/pitcrew-admission/coordinator.sock"
PITCREW_HOST_ADMISSION_CLI="${admission_cli}"
PITCREW_HOST_ADMISSION_CLI_TIMEOUT=2
PITCREW_TEST_ADMISSION_CALLS="${admission_calls}"
export \
    PROFILE_ID \
    PITCREW_HOST_ADMISSION_NAMESPACE \
    PITCREW_HOST_ADMISSION_SOCKET \
    PITCREW_HOST_ADMISSION_CLI \
    PITCREW_HOST_ADMISSION_CLI_TIMEOUT \
    PITCREW_TEST_ADMISSION_CALLS
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
    "Fixed manager recovery ignores created worker containers." \
    grep -Fq 'docker ps -aq --filter "label=${MANAGED_LABEL}"' "${manager_source}"
assert_true \
    "Fixed manager drain can hang forever while the coordinator is unavailable." \
    grep -Fq 'active lease remains fenced' "${manager_source}"
assert_true \
    "Recovered draining slots do not clear pending host demand before return." \
    grep -Fq 'host_admission_end_wait \' "${manager_source}"
assert_true \
    "Fixed admission implementation activated the manager contract before autoscaler parity." \
    grep -Fq 'MANAGER_CONTRACT_VERSION=17' "${manager_source}"

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

PITCREW_TEST_ADMISSION_MODE="not-found"
export PITCREW_TEST_ADMISSION_MODE
assert_true \
    "Missing lease was not treated as already released." \
    host_admission_release "${admission_slot}" "control-1"
assert_true \
    "Missing lease was not treated as already reconciled." \
    host_admission_reconcile_absent "${admission_slot}" "control-1"

echo "Host admission contracts passed: ${ASSERTIONS} assertions."
