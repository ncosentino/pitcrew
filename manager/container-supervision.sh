# Every docker-logs/docker-wait monitor cycle launches through this dedicated
# process-group leader script (never a bare setsid CMD) so the leader itself,
# not a transient docker/timeout process, is the pid whose kernel
# process-birth identity independent reconciliation can trust for the whole
# life of that process group. Callers must set SCRIPT_DIRECTORY before
# sourcing this file (manage-runners.sh already does).
CONTAINER_MONITOR_GROUP_LEADER_SCRIPT="${SCRIPT_DIRECTORY}/container-monitor-group-leader.sh"

# container_monitor_process_group_supervisor_available reports whether this
# host can launch a monitor cycle's docker logs/wait invocation as its own
# process group leader (via setsid) AND independently verify that leader's
# kernel process-birth identity afterward (via /proc). Independent
# reconciliation only ever signals a process group it can prove it created
# this way and can still prove is the exact process it created; when either
# setsid or /proc is unavailable it degrades to file/lease cleanup plus the
# supervisor-process fallback instead of guessing at a group it can never
# re-verify.
container_monitor_process_group_supervisor_available() {
    command -v setsid >/dev/null 2>&1 || return 1
    [ -r "/proc/$$/stat" ]
}

# monitor_generation_nonce produces a value unique to one monitor_runner_container
# invocation (not just one docker-logs/wait cycle within it), combining the
# monitor shell's own PID with the current time so a manager restart or a
# replacement monitor for the same slot never collides with a prior
# generation's value even if the PID is reused.
monitor_generation_nonce() {
    printf '%s-%s\n' "$$" "$(date +%s%N 2>/dev/null || date +%s)"
}

# process_stat_remainder prints a pid's /proc/<pid>/stat contents with the
# leading "pid (comm) " prefix stripped, splitting on the LAST ") " rather
# than the first: comm (the executable's basename) can itself contain
# spaces or parentheses, but no field after it ever does, so only the final
# ") " reliably marks the boundary into the fixed-format fields that follow.
process_stat_remainder() {
    stat_pid="$1"
    stat_path="/proc/${stat_pid}/stat"
    [ -r "${stat_path}" ] || return 1
    stat_line=$(cat "${stat_path}" 2>/dev/null) || return 1
    case "${stat_line}" in
        *') '*) ;;
        *) return 1 ;;
    esac
    stat_remainder=${stat_line##*') '}
    [ -n "${stat_remainder}" ] || return 1
    printf '%s\n' "${stat_remainder}"
}

# process_stat_field prints the given 1-indexed field of a pid's stat
# remainder (state=1, ppid=2, pgrp=3, ..., starttime=20; these correspond to
# the standard /proc/<pid>/stat fields 3, 4, 5, ..., 22 once pid+comm are
# skipped). Fails closed (non-zero, no output) if the pid or field is
# unavailable, which every caller treats as "identity cannot be proven."
process_stat_field() {
    field_pid="$1"
    field_index="$2"
    field_remainder=$(process_stat_remainder "${field_pid}") || return 1
    # shellcheck disable=SC2086
    set -- ${field_remainder}
    [ "$#" -ge "${field_index}" ] || return 1
    shift "$((field_index - 1))"
    [ -n "${1:-}" ] || return 1
    printf '%s\n' "$1"
}

# process_starttime prints a pid's kernel process-birth tick count. Unlike a
# pid or pgid number, this value can never collide between an original
# process and a later, unrelated process that reused the same numeric id, so
# it is the only sound proof of identity for a previously recorded pid.
process_starttime() {
    process_stat_field "$1" 20
}

process_pgrp() {
    process_stat_field "$1" 3
}

process_ppid() {
    process_stat_field "$1" 2
}

# process_group_leader_identity_matches proves a previously recorded
# docker-logs/docker-wait process-group leader pid is still alive, is still
# the exact kernel process that was recorded (its starttime has not changed,
# so the numeric pid was never recycled to an unrelated process since), and
# is still its own process group's leader. A negative-pgid signal is only
# ever issued once this passes; any failure is treated as "cannot prove this
# is still the tracked group" and skips signaling entirely.
process_group_leader_identity_matches() {
    identity_pid="$1"
    identity_expected_starttime="$2"

    case "${identity_pid}" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ -n "${identity_expected_starttime}" ] || return 1
    identity_current_starttime=$(process_starttime "${identity_pid}") || return 1
    [ "${identity_current_starttime}" = "${identity_expected_starttime}" ] || return 1
    identity_current_pgrp=$(process_pgrp "${identity_pid}") || return 1
    [ "${identity_current_pgrp}" = "${identity_pid}" ] || return 1
    return 0
}

# slot_supervisor_identity_matches proves a recorded run_slot supervisor pid
# is still alive, is still the exact kernel process this manager instance
# forked (starttime match), is still a direct child of the given manager pid
# (never a reparented, unrelated process), and is never the manager pid
# itself, before the last-resort supervisor KILL fallback is ever allowed to
# target it. The manager pid is passed in rather than read from $$ so this
# check can be exercised directly against synthetic values in tests without
# any risk of it ever validating true against the caller's own process.
slot_supervisor_identity_matches() {
    identity_pid="$1"
    identity_expected_starttime="$2"
    identity_manager_pid="$3"

    case "${identity_pid}" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "${identity_pid}" != "${identity_manager_pid}" ] || return 1
    [ -n "${identity_expected_starttime}" ] || return 1
    identity_current_starttime=$(process_starttime "${identity_pid}") || return 1
    [ "${identity_current_starttime}" = "${identity_expected_starttime}" ] || return 1
    identity_current_ppid=$(process_ppid "${identity_pid}") || return 1
    [ "${identity_current_ppid}" = "${identity_manager_pid}" ] || return 1
    return 0
}

probe_monitored_container() {
    probed_id="$1"
    probed_inspect_path="$2"

    rm -f "${probed_inspect_path}"
    if timeout \
        -s TERM \
        -k "${CONTAINER_MONITOR_KILL_AFTER_SECONDS}" \
        "${CONTAINER_MONITOR_PROBE_TIMEOUT_SECONDS}" \
        docker inspect "${probed_id}" > "${probed_inspect_path}" 2>/dev/null; then
        if jq -e '.[0].State.Running == true' "${probed_inspect_path}" >/dev/null 2>&1; then
            printf '%s\n' "running"
        elif jq -e '.[0].State.Running == false' "${probed_inspect_path}" >/dev/null 2>&1; then
            printf '%s\n' "exited"
        else
            printf '%s\n' "unavailable"
        fi
        return
    fi

    rm -f "${probed_inspect_path}"
    if probed_ids=$(
        timeout \
            -s TERM \
            -k "${CONTAINER_MONITOR_KILL_AFTER_SECONDS}" \
            "${CONTAINER_MONITOR_PROBE_TIMEOUT_SECONDS}" \
            docker ps \
                --all \
                --quiet \
                --no-trunc \
                --filter "id=${probed_id}" 2>/dev/null
    ); then
        for candidate_id in ${probed_ids}; do
            if [ "${candidate_id}" = "${probed_id}" ]; then
                printf '%s\n' "unavailable"
                return
            fi
        done
        printf '%s\n' "absent"
        return
    fi

    printf '%s\n' "unavailable"
}

# record_monitor_process_group_identity durably records a just-launched
# monitor process-group leader's pid alongside its kernel process-birth
# starttime read from /proc, in that write-ahead order, so a reconciliation
# pass that observes the pgid file already has (or can wait a cycle for) the
# starttime it needs before ever trusting that pgid belongs to this exact
# monitor cycle. A starttime read that fails (for example, an extremely
# short-lived leader that already exited) records an empty value, which
# every signaling path treats as "identity unproven" and skips.
record_monitor_process_group_identity() {
    identity_slot_path="$1"
    identity_kind="$2"
    identity_pid="$3"

    identity_starttime=$(process_starttime "${identity_pid}" 2>/dev/null || true)
    printf '%s\n' "${identity_pid}" > "${identity_slot_path}/monitor-${identity_kind}-pgid"
    printf '%s\n' "${identity_starttime}" > "${identity_slot_path}/monitor-${identity_kind}-pgid-starttime"
}

monitor_runner_container() {
    monitored_slot_path="$1"
    monitored_name="$2"
    monitored_id="$3"
    monitored_log_path="$4"
    monitored_since="${5:-}"

    monitored_started_epoch=$(date +%s)
    monitor_probe_degraded=0
    wait_exit_code=""
    : > "${monitored_log_path}"
    printf '%s\n' "${monitored_started_epoch}" > "${monitored_slot_path}/monitor-heartbeat"
    # The generation nonce lets an independent reconciliation pass prove the
    # docker-logs/docker-wait process group it is about to signal still
    # belongs to this exact monitor invocation and not a replacement that
    # took over the slot in the interim. Any pgid/starttime identity left by
    # a prior generation is cleared at the same time so a reader can never
    # pair a stale identity file with this new generation value.
    monitor_generation=$(monitor_generation_nonce)
    rm -f \
        "${monitored_slot_path}/monitor-logs-pgid" \
        "${monitored_slot_path}/monitor-logs-pgid-starttime" \
        "${monitored_slot_path}/monitor-wait-pgid" \
        "${monitored_slot_path}/monitor-wait-pgid-starttime"
    printf '%s\n' "${monitor_generation}" > "${monitored_slot_path}/monitor-generation"

    while :; do
        monitor_cycle_started_epoch=$(date +%s)
        printf '%s\n' "${monitor_cycle_started_epoch}" > "${monitored_slot_path}/monitor-heartbeat"
        if [ -n "${monitored_since}" ]; then
            set -- docker logs --since "${monitored_since}" --follow "${monitored_id}"
        else
            set -- docker logs --follow "${monitored_id}"
        fi

        # docker logs is piped through an explicit FIFO (rather than a plain
        # `cmd | while read` pipeline) so its writer side can be launched and
        # tracked independently of the reader: a plain pipeline's `$!` only
        # ever names the reader, leaving no way to address the docker/timeout
        # side (or a descendant that inherits its stdout fd) if it survives
        # its own timeout.
        monitor_log_fifo_path="${monitored_slot_path}/.container-log-fifo.$$"
        rm -f "${monitor_log_fifo_path}"
        mkfifo "${monitor_log_fifo_path}"
        while IFS= read -r output_line || [ -n "${output_line:-}" ]; do
            printf '%s\n' "${output_line}"
            printf '%s\n' "${output_line}" >> "${monitored_log_path}"
            case "${output_line}" in
                *"${CONNECT_MARKER}"*)
                    if slot_connect_marker_is_pending "${monitored_slot_path}"; then
                        consume_slot_connect_marker "${monitored_slot_path}"
                        write_slot_runtime_state \
                            "${monitored_slot_path}" \
                            "${OBSERVED_STATE_DIRTY}" \
                            "online" \
                            "${monitored_name}" \
                            0 \
                            0 || true
                    fi
                    ;;
            esac
        done < "${monitor_log_fifo_path}" &
        logs_reader_pid=$!

        rm -f \
            "${monitored_slot_path}/monitor-logs-pgid" \
            "${monitored_slot_path}/monitor-logs-pgid-starttime"
        if container_monitor_process_group_supervisor_available; then
            setsid \
                sh "${CONTAINER_MONITOR_GROUP_LEADER_SCRIPT}" \
                    "${CONTAINER_MONITOR_WINDOW_SECONDS}" \
                    "${CONTAINER_MONITOR_KILL_AFTER_SECONDS}" \
                    "${CONTAINER_MONITOR_GROUP_DRAIN_SECONDS}" \
                    "$@" > "${monitor_log_fifo_path}" 2>&1 &
            logs_pgid=$!
            record_monitor_process_group_identity \
                "${monitored_slot_path}" \
                "logs" \
                "${logs_pgid}"
        else
            timeout \
                -s TERM \
                -k "${CONTAINER_MONITOR_KILL_AFTER_SECONDS}" \
                "${CONTAINER_MONITOR_WINDOW_SECONDS}" \
                "$@" > "${monitor_log_fifo_path}" 2>&1 &
            logs_pgid=$!
        fi

        wait_output_path="${monitored_slot_path}/.container-wait.$$.txt"
        rm -f \
            "${monitored_slot_path}/monitor-wait-pgid" \
            "${monitored_slot_path}/monitor-wait-pgid-starttime"
        if container_monitor_process_group_supervisor_available; then
            setsid \
                sh "${CONTAINER_MONITOR_GROUP_LEADER_SCRIPT}" \
                    "${CONTAINER_MONITOR_WINDOW_SECONDS}" \
                    "${CONTAINER_MONITOR_KILL_AFTER_SECONDS}" \
                    "${CONTAINER_MONITOR_GROUP_DRAIN_SECONDS}" \
                    docker wait "${monitored_id}" > "${wait_output_path}" 2>/dev/null &
            wait_pgid=$!
            record_monitor_process_group_identity \
                "${monitored_slot_path}" \
                "wait" \
                "${wait_pgid}"
        else
            timeout \
                -s TERM \
                -k "${CONTAINER_MONITOR_KILL_AFTER_SECONDS}" \
                "${CONTAINER_MONITOR_WINDOW_SECONDS}" \
                docker wait "${monitored_id}" > "${wait_output_path}" 2>/dev/null &
            wait_pgid=$!
        fi

        wait "${wait_pgid}" 2>/dev/null || true
        wait "${logs_pgid}" 2>/dev/null || true
        wait "${logs_reader_pid}" 2>/dev/null || true
        rm -f "${monitor_log_fifo_path}"
        wait_output=$(cat "${wait_output_path}" 2>/dev/null || true)
        rm -f "${wait_output_path}"

        case "${wait_output}" in
            ''|*[!0-9]*) ;;
            *)
                if [ "${monitor_probe_degraded}" -eq 1 ]; then
                    record_manager_diagnostic \
                        docker \
                        docker-inspect \
                        "${monitored_slot_path##*/}" \
                        recovered \
                        "" \
                        recovered \
                        "Exact worker container supervision recovered"
                    monitor_probe_degraded=0
                fi
                wait_exit_code="${wait_output}"
                break
                ;;
        esac

        exit_inspect_path="${monitored_slot_path}/.container-exit.$$.json"
        monitor_probe=$(
            probe_monitored_container \
                "${monitored_id}" \
                "${exit_inspect_path}"
        )
        case "${monitor_probe}" in
            running)
                if [ "${monitor_probe_degraded}" -eq 1 ]; then
                    record_manager_diagnostic \
                        docker \
                        docker-inspect \
                        "${monitored_slot_path##*/}" \
                        recovered \
                        "" \
                        recovered \
                        "Exact worker container supervision recovered"
                    monitor_probe_degraded=0
                fi
                case "${monitored_since}" in
                    ''|*[!0-9]*)
                        monitored_since="${monitor_cycle_started_epoch}"
                        ;;
                    *)
                        if [ "${monitor_cycle_started_epoch}" -gt "${monitored_since}" ]; then
                            monitored_since="${monitor_cycle_started_epoch}"
                        fi
                        ;;
                esac
                ;;
            exited|absent)
                if [ "${monitor_probe_degraded}" -eq 1 ]; then
                    record_manager_diagnostic \
                        docker \
                        docker-inspect \
                        "${monitored_slot_path##*/}" \
                        recovered \
                        "" \
                        recovered \
                        "Exact worker container state became available"
                fi
                break
                ;;
            *)
                if [ "${monitor_probe_degraded}" -eq 0 ]; then
                    record_manager_diagnostic \
                        docker \
                        docker-inspect \
                        "${monitored_slot_path##*/}" \
                        timed-out \
                        "" \
                        docker-unavailable \
                        "Exact worker container state is unavailable; admission remains fenced"
                    monitor_probe_degraded=1
                fi
                case "${monitored_since}" in
                    ''|*[!0-9]*)
                        monitored_since="${monitor_cycle_started_epoch}"
                        ;;
                    *)
                        if [ "${monitor_cycle_started_epoch}" -gt "${monitored_since}" ]; then
                            monitored_since="${monitor_cycle_started_epoch}"
                        fi
                        ;;
                esac
                sleep "${CONTAINER_MONITOR_RETRY_SECONDS}"
                ;;
        esac
        rm -f "${exit_inspect_path}"
    done

    finalize_stopped_container_slot \
        "${monitored_slot_path}" \
        "${monitored_id}" \
        "${wait_exit_code}" \
        "${monitored_started_epoch}"

    case "${finalize_exit_code}" in
        ''|*[!0-9]*) return 0 ;;
    esac
    [ "${finalize_exit_code}" -le 255 ] || return 0
    return "${finalize_exit_code}"
}

# finalize_stopped_container_slot performs the exact-absence cleanup shared by
# a monitor loop's own confirmed exit and reconcile_stalled_container_monitor's
# independent probe of a stalled monitor: it queues the host-admission lease
# release, captures whatever exit evidence Docker still has, and clears the
# slot's container and monitor-heartbeat records in that order so a reader
# never observes a released lease without also seeing the container record
# cleared. finalize_wait_exit_code and finalize_started_epoch may be empty
# when the caller never observed a `docker wait` result (an independent
# reconciliation acting on a monitor that stopped making progress). The
# resulting exit code, when known, is returned via finalize_exit_code.
finalize_stopped_container_slot() {
    finalize_slot_path="$1"
    finalize_container_id="$2"
    finalize_wait_exit_code="$3"
    finalize_started_epoch="${4:-}"

    if host_admission_enabled; then
        host_admission_queue_release "${finalize_slot_path##*/}" || true
    fi

    # Docker removes an ephemeral worker as soon as it exits, so exit state is
    # captured immediately and never inferred when the record is already gone.
    exit_evidence="unavailable"
    finalize_exit_code="${finalize_wait_exit_code}"
    exit_oom_killed=""
    exit_inspect_path="${finalize_slot_path}/.container-exit.$$.json"
    if timeout \
        -s TERM \
        -k "${CONTAINER_MONITOR_KILL_AFTER_SECONDS}" \
        "${CONTAINER_MONITOR_PROBE_TIMEOUT_SECONDS}" \
        docker inspect "${finalize_container_id}" > "${exit_inspect_path}" 2>/dev/null &&
        jq -e '
            (.[0].State.ExitCode | type == "number")
            and (.[0].State.OOMKilled | type == "boolean")
            and (.[0].State.Running == false)
        ' "${exit_inspect_path}" >/dev/null 2>&1; then
        exit_evidence="docker-inspect"
        finalize_exit_code=$(jq -r '.[0].State.ExitCode' "${exit_inspect_path}")
        exit_oom_killed=$(jq -r '.[0].State.OOMKilled' "${exit_inspect_path}")
    elif [ -n "${finalize_wait_exit_code}" ]; then
        exit_evidence="docker-wait"
    fi
    rm -f "${exit_inspect_path}"
    if [ "${exit_oom_killed}" = "" ] && [ "${finalize_exit_code}" = "137" ] &&
        [ -n "${finalize_started_epoch}" ]; then
        # Docker keeps recent daemon events after an ephemeral worker record is
        # removed, but an out-of-memory event can arrive just after the wait
        # returns, so the query holds a short grace window open. Only an exact
        # container match confirms an out-of-memory kill; a missing event stays
        # unknown instead of turning a plain signal exit into a resource claim.
        oom_actors=$(
            timeout "${EXIT_EVIDENCE_COMMAND_TIMEOUT}" docker events \
                --since "${finalize_started_epoch}" \
                --until "$(($(date +%s) + EXIT_EVIDENCE_EVENT_GRACE_SECONDS))" \
                --filter event=oom \
                --format '{{.Actor.ID}}' 2>/dev/null || true
        )
        for oom_actor in ${oom_actors}; do
            [ "${oom_actor}" = "${finalize_container_id}" ] || continue
            exit_oom_killed="true"
            break
        done
    fi
    write_slot_exit_evidence \
        "${finalize_slot_path}" \
        "${OBSERVED_STATE_DIRTY}" \
        "${exit_evidence}" \
        "${finalize_exit_code}" \
        "${exit_oom_killed}" || true
    if [ "${exit_oom_killed}" = "true" ]; then
        record_manager_diagnostic \
            worker-exit \
            worker-exit \
            "${finalize_slot_path##*/}" \
            failed \
            "" \
            invalid-state \
            "Worker was terminated by a confirmed out of memory kill"
    elif [ "${finalize_exit_code}" != "0" ]; then
        record_manager_diagnostic \
            worker-exit \
            worker-exit \
            "${finalize_slot_path##*/}" \
            failed \
            "" \
            unknown \
            "Worker exited without a clean status"
    fi

    rm -f \
        "${finalize_slot_path}/container-id" \
        "${finalize_slot_path}/container-name" \
        "${finalize_slot_path}/image-id" \
        "${finalize_slot_path}/monitor-heartbeat" \
        "${finalize_slot_path}/monitor-generation" \
        "${finalize_slot_path}/monitor-logs-pgid" \
        "${finalize_slot_path}/monitor-logs-pgid-starttime" \
        "${finalize_slot_path}/monitor-wait-pgid" \
        "${finalize_slot_path}/monitor-wait-pgid-starttime"
    mark_observed_state_dirty
}

# reconcile_terminate_stalled_monitor_supervision requests cancellation of the
# exact docker-logs/docker-wait process groups a stalled monitor recorded for
# terminate_generation against terminate_container_id, then waits up to
# CONTAINER_MONITOR_UNBLOCK_SECONDS for that same monitor cycle (or its normal
# completion path) to clear on its own before escalating from TERM to KILL and
# waiting once more. Every escalation round independently re-validates the
# slot's on-disk container-id and generation, and independently re-validates
# each tracked pid's kernel process-birth identity immediately before it is
# ever signaled, so a monitor that already completed, was replaced, or whose
# recorded pid has since been reused by an unrelated process is never
# touched. Prints exactly one of:
#   skip     - no process-group supervisor available, nothing was tracked, or
#              context (container-id/generation) already moved on
#   settled  - the monitor cleared (container record gone or generation moved
#              on) within the bounded window
#   unsettled - still wedged after TERM and KILL; caller must fall back to
#              write-ahead-only cleanup and unblocking the slot supervisor
reconcile_terminate_stalled_monitor_supervision() {
    terminate_slot_path="$1"
    terminate_container_id="$2"
    terminate_generation="$3"

    if ! container_monitor_process_group_supervisor_available; then
        printf '%s\n' "skip"
        return 0
    fi

    terminate_logs_pgid=""
    terminate_logs_starttime=""
    if [ -f "${terminate_slot_path}/monitor-logs-pgid" ]; then
        terminate_logs_pgid=$(cat "${terminate_slot_path}/monitor-logs-pgid" 2>/dev/null || true)
        terminate_logs_starttime=$(cat "${terminate_slot_path}/monitor-logs-pgid-starttime" 2>/dev/null || true)
    fi
    terminate_wait_pgid=""
    terminate_wait_starttime=""
    if [ -f "${terminate_slot_path}/monitor-wait-pgid" ]; then
        terminate_wait_pgid=$(cat "${terminate_slot_path}/monitor-wait-pgid" 2>/dev/null || true)
        terminate_wait_starttime=$(cat "${terminate_slot_path}/monitor-wait-pgid-starttime" 2>/dev/null || true)
    fi
    if [ -z "${terminate_logs_pgid}" ] && [ -z "${terminate_wait_pgid}" ]; then
        printf '%s\n' "skip"
        return 0
    fi

    # Context (container-id, generation) is re-read only after the pgid/
    # starttime values are already in hand: monitor_runner_container always
    # records a cycle's generation before it ever records that cycle's
    # pgids/starttimes, so a match here proves the values just read cannot
    # belong to a newer generation that has since replaced this one.
    reconcile_terminate_context_matches \
        "${terminate_slot_path}" "${terminate_container_id}" "${terminate_generation}" ||
        { printf '%s\n' "skip"; return 0; }

    reconcile_terminate_signal_pgids TERM \
        "${terminate_logs_pgid}" "${terminate_logs_starttime}" \
        "${terminate_wait_pgid}" "${terminate_wait_starttime}"
    if reconcile_terminate_await_settle \
        "${terminate_slot_path}" "${terminate_generation}" "${CONTAINER_MONITOR_UNBLOCK_SECONDS}"; then
        printf '%s\n' "settled"
        return 0
    fi

    if ! reconcile_terminate_context_matches \
        "${terminate_slot_path}" "${terminate_container_id}" "${terminate_generation}"; then
        printf '%s\n' "settled"
        return 0
    fi
    reconcile_terminate_signal_pgids KILL \
        "${terminate_logs_pgid}" "${terminate_logs_starttime}" \
        "${terminate_wait_pgid}" "${terminate_wait_starttime}"
    if reconcile_terminate_await_settle \
        "${terminate_slot_path}" "${terminate_generation}" "${CONTAINER_MONITOR_UNBLOCK_SECONDS}"; then
        printf '%s\n' "settled"
        return 0
    fi

    printf '%s\n' "unsettled"
}

# reconcile_terminate_context_matches proves the slot's on-disk container-id
# and monitor-generation still match what reconciliation originally observed,
# immediately before any escalation round is allowed to run, so a monitor
# that legitimately replaced its container or started a new generation in the
# interim is never touched by a stale escalation round.
reconcile_terminate_context_matches() {
    context_slot_path="$1"
    context_container_id="$2"
    context_generation="$3"

    context_current_id=$(cat "${context_slot_path}/container-id" 2>/dev/null || true)
    [ "${context_current_id}" = "${context_container_id}" ] || return 1
    context_current_generation=$(cat "${context_slot_path}/monitor-generation" 2>/dev/null || true)
    [ "${context_current_generation}" = "${context_generation}" ] || return 1
    return 0
}

# reconcile_terminate_signal_pgids sends signal_name to each recorded
# process-group leader, but only after independently proving immediately
# beforehand (via process_group_leader_identity_matches) that the exact
# kernel process it recorded is still alive, still started at the same time
# it was recorded (never a pid recycled to an unrelated process since), and
# still its own group's leader. Signaling a negative pid targets the whole
# group (every descendant that inherited it), not just the tracked leader,
# which is what lets a bounded TERM/KILL pair reach a grandchild that still
# holds a monitor's log fifo or wait pipe open, without ever trusting the
# pgid number alone.
reconcile_terminate_signal_pgids() {
    signal_name="$1"
    shift
    while [ "$#" -ge 2 ]; do
        signal_pgid="$1"
        signal_starttime="$2"
        shift 2
        process_group_leader_identity_matches "${signal_pgid}" "${signal_starttime}" || continue
        kill "-${signal_name}" "-${signal_pgid}" 2>/dev/null || true
    done
}

# reconcile_terminate_await_settle polls up to settle_timeout_seconds for
# either the slot's container record to disappear or its monitor generation to
# move past settle_generation, both of which prove the targeted monitor cycle
# is no longer the one reconciliation just signaled. Returns success as soon
# as either is observed, failure once the bound elapses.
reconcile_terminate_await_settle() {
    settle_slot_path="$1"
    settle_generation="$2"
    settle_timeout_seconds="$3"

    settle_deadline_epoch=$(($(date +%s) + settle_timeout_seconds))
    while :; do
        [ -f "${settle_slot_path}/container-id" ] || return 0
        settle_observed_generation=$(cat "${settle_slot_path}/monitor-generation" 2>/dev/null || true)
        [ "${settle_observed_generation}" = "${settle_generation}" ] || return 0
        [ "$(date +%s)" -lt "${settle_deadline_epoch}" ] || return 1
        sleep 1
    done
}

# terminate_stalled_slot_supervisor_process is the last-resort fallback when a
# stalled monitor's tracked process groups cannot be signaled or do not settle
# within the bounded window: it directly kills the run_slot supervisor that is
# synchronously blocked inside the wedged monitor call, so the manager's
# existing not-running slot detection can reap and relaunch it with fresh
# capacity. run_slot inherits manage-runners.sh's top-level shutdown trap for
# TERM/INT, so a plain TERM here would run the *entire* fleet shutdown routine
# inside this one forked slot's process instead of just ending it; KILL is
# used instead because it can never be caught or re-dispatch that trap. The
# recorded pid is only ever killed after slot_supervisor_identity_matches
# proves it is still alive, still the exact process this manager forked
# (starttime match), still that process's direct child (never reparented),
# and never the manager's own pid, so a reused pid can never be hit and this
# can never target the top-level manager or an unrelated slot.
terminate_stalled_slot_supervisor_process() {
    supervisor_slot_path="$1"

    [ -f "${supervisor_slot_path}/pid" ] || return 0
    supervisor_pid=$(cat "${supervisor_slot_path}/pid" 2>/dev/null || true)
    supervisor_starttime=""
    if [ -f "${supervisor_slot_path}/pid-starttime" ]; then
        supervisor_starttime=$(cat "${supervisor_slot_path}/pid-starttime" 2>/dev/null || true)
    fi
    slot_supervisor_identity_matches "${supervisor_pid}" "${supervisor_starttime}" "$$" || return 0
    kill -KILL "${supervisor_pid}" 2>/dev/null || true
}

# reconcile_stalled_container_monitor independently re-verifies exact
# container liveness for one slot whose monitor heartbeat has gone stale (or
# was never written at all, which covers a monitor loop that never started,
# such as a manager-restart adoption whose immediate docker inspect raced a
# container's disappearance). It never acts while the heartbeat is fresh, so
# a healthy monitor cycle is untouched; a proven "running" verdict only
# refreshes the heartbeat, and an unavailable/ambiguous verdict changes
# nothing (fail-closed, retried on the next reconciliation pass). A
# proven-absent verdict first asks reconcile_terminate_stalled_monitor_supervision
# to unblock the actual wedged monitor by its tracked process groups and give
# it a bounded chance to finish on its own; only when that does not settle
# does this function perform the write-ahead cleanup itself and, as a last
# resort, end the run_slot supervisor so the manager's own slot reconciliation
# can relaunch it. Every destructive step re-reads container-id (and, for the
# process-group path, monitor-generation) immediately beforehand, so a monitor
# that legitimately replaced the slot's container or started a new generation
# between the read and this check is never clobbered.
reconcile_stalled_container_monitor() {
    reconcile_slot_path="$1"

    [ -f "${reconcile_slot_path}/container-id" ] || return 0
    reconcile_container_id=$(cat "${reconcile_slot_path}/container-id" 2>/dev/null || true)
    [ -n "${reconcile_container_id}" ] || return 0

    reconcile_heartbeat_epoch=0
    if [ -f "${reconcile_slot_path}/monitor-heartbeat" ]; then
        reconcile_heartbeat_epoch=$(cat "${reconcile_slot_path}/monitor-heartbeat" 2>/dev/null || echo 0)
        case "${reconcile_heartbeat_epoch}" in
            ''|*[!0-9]*) reconcile_heartbeat_epoch=0 ;;
        esac
    fi
    reconcile_now_epoch=$(date +%s)
    if [ $((reconcile_now_epoch - reconcile_heartbeat_epoch)) -lt "${CONTAINER_MONITOR_RECONCILE_GRACE_SECONDS}" ]; then
        return 0
    fi

    reconcile_inspect_path="${reconcile_slot_path}/.container-reconcile.$$.json"
    reconcile_probe=$(probe_monitored_container "${reconcile_container_id}" "${reconcile_inspect_path}")
    rm -f "${reconcile_inspect_path}"

    case "${reconcile_probe}" in
        exited|absent)
            reconcile_current_id=$(cat "${reconcile_slot_path}/container-id" 2>/dev/null || true)
            [ "${reconcile_current_id}" = "${reconcile_container_id}" ] || return 0
            record_manager_diagnostic \
                docker \
                docker-inspect \
                "${reconcile_slot_path##*/}" \
                recovered \
                "" \
                recovered \
                "Independent reconciliation confirmed exact container absence for a stalled monitor"

            reconcile_target_generation=$(cat "${reconcile_slot_path}/monitor-generation" 2>/dev/null || true)
            reconcile_settle=$(
                reconcile_terminate_stalled_monitor_supervision \
                    "${reconcile_slot_path}" \
                    "${reconcile_container_id}" \
                    "${reconcile_target_generation}"
            )
            [ "${reconcile_settle}" = "settled" ] && return 0

            reconcile_final_id=$(cat "${reconcile_slot_path}/container-id" 2>/dev/null || true)
            [ "${reconcile_final_id}" = "${reconcile_container_id}" ] || return 0
            if [ -n "${reconcile_target_generation}" ]; then
                reconcile_final_generation=$(cat "${reconcile_slot_path}/monitor-generation" 2>/dev/null || true)
                [ "${reconcile_final_generation}" = "${reconcile_target_generation}" ] || return 0
            fi

            finalize_stopped_container_slot \
                "${reconcile_slot_path}" \
                "${reconcile_container_id}" \
                "" \
                ""
            # skip means nothing could be tracked/signaled (no setsid, or the
            # monitor never reached a cycle); unsettled means signaling did not
            # unblock it in time. Either way the wedge itself is still present,
            # so the run_slot supervisor is ended directly to unblock capacity.
            terminate_stalled_slot_supervisor_process "${reconcile_slot_path}"
            ;;
        running)
            printf '%s\n' "${reconcile_now_epoch}" > "${reconcile_slot_path}/monitor-heartbeat"
            ;;
        *)
            : # unavailable/ambiguous; fail closed and retry on the next pass
            ;;
    esac
}

# reconcile_stalled_container_monitors sweeps every slot at a bounded
# interval so a stalled monitor cannot strand a slot, container record, or
# host-admission lease for the remaining lifetime of the manager process.
reconcile_stalled_container_monitors() {
    reconcile_scan_now_epoch=$(date +%s)
    if [ $((reconcile_scan_now_epoch - LAST_CONTAINER_MONITOR_RECONCILE_EPOCH)) -lt \
        "${CONTAINER_MONITOR_RECONCILE_INTERVAL_SECONDS}" ]; then
        return 0
    fi
    LAST_CONTAINER_MONITOR_RECONCILE_EPOCH="${reconcile_scan_now_epoch}"
    for reconcile_candidate_path in "${SLOT_DIRECTORY}"/*; do
        [ -d "${reconcile_candidate_path}" ] || continue
        reconcile_stalled_container_monitor "${reconcile_candidate_path}"
    done
}
