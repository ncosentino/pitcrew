#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SCRIPT_DIRECTORY="${ROOT}/manager"
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
CONTAINER_MONITOR_RECONCILE_GRACE_SECONDS=180
CONTAINER_MONITOR_RECONCILE_INTERVAL_SECONDS=60
CONTAINER_MONITOR_UNBLOCK_SECONDS=1
CONTAINER_MONITOR_GROUP_DRAIN_SECONDS=10
LAST_CONTAINER_MONITOR_RECONCILE_EPOCH=0
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
    sigterm-ignoring-hang:logs|sigterm-ignoring-hang:wait)
        printf '%s\n' "$$" > "${FAKE_DOCKER_STATE_DIRECTORY}/${command_name}-${count}.pid"
        trap '' TERM
        while :; do sleep 1; done
        ;;
    sigterm-ignoring-hang:inspect)
        exited_state
        ;;
    wedged-logs-grandchild:logs)
        # docker itself returns immediately (as it would once a container is
        # truly gone), but leaves behind an untracked grandchild that inherits
        # the same stdout pipe/fifo and ignores TERM, exactly reproducing a
        # monitor stuck waiting for end-of-stream on a descendant docker
        # itself never waited for.
        (
            trap '' TERM
            printf '%s\n' "$$" > "${FAKE_DOCKER_STATE_DIRECTORY}/logs-grandchild.pid"
            while :; do sleep 1; done
        ) &
        exit 0
        ;;
    wedged-logs-grandchild:wait)
        printf '%s\n' 0
        ;;
    wedged-logs-grandchild:inspect)
        exit 1
        ;;
    wedged-logs-grandchild:ps)
        exit 0
        ;;
    running-only:inspect)
        running_state
        ;;
    docker-unavailable-ambiguous:inspect)
        exit 1
        ;;
    docker-unavailable-ambiguous:ps)
        exit 1
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

run_scenario "sigterm-ignoring-hang" "slot-sigterm"
assert_true \
    "A SIGTERM-ignoring docker wait child was not force-killed within the bounded window." \
    test -f "${TEMP_DIRECTORY}/sigterm-ignoring-hang/docker-state/wait-1.pid"
assert_true \
    "A SIGTERM-ignoring docker logs child was not force-killed within the bounded window." \
    test -f "${TEMP_DIRECTORY}/sigterm-ignoring-hang/docker-state/logs-1.pid"

# --- reconcile_stalled_container_monitor: a fresh heartbeat is left alone ---
reconcile_fresh="${TEMP_DIRECTORY}/reconcile-fresh"
reconcile_fresh_docker="${TEMP_DIRECTORY}/reconcile-fresh-docker-state"
mkdir -p "${reconcile_fresh}" "${reconcile_fresh_docker}"
printf '%s\n' "container-fresh" > "${reconcile_fresh}/container-id"
printf '%s\n' "$(date +%s)" > "${reconcile_fresh}/monitor-heartbeat"
FAKE_DOCKER_SCENARIO="no-fake-docker-call-expected"
FAKE_DOCKER_STATE_DIRECTORY="${reconcile_fresh_docker}"
export FAKE_DOCKER_SCENARIO FAKE_DOCKER_STATE_DIRECTORY
: > "${DIAGNOSTICS_PATH}"
rm -f "${RELEASE_QUEUE_PATH}"
reconcile_stalled_container_monitor "${reconcile_fresh}"
assert_true \
    "A fresh monitor heartbeat was reconciled even though its cycle had not gone stale." \
    test -f "${reconcile_fresh}/container-id"
assert_true \
    "A fresh monitor heartbeat triggered an unnecessary independent Docker probe." \
    test ! -f "${reconcile_fresh_docker}/inspect.count"

# --- reconcile_stalled_container_monitor: a stale, confirmed-absent container
# is cleaned up and its lease queued for release ---
reconcile_absent="${TEMP_DIRECTORY}/reconcile-absent"
reconcile_absent_docker="${TEMP_DIRECTORY}/reconcile-absent-docker-state"
mkdir -p "${reconcile_absent}" "${reconcile_absent_docker}"
printf '%s\n' "container-absent" > "${reconcile_absent}/container-id"
printf '%s\n' "$(( $(date +%s) - 999 ))" > "${reconcile_absent}/monitor-heartbeat"
FAKE_DOCKER_SCENARIO="absent"
FAKE_DOCKER_STATE_DIRECTORY="${reconcile_absent_docker}"
export FAKE_DOCKER_SCENARIO FAKE_DOCKER_STATE_DIRECTORY
: > "${DIAGNOSTICS_PATH}"
rm -f "${RELEASE_QUEUE_PATH}"
reconcile_stalled_container_monitor "${reconcile_absent}"
assert_true \
    "An independently reconciled absent container retained its container-id record." \
    test ! -e "${reconcile_absent}/container-id"
assert_true \
    "An independently reconciled absent container retained its monitor-heartbeat record." \
    test ! -e "${reconcile_absent}/monitor-heartbeat"
assert_equals \
    "reconcile-absent" \
    "$(cat "${RELEASE_QUEUE_PATH}" 2>/dev/null || true)" \
    "An independently reconciled absent container did not queue its exact lease release."

# --- reconcile_stalled_container_monitor: a stale but still-running container
# only refreshes its heartbeat; the live worker is left untouched ---
reconcile_running="${TEMP_DIRECTORY}/reconcile-running"
reconcile_running_docker="${TEMP_DIRECTORY}/reconcile-running-docker-state"
mkdir -p "${reconcile_running}" "${reconcile_running_docker}"
printf '%s\n' "container-running" > "${reconcile_running}/container-id"
stale_heartbeat=$(( $(date +%s) - 999 ))
printf '%s\n' "${stale_heartbeat}" > "${reconcile_running}/monitor-heartbeat"
FAKE_DOCKER_SCENARIO="running-only"
FAKE_DOCKER_STATE_DIRECTORY="${reconcile_running_docker}"
export FAKE_DOCKER_SCENARIO FAKE_DOCKER_STATE_DIRECTORY
: > "${DIAGNOSTICS_PATH}"
rm -f "${RELEASE_QUEUE_PATH}"
reconcile_stalled_container_monitor "${reconcile_running}"
assert_equals \
    "container-running" \
    "$(cat "${reconcile_running}/container-id" 2>/dev/null || true)" \
    "A confirmed-running container's identity was disturbed by independent reconciliation."
assert_true \
    "A confirmed-running container's stale heartbeat was not refreshed." \
    test "$(cat "${reconcile_running}/monitor-heartbeat")" -gt "${stale_heartbeat}"
assert_true \
    "A confirmed-running container had its lease released." \
    test ! -f "${RELEASE_QUEUE_PATH}"

# --- reconcile_stalled_container_monitor: an unavailable/ambiguous Docker
# verdict changes nothing (fail-closed; retried on the next pass) ---
reconcile_unavailable="${TEMP_DIRECTORY}/reconcile-unavailable"
reconcile_unavailable_docker="${TEMP_DIRECTORY}/reconcile-unavailable-docker-state"
mkdir -p "${reconcile_unavailable}" "${reconcile_unavailable_docker}"
printf '%s\n' "container-unavailable" > "${reconcile_unavailable}/container-id"
stale_heartbeat=$(( $(date +%s) - 999 ))
printf '%s\n' "${stale_heartbeat}" > "${reconcile_unavailable}/monitor-heartbeat"
FAKE_DOCKER_SCENARIO="docker-unavailable-ambiguous"
FAKE_DOCKER_STATE_DIRECTORY="${reconcile_unavailable_docker}"
export FAKE_DOCKER_SCENARIO FAKE_DOCKER_STATE_DIRECTORY
: > "${DIAGNOSTICS_PATH}"
rm -f "${RELEASE_QUEUE_PATH}"
reconcile_stalled_container_monitor "${reconcile_unavailable}"
assert_equals \
    "container-unavailable" \
    "$(cat "${reconcile_unavailable}/container-id" 2>/dev/null || true)" \
    "An ambiguous Docker verdict removed a container record instead of failing closed."
assert_equals \
    "${stale_heartbeat}" \
    "$(cat "${reconcile_unavailable}/monitor-heartbeat" 2>/dev/null || true)" \
    "An ambiguous Docker verdict refreshed a heartbeat instead of retrying on the next pass."
assert_true \
    "An ambiguous Docker verdict released a lease instead of failing closed." \
    test ! -f "${RELEASE_QUEUE_PATH}"

# --- reconcile_stalled_container_monitor: a missing heartbeat (a manager
# restart/adoption whose immediate docker inspect raced a container's exit)
# is treated as maximally stale and reconciled immediately ---
reconcile_restart_race="${TEMP_DIRECTORY}/reconcile-restart-race"
reconcile_restart_race_docker="${TEMP_DIRECTORY}/reconcile-restart-race-docker-state"
mkdir -p "${reconcile_restart_race}" "${reconcile_restart_race_docker}"
printf '%s\n' "container-restart-race" > "${reconcile_restart_race}/container-id"
FAKE_DOCKER_SCENARIO="absent"
FAKE_DOCKER_STATE_DIRECTORY="${reconcile_restart_race_docker}"
export FAKE_DOCKER_SCENARIO FAKE_DOCKER_STATE_DIRECTORY
: > "${DIAGNOSTICS_PATH}"
rm -f "${RELEASE_QUEUE_PATH}"
reconcile_stalled_container_monitor "${reconcile_restart_race}"
assert_true \
    "A stale record left by a manager-restart adoption race was not reconciled." \
    test ! -e "${reconcile_restart_race}/container-id"
assert_equals \
    "reconcile-restart-race" \
    "$(cat "${RELEASE_QUEUE_PATH}" 2>/dev/null || true)" \
    "A manager-restart adoption race did not release its orphaned lease."

# --- reconcile_stalled_container_monitor: a container-id that changes between
# the probe and cleanup (a monitor that legitimately replaced the slot's
# container) is never clobbered ---
reconcile_race_guard="${TEMP_DIRECTORY}/reconcile-race-guard"
mkdir -p "${reconcile_race_guard}"
printf '%s\n' "container-old" > "${reconcile_race_guard}/container-id"
printf '%s\n' "$(( $(date +%s) - 999 ))" > "${reconcile_race_guard}/monitor-heartbeat"
: > "${DIAGNOSTICS_PATH}"
rm -f "${RELEASE_QUEUE_PATH}"
probe_monitored_container() {
    printf '%s\n' "container-new" > "${reconcile_race_guard}/container-id"
    printf '%s\n' "absent"
}
reconcile_stalled_container_monitor "${reconcile_race_guard}"
. "${ROOT}/manager/container-supervision.sh"
assert_equals \
    "container-new" \
    "$(cat "${reconcile_race_guard}/container-id" 2>/dev/null || true)" \
    "Independent reconciliation clobbered a container-id a concurrent monitor had just replaced."
assert_true \
    "Independent reconciliation queued a lease release for a container-id race it should have skipped." \
    test ! -f "${RELEASE_QUEUE_PATH}"

# --- reconcile_stalled_container_monitors: sweeps every slot, rate-limited,
# and only acts on genuinely stale slots ---
driver_root="${TEMP_DIRECTORY}/reconcile-driver"
driver_docker="${TEMP_DIRECTORY}/reconcile-driver-docker-state"
mkdir -p "${driver_root}/slot-a" "${driver_root}/slot-b" "${driver_docker}"
printf '%s\n' "container-a" > "${driver_root}/slot-a/container-id"
printf '%s\n' "$(( $(date +%s) - 999 ))" > "${driver_root}/slot-a/monitor-heartbeat"
printf '%s\n' "container-b" > "${driver_root}/slot-b/container-id"
printf '%s\n' "$(date +%s)" > "${driver_root}/slot-b/monitor-heartbeat"
SLOT_DIRECTORY="${driver_root}"
CONTAINER_MONITOR_RECONCILE_INTERVAL_SECONDS=60
LAST_CONTAINER_MONITOR_RECONCILE_EPOCH=0
FAKE_DOCKER_SCENARIO="absent"
FAKE_DOCKER_STATE_DIRECTORY="${driver_docker}"
export FAKE_DOCKER_SCENARIO FAKE_DOCKER_STATE_DIRECTORY
: > "${DIAGNOSTICS_PATH}"
rm -f "${RELEASE_QUEUE_PATH}"
reconcile_stalled_container_monitors
assert_true \
    "A stale slot was not reconciled by the periodic sweep." \
    test ! -e "${driver_root}/slot-a/container-id"
assert_true \
    "A fresh, healthy slot was disturbed by the periodic sweep." \
    test -e "${driver_root}/slot-b/container-id"
mkdir -p "${driver_root}/slot-c"
printf '%s\n' "container-c" > "${driver_root}/slot-c/container-id"
printf '%s\n' "$(( $(date +%s) - 999 ))" > "${driver_root}/slot-c/monitor-heartbeat"
reconcile_stalled_container_monitors
assert_true \
    "A second sweep inside the reconciliation interval was not rate-limited." \
    test -e "${driver_root}/slot-c/container-id"

# --- reconcile_terminate_stalled_monitor_supervision: a replacement
# generation's tracked process group is never signaled by a reconciliation
# pass still holding an older, now-stale generation value; this is the
# guard against both a stale read and numeric PID/PGID reuse, since neither
# ever authorizes an action once the generation on disk has moved on. ---
CONTAINER_MONITOR_UNBLOCK_SECONDS=1
reconcile_regen_guard="${TEMP_DIRECTORY}/reconcile-regen-guard"
mkdir -p "${reconcile_regen_guard}"
printf '%s\n' "container-regen" > "${reconcile_regen_guard}/container-id"
setsid sleep 30 &
regen_guard_pgid=$!
printf '%s\n' "${regen_guard_pgid}" > "${reconcile_regen_guard}/monitor-logs-pgid"
process_starttime "${regen_guard_pgid}" > "${reconcile_regen_guard}/monitor-logs-pgid-starttime"
printf '%s\n' "current-generation" > "${reconcile_regen_guard}/monitor-generation"
regen_result=$(
    reconcile_terminate_stalled_monitor_supervision \
        "${reconcile_regen_guard}" \
        "container-regen" \
        "stale-generation"
)
assert_equals \
    "skip" \
    "${regen_result}" \
    "A stale generation's stale-read process group was signaled instead of skipped."
ASSERTIONS=$((ASSERTIONS + 1))
if ! kill -0 -"${regen_guard_pgid}" 2>/dev/null; then
    fail "A replacement generation's tracked process group was killed by a stale-generation reconciliation pass."
fi
kill -KILL -"${regen_guard_pgid}" 2>/dev/null || true
wait "${regen_guard_pgid}" 2>/dev/null || true

# --- reconcile_terminate_stalled_monitor_supervision: no process-group
# supervisor available (setsid missing) degrades to an immediate, bounded
# "skip" rather than guessing at an unestablished group ---
reconcile_no_setsid="${TEMP_DIRECTORY}/reconcile-no-setsid"
mkdir -p "${reconcile_no_setsid}"
printf '%s\n' "container-no-setsid" > "${reconcile_no_setsid}/container-id"
printf '%s\n' "generation-no-setsid" > "${reconcile_no_setsid}/monitor-generation"
printf '%s\n' "999999" > "${reconcile_no_setsid}/monitor-logs-pgid"
container_monitor_process_group_supervisor_available() {
    return 1
}
no_setsid_started=$(date +%s)
no_setsid_result=$(
    reconcile_terminate_stalled_monitor_supervision \
        "${reconcile_no_setsid}" \
        "container-no-setsid" \
        "generation-no-setsid"
)
no_setsid_elapsed=$(($(date +%s) - no_setsid_started))
. "${ROOT}/manager/container-supervision.sh"
assert_equals \
    "skip" \
    "${no_setsid_result}" \
    "An unavailable process-group supervisor was not reported as skip."
assert_true \
    "An unavailable process-group supervisor did not return immediately (${no_setsid_elapsed}s)." \
    test "${no_setsid_elapsed}" -lt 2

# --- reconcile_terminate_stalled_monitor_supervision: a tracked process
# group that never settles (its container/generation record never changes)
# is bounded by CONTAINER_MONITOR_UNBLOCK_SECONDS on both the TERM and KILL
# rounds, is force-killed by the KILL round, and is reported "unsettled" so
# the caller knows it must fall back to write-ahead cleanup ---
reconcile_unsettled="${TEMP_DIRECTORY}/reconcile-unsettled"
mkdir -p "${reconcile_unsettled}"
printf '%s\n' "container-unsettled" > "${reconcile_unsettled}/container-id"
printf '%s\n' "generation-unsettled" > "${reconcile_unsettled}/monitor-generation"
setsid sleep 30 &
unsettled_pgid=$!
printf '%s\n' "${unsettled_pgid}" > "${reconcile_unsettled}/monitor-logs-pgid"
process_starttime "${unsettled_pgid}" > "${reconcile_unsettled}/monitor-logs-pgid-starttime"
unsettled_started=$(date +%s)
unsettled_result=$(
    reconcile_terminate_stalled_monitor_supervision \
        "${reconcile_unsettled}" \
        "container-unsettled" \
        "generation-unsettled"
)
unsettled_elapsed=$(($(date +%s) - unsettled_started))
assert_equals \
    "unsettled" \
    "${unsettled_result}" \
    "A monitor whose container/generation record never changed was not reported unsettled."
assert_true \
    "Cancellation-timeout handling exceeded its bounded window (${unsettled_elapsed}s)." \
    test "${unsettled_elapsed}" -lt 6
ASSERTIONS=$((ASSERTIONS + 1))
if kill -0 -"${unsettled_pgid}" 2>/dev/null; then
    fail "An unsettled reconciliation left its tracked process group alive after escalating to KILL."
fi

# --- reconcile_terminate_signal_pgids/process_group_leader_identity_matches:
# a tracked pgid whose recorded starttime does not match the live process's
# actual starttime (whether from being wrong or from the numeric pid having
# been recycled to an unrelated process since) is never signaled, and the
# live, otherwise-legitimate-looking process survives untouched ---
stale_starttime_guard="${TEMP_DIRECTORY}/stale-starttime-guard"
mkdir -p "${stale_starttime_guard}"
printf '%s\n' "container-stale-starttime" > "${stale_starttime_guard}/container-id"
printf '%s\n' "generation-stale-starttime" > "${stale_starttime_guard}/monitor-generation"
setsid sleep 30 &
stale_starttime_pgid=$!
printf '%s\n' "${stale_starttime_pgid}" > "${stale_starttime_guard}/monitor-logs-pgid"
real_starttime=$(process_starttime "${stale_starttime_pgid}")
printf '%s\n' "$((real_starttime + 1))" > "${stale_starttime_guard}/monitor-logs-pgid-starttime"
stale_starttime_result=$(
    reconcile_terminate_stalled_monitor_supervision \
        "${stale_starttime_guard}" \
        "container-stale-starttime" \
        "generation-stale-starttime"
)
assert_equals \
    "unsettled" \
    "${stale_starttime_result}" \
    "A wrong-starttime pgid was reported as settled instead of never having been signaled."
ASSERTIONS=$((ASSERTIONS + 1))
if ! kill -0 -"${stale_starttime_pgid}" 2>/dev/null; then
    fail "A pgid recorded with the wrong starttime was signaled and killed anyway."
fi
kill -KILL -"${stale_starttime_pgid}" 2>/dev/null || true
wait "${stale_starttime_pgid}" 2>/dev/null || true

# --- process_group_leader_identity_matches: a live process that is not its
# own process group's leader (a plain background job, not setsid-wrapped)
# fails the leader-role check even with a correct starttime, guarding
# against ever issuing a negative-pgid signal for a pid that never actually
# established the group it was recorded under ---
sleep 45 &
non_leader_pid=$!
non_leader_starttime=$(process_starttime "${non_leader_pid}")
ASSERTIONS=$((ASSERTIONS + 1))
if process_group_leader_identity_matches "${non_leader_pid}" "${non_leader_starttime}"; then
    fail "A non-leader process (not its own process group) was accepted as a signalable group leader."
fi
kill -KILL "${non_leader_pid}" 2>/dev/null || true
wait "${non_leader_pid}" 2>/dev/null || true

# --- unrelated sentinel process: a full TERM+KILL escalation run against one
# wedged pgid never disturbs a completely unrelated live process ---
sentinel_survivor="${TEMP_DIRECTORY}/sentinel-survivor"
mkdir -p "${sentinel_survivor}"
printf '%s\n' "container-sentinel" > "${sentinel_survivor}/container-id"
printf '%s\n' "generation-sentinel" > "${sentinel_survivor}/monitor-generation"
setsid sleep 30 &
sentinel_target_pgid=$!
printf '%s\n' "${sentinel_target_pgid}" > "${sentinel_survivor}/monitor-logs-pgid"
process_starttime "${sentinel_target_pgid}" > "${sentinel_survivor}/monitor-logs-pgid-starttime"
setsid sleep 45 &
unrelated_sentinel_pgid=$!
reconcile_terminate_stalled_monitor_supervision \
    "${sentinel_survivor}" \
    "container-sentinel" \
    "generation-sentinel" >/dev/null
ASSERTIONS=$((ASSERTIONS + 1))
if ! kill -0 -"${unrelated_sentinel_pgid}" 2>/dev/null; then
    fail "An unrelated sentinel process group was disturbed by a reconciliation pass targeting a different pgid."
fi
kill -KILL -"${unrelated_sentinel_pgid}" 2>/dev/null || true
wait "${unrelated_sentinel_pgid}" 2>/dev/null || true

# --- terminate_stalled_slot_supervisor_process: kills the exact recorded
# supervisor pid, and is idempotent against an already-exited one ---
supervisor_kill_slot="${TEMP_DIRECTORY}/supervisor-kill"
mkdir -p "${supervisor_kill_slot}"
sleep 30 &
supervisor_pid=$!
printf '%s\n' "${supervisor_pid}" > "${supervisor_kill_slot}/pid"
process_starttime "${supervisor_pid}" > "${supervisor_kill_slot}/pid-starttime"
terminate_stalled_slot_supervisor_process "${supervisor_kill_slot}"
wait "${supervisor_pid}" 2>/dev/null || true
ASSERTIONS=$((ASSERTIONS + 1))
if kill -0 "${supervisor_pid}" 2>/dev/null; then
    fail "The recorded slot supervisor pid was not terminated."
fi
assert_true \
    "A second call against an already-terminated supervisor pid was not idempotent." \
    terminate_stalled_slot_supervisor_process "${supervisor_kill_slot}"

# --- terminate_stalled_slot_supervisor_process: a wrong recorded starttime
# (stale record, or the pid number having been recycled since) never kills
# the live process actually holding that pid today ---
supervisor_stale_starttime_slot="${TEMP_DIRECTORY}/supervisor-stale-starttime"
mkdir -p "${supervisor_stale_starttime_slot}"
sleep 30 &
supervisor_stale_pid=$!
printf '%s\n' "${supervisor_stale_pid}" > "${supervisor_stale_starttime_slot}/pid"
supervisor_real_starttime=$(process_starttime "${supervisor_stale_pid}")
printf '%s\n' "$((supervisor_real_starttime + 1))" > "${supervisor_stale_starttime_slot}/pid-starttime"
assert_true \
    "A wrong-starttime supervisor pid was not reported as a no-op skip." \
    terminate_stalled_slot_supervisor_process "${supervisor_stale_starttime_slot}"
ASSERTIONS=$((ASSERTIONS + 1))
if ! kill -0 "${supervisor_stale_pid}" 2>/dev/null; then
    fail "A supervisor pid recorded with the wrong starttime was killed anyway."
fi
kill -KILL "${supervisor_stale_pid}" 2>/dev/null || true
wait "${supervisor_stale_pid}" 2>/dev/null || true

# --- slot_supervisor_identity_matches: pure guard-logic checks against
# synthetic values, with no risk of ever targeting a real process ---
ASSERTIONS=$((ASSERTIONS + 1))
if slot_supervisor_identity_matches "4242" "1000" "4242"; then
    fail "A candidate pid equal to the manager pid was accepted (must never target the manager itself)."
fi
ASSERTIONS=$((ASSERTIONS + 1))
if slot_supervisor_identity_matches "" "1000" "4242"; then
    fail "An empty candidate pid was accepted by the supervisor identity guard."
fi
ASSERTIONS=$((ASSERTIONS + 1))
if slot_supervisor_identity_matches "4243" "" "4242"; then
    fail "An empty expected starttime was accepted by the supervisor identity guard."
fi
sleep 30 &
role_guard_pid=$!
role_guard_starttime=$(process_starttime "${role_guard_pid}")
ASSERTIONS=$((ASSERTIONS + 1))
if slot_supervisor_identity_matches "${role_guard_pid}" "${role_guard_starttime}" "1"; then
    fail "A live process whose ppid does not match the supplied manager pid was accepted (role check bypassed)."
fi
ASSERTIONS=$((ASSERTIONS + 1))
if ! slot_supervisor_identity_matches "${role_guard_pid}" "${role_guard_starttime}" "$$"; then
    fail "A live, correctly-parented, correct-starttime process was rejected by the supervisor identity guard."
fi
kill -KILL "${role_guard_pid}" 2>/dev/null || true
wait "${role_guard_pid}" 2>/dev/null || true

# --- end-to-end: an actual monitor_runner_container invocation wedged on a
# TERM-ignoring grandchild that inherited its log fifo/pipe is unblocked by
# independent reconciliation alone (no supervisor-process kill needed); the
# monitor completes on its own, its paired process groups are gone, its
# lease/state is released exactly once, and the wrapping "run_slot" stand-in
# resumes to relaunch replacement capacity ---
e2e_root="${TEMP_DIRECTORY}/e2e-wedged"
e2e_docker="${TEMP_DIRECTORY}/e2e-wedged-docker-state"
mkdir -p "${e2e_root}" "${e2e_docker}"
printf '%s\n' "container-e2e" > "${e2e_root}/container-id"
printf '%s\n' "runner-e2e" > "${e2e_root}/container-name"
printf '%s\n' "sha256:$(printf 'a%.0s' $(seq 1 64))" > "${e2e_root}/image-id"
FAKE_DOCKER_SCENARIO="wedged-logs-grandchild"
FAKE_DOCKER_STATE_DIRECTORY="${e2e_docker}"
export FAKE_DOCKER_SCENARIO FAKE_DOCKER_STATE_DIRECTORY
: > "${DIAGNOSTICS_PATH}"
rm -f "${RELEASE_QUEUE_PATH}"
release_call_count_path="${TEMP_DIRECTORY}/e2e-release-calls.count"
: > "${release_call_count_path}"
host_admission_queue_release() {
    printf 'x' >> "${release_call_count_path}"
    printf '%s\n' "$1" > "${RELEASE_QUEUE_PATH}"
}

# A minimal run_slot stand-in: the same synchronous, blocking call to
# monitor_runner_container that a real slot's supervisor loop makes, proving
# that call returning is what lets a wrapping loop reach its next iteration
# and relaunch replacement capacity.
(
    monitor_runner_container \
        "${e2e_root}" \
        "runner-e2e" \
        "container-e2e" \
        "${e2e_root}/worker.log" \
        ""
    : > "${e2e_root}/run-slot-resumed"
    : > "${e2e_root}/run-slot-relaunched"
) &
e2e_supervisor_pid=$!
printf '%s\n' "${e2e_supervisor_pid}" > "${e2e_root}/pid"

# Give the monitor's first cycle time to reach its wedge point (its own
# docker/timeout invocations return immediately; only the untracked
# grandchild's held-open fifo blocks the reader).
e2e_wait_deadline=$(($(date +%s) + 5))
while [ ! -f "${e2e_docker}/logs-grandchild.pid" ]; do
    if [ "$(date +%s)" -ge "${e2e_wait_deadline}" ]; then
        fail "The wedged-logs-grandchild scenario never reached its wedge point."
    fi
    sleep 0.2
done
e2e_logs_pgid=$(cat "${e2e_root}/monitor-logs-pgid" 2>/dev/null || true)
[ -n "${e2e_logs_pgid}" ] || fail "The monitor never recorded its docker-logs process group."
ASSERTIONS=$((ASSERTIONS + 1))
if ! kill -0 "${e2e_supervisor_pid}" 2>/dev/null; then
    fail "The run_slot stand-in exited before reconciliation ran; it was never actually wedged."
fi

# Force the staleness gate open immediately rather than waiting out
# CONTAINER_MONITOR_RECONCILE_GRACE_SECONDS in real time.
printf '%s\n' "$(( $(date +%s) - 999 ))" > "${e2e_root}/monitor-heartbeat"
reconcile_stalled_container_monitor "${e2e_root}"

e2e_settle_deadline=$(($(date +%s) + 5))
while kill -0 "${e2e_supervisor_pid}" 2>/dev/null; do
    if [ "$(date +%s)" -ge "${e2e_settle_deadline}" ]; then
        fail "The run_slot stand-in did not resume after independent reconciliation."
    fi
    sleep 0.2
done
wait "${e2e_supervisor_pid}" 2>/dev/null || true

assert_true \
    "Independent reconciliation did not unblock the wedged monitor's own run_slot stand-in." \
    test -f "${e2e_root}/run-slot-resumed"
assert_true \
    "The run_slot stand-in did not reach relaunching replacement capacity." \
    test -f "${e2e_root}/run-slot-relaunched"
e2e_grandchild_pid=$(cat "${e2e_docker}/logs-grandchild.pid" 2>/dev/null || true)
ASSERTIONS=$((ASSERTIONS + 1))
if [ -n "${e2e_grandchild_pid}" ] && kill -0 "${e2e_grandchild_pid}" 2>/dev/null; then
    fail "The wedged docker-logs grandchild survived independent reconciliation."
fi
ASSERTIONS=$((ASSERTIONS + 1))
if kill -0 -"${e2e_logs_pgid}" 2>/dev/null; then
    fail "The wedged monitor's tracked docker-logs process group survived independent reconciliation."
fi
assert_true \
    "The end-to-end reconciliation retained the exact container identity." \
    test ! -e "${e2e_root}/container-id"
assert_true \
    "The end-to-end reconciliation retained the monitor heartbeat." \
    test ! -e "${e2e_root}/monitor-heartbeat"
assert_true \
    "The end-to-end reconciliation retained the monitor generation." \
    test ! -e "${e2e_root}/monitor-generation"
assert_true \
    "The end-to-end reconciliation retained the monitor docker-logs process group record." \
    test ! -e "${e2e_root}/monitor-logs-pgid"
assert_true \
    "The end-to-end reconciliation retained the monitor docker-wait process group record." \
    test ! -e "${e2e_root}/monitor-wait-pgid"
assert_equals \
    "1" \
    "$(wc -c < "${release_call_count_path}" | tr -d ' ')" \
    "The exact lease was released more than once (or not at all) for the same container."
assert_equals \
    "e2e-wedged" \
    "$(cat "${RELEASE_QUEUE_PATH}" 2>/dev/null || true)" \
    "The end-to-end reconciliation did not durably queue the exact lease release."

echo "Container supervision tests passed: ${ASSERTIONS} assertions."
