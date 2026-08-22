#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "${ROOT}/manager/container-supervision.sh"

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

assert_no_live_monitor_processes() {
    state_directory="$1"
    for pid_path in "${state_directory}"/*.pid; do
        [ -f "${pid_path}" ] || continue
        monitored_pid=$(cat "${pid_path}")
        if kill -0 "${monitored_pid}" 2>/dev/null; then
            fail "Container monitor process ${monitored_pid} remained alive."
        fi
    done
    ASSERTIONS=$((ASSERTIONS + 1))
}

CONNECT_MARKER="Listening for Jobs"
OBSERVED_STATE_DIRTY="${TEMP_DIRECTORY}/observed-state-dirty"
EXIT_EVIDENCE_EVENT_GRACE_SECONDS=0
EXIT_EVIDENCE_COMMAND_TIMEOUT=1
CONTAINER_MONITOR_WINDOW_SECONDS=1
CONTAINER_MONITOR_PROBE_TIMEOUT_SECONDS=1
CONTAINER_MONITOR_KILL_AFTER_SECONDS=1
CONTAINER_MONITOR_RETRY_SECONDS=0
HOST_ADMISSION_TEST_ENABLED=1
DIAGNOSTICS_PATH="${TEMP_DIRECTORY}/diagnostics.txt"
RELEASE_QUEUE_PATH="${TEMP_DIRECTORY}/release-queue.txt"

slot_connect_marker_is_pending() {
    return 1
}

consume_slot_connect_marker() {
    :
}

write_slot_runtime_state() {
    :
}

mark_observed_state_dirty() {
    : > "${OBSERVED_STATE_DIRTY}"
}

record_manager_diagnostic() {
    printf '%s|' "$@" >> "${DIAGNOSTICS_PATH}"
    printf '\n' >> "${DIAGNOSTICS_PATH}"
}

write_slot_exit_evidence() {
    printf '%s|%s|%s\n' "$3" "$4" "$5" > "$1/exit-evidence.txt"
}

host_admission_enabled() {
    [ "${HOST_ADMISSION_TEST_ENABLED}" -eq 1 ]
}

host_admission_queue_release() {
    printf '%s\n' "$1" > "${RELEASE_QUEUE_PATH}"
}

FAKE_DOCKER_DIRECTORY="${TEMP_DIRECTORY}/bin"
mkdir -p "${FAKE_DOCKER_DIRECTORY}"
cat > "${FAKE_DOCKER_DIRECTORY}/docker" <<'EOF'
#!/bin/sh
set -eu

command_name="$1"
shift
count_path="${FAKE_DOCKER_STATE_DIRECTORY}/${command_name}.count"
count=0
if [ -f "${count_path}" ]; then
    count=$(cat "${count_path}")
fi
count=$((count + 1))
printf '%s\n' "${count}" > "${count_path}"
printf '%s\n' "$*" > "${FAKE_DOCKER_STATE_DIRECTORY}/${command_name}-${count}.args"

hang() {
    printf '%s\n' "$$" > "${FAKE_DOCKER_STATE_DIRECTORY}/${command_name}-${count}.pid"
    exec sleep 30
}

running_state() {
    printf '%s\n' '[{"State":{"Running":true,"ExitCode":0,"OOMKilled":false}}]'
}

exited_state() {
    printf '%s\n' '[{"State":{"Running":false,"ExitCode":0,"OOMKilled":false}}]'
}

case "${FAKE_DOCKER_SCENARIO}:${command_name}" in
    absent:logs|absent:wait)
        hang
        ;;
    absent:inspect)
        exit 1
        ;;
    absent:ps)
        exit 0
        ;;
    running-then-exit:logs|running-then-exit:wait)
        if [ "${count}" -eq 1 ]; then
            hang
        fi
        [ "${command_name}" = "wait" ] && printf '%s\n' 0
        ;;
    running-then-exit:inspect)
        wait_count=$(cat "${FAKE_DOCKER_STATE_DIRECTORY}/wait.count")
        if [ "${wait_count}" -eq 1 ]; then
            running_state
        else
            exited_state
        fi
        ;;
    unavailable-then-exit:logs|unavailable-then-exit:wait)
        if [ "${count}" -eq 1 ]; then
            hang
        fi
        [ "${command_name}" = "wait" ] && printf '%s\n' 0
        ;;
    unavailable-then-exit:inspect)
        wait_count=$(cat "${FAKE_DOCKER_STATE_DIRECTORY}/wait.count")
        if [ "${wait_count}" -eq 1 ]; then
            exit 1
        fi
        exited_state
        ;;
    unavailable-then-exit:ps)
        exit 1
        ;;
    logs-hang-exit:logs)
        hang
        ;;
    logs-hang-exit:wait)
        printf '%s\n' 0
        ;;
    logs-hang-exit:inspect)
        exited_state
        ;;
    *:events)
        exit 0
        ;;
    *)
        echo "Unexpected fake Docker call: ${FAKE_DOCKER_SCENARIO} ${command_name} $*" >&2
        exit 1
        ;;
esac
EOF
chmod +x "${FAKE_DOCKER_DIRECTORY}/docker"
PATH="${FAKE_DOCKER_DIRECTORY}:${PATH}"
export PATH

run_scenario() {
    scenario="$1"
    slot_key="$2"
    initial_since="${3:-}"
    scenario_directory="${TEMP_DIRECTORY}/${scenario}"
    state_directory="${scenario_directory}/docker-state"
    slot_directory="${scenario_directory}/${slot_key}"
    log_path="${scenario_directory}/worker.log"
    mkdir -p "${state_directory}" "${slot_directory}"
    printf '%s\n' "container-1" > "${slot_directory}/container-id"
    printf '%s\n' "runner-one" > "${slot_directory}/container-name"
    printf '%s\n' "sha256:$(printf 'a%.0s' $(seq 1 64))" > "${slot_directory}/image-id"
    : > "${DIAGNOSTICS_PATH}"
    rm -f "${RELEASE_QUEUE_PATH}"

    FAKE_DOCKER_SCENARIO="${scenario}"
    FAKE_DOCKER_STATE_DIRECTORY="${state_directory}"
    export FAKE_DOCKER_SCENARIO FAKE_DOCKER_STATE_DIRECTORY

    started=$(date +%s)
    monitor_runner_container \
        "${slot_directory}" \
        "runner-one" \
        "container-1" \
        "${log_path}" \
        "${initial_since}"
    elapsed=$(($(date +%s) - started))

    assert_true \
        "Scenario ${scenario} exceeded its bounded supervision window (${elapsed}s)." \
        test "${elapsed}" -lt 6
    assert_equals \
        "${slot_key}" \
        "$(cat "${RELEASE_QUEUE_PATH}")" \
        "Scenario ${scenario} did not durably queue exact lease release."
    assert_true \
        "Scenario ${scenario} retained the exact container identity after terminal evidence." \
        test ! -e "${slot_directory}/container-id"
    assert_no_live_monitor_processes "${state_directory}"
}

run_scenario "absent" "slot-absent"
assert_equals \
    "unavailable||" \
    "$(cat "${TEMP_DIRECTORY}/absent/slot-absent/exit-evidence.txt")" \
    "Confirmed container absence fabricated exit evidence."
assert_equals \
    "1" \
    "$(cat "${TEMP_DIRECTORY}/absent/docker-state/wait.count")" \
    "Confirmed absence restarted Docker wait unnecessarily."

run_scenario "running-then-exit" "slot-running" "9999999999"
assert_equals \
    "2" \
    "$(cat "${TEMP_DIRECTORY}/running-then-exit/docker-state/wait.count")" \
    "A live container was not remonitored after the bounded window."
assert_true \
    "Remonitoring replayed logs older than the protected handoff boundary." \
    grep -q -- "--since 9999999999" \
        "${TEMP_DIRECTORY}/running-then-exit/docker-state/logs-2.args"

run_scenario "unavailable-then-exit" "slot-unavailable"
assert_true \
    "Unavailable Docker evidence was not surfaced as fenced degradation." \
    grep -q "docker-unavailable" "${DIAGNOSTICS_PATH}"
assert_true \
    "Recovered Docker supervision did not clear its degraded health evidence." \
    grep -q "recovered" "${DIAGNOSTICS_PATH}"
assert_equals \
    "2" \
    "$(cat "${TEMP_DIRECTORY}/unavailable-then-exit/docker-state/wait.count")" \
    "Unavailable Docker evidence did not preserve and retry supervision."

run_scenario "logs-hang-exit" "slot-logs"
assert_equals \
    "1" \
    "$(cat "${TEMP_DIRECTORY}/logs-hang-exit/docker-state/wait.count")" \
    "A completed wait was restarted because the paired log follower hung."

echo "Container supervision tests passed: ${ASSERTIONS} assertions."
