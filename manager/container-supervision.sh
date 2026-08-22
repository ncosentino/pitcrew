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

    while :; do
        monitor_cycle_started_epoch=$(date +%s)
        if [ -n "${monitored_since}" ]; then
            timeout \
                -s TERM \
                -k "${CONTAINER_MONITOR_KILL_AFTER_SECONDS}" \
                "${CONTAINER_MONITOR_WINDOW_SECONDS}" \
                docker logs \
                    --since "${monitored_since}" \
                    --follow \
                    "${monitored_id}" 2>&1
        else
            timeout \
                -s TERM \
                -k "${CONTAINER_MONITOR_KILL_AFTER_SECONDS}" \
                "${CONTAINER_MONITOR_WINDOW_SECONDS}" \
                docker logs --follow "${monitored_id}" 2>&1
        fi |
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
            done &
        logs_pid=$!

        wait_output_path="${monitored_slot_path}/.container-wait.$$.txt"
        timeout \
            -s TERM \
            -k "${CONTAINER_MONITOR_KILL_AFTER_SECONDS}" \
            "${CONTAINER_MONITOR_WINDOW_SECONDS}" \
            docker wait "${monitored_id}" > "${wait_output_path}" 2>/dev/null || true
        wait "${logs_pid}" 2>/dev/null || true
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

    if host_admission_enabled; then
        host_admission_queue_release "${monitored_slot_path##*/}" || true
    fi

    # Docker removes an ephemeral worker as soon as it exits, so exit state is
    # captured immediately and never inferred when the record is already gone.
    exit_evidence="unavailable"
    exit_code="${wait_exit_code}"
    exit_oom_killed=""
    exit_inspect_path="${monitored_slot_path}/.container-exit.$$.json"
    if timeout \
        -s TERM \
        -k "${CONTAINER_MONITOR_KILL_AFTER_SECONDS}" \
        "${CONTAINER_MONITOR_PROBE_TIMEOUT_SECONDS}" \
        docker inspect "${monitored_id}" > "${exit_inspect_path}" 2>/dev/null &&
        jq -e '
            (.[0].State.ExitCode | type == "number")
            and (.[0].State.OOMKilled | type == "boolean")
            and (.[0].State.Running == false)
        ' "${exit_inspect_path}" >/dev/null 2>&1; then
        exit_evidence="docker-inspect"
        exit_code=$(jq -r '.[0].State.ExitCode' "${exit_inspect_path}")
        exit_oom_killed=$(jq -r '.[0].State.OOMKilled' "${exit_inspect_path}")
    elif [ -n "${wait_exit_code}" ]; then
        exit_evidence="docker-wait"
    fi
    rm -f "${exit_inspect_path}"
    if [ "${exit_oom_killed}" = "" ] && [ "${exit_code}" = "137" ]; then
        # Docker keeps recent daemon events after an ephemeral worker record is
        # removed, but an out-of-memory event can arrive just after the wait
        # returns, so the query holds a short grace window open. Only an exact
        # container match confirms an out-of-memory kill; a missing event stays
        # unknown instead of turning a plain signal exit into a resource claim.
        oom_actors=$(
            timeout "${EXIT_EVIDENCE_COMMAND_TIMEOUT}" docker events \
                --since "${monitored_started_epoch}" \
                --until "$(($(date +%s) + EXIT_EVIDENCE_EVENT_GRACE_SECONDS))" \
                --filter event=oom \
                --format '{{.Actor.ID}}' 2>/dev/null || true
        )
        for oom_actor in ${oom_actors}; do
            [ "${oom_actor}" = "${monitored_id}" ] || continue
            exit_oom_killed="true"
            break
        done
    fi
    write_slot_exit_evidence \
        "${monitored_slot_path}" \
        "${OBSERVED_STATE_DIRTY}" \
        "${exit_evidence}" \
        "${exit_code}" \
        "${exit_oom_killed}" || true
    if [ "${exit_oom_killed}" = "true" ]; then
        record_manager_diagnostic \
            worker-exit \
            worker-exit \
            "${monitored_slot_path##*/}" \
            failed \
            "" \
            invalid-state \
            "Worker was terminated by a confirmed out of memory kill"
    elif [ "${exit_code}" != "0" ]; then
        record_manager_diagnostic \
            worker-exit \
            worker-exit \
            "${monitored_slot_path##*/}" \
            failed \
            "" \
            unknown \
            "Worker exited without a clean status"
    fi

    rm -f \
        "${monitored_slot_path}/container-id" \
        "${monitored_slot_path}/container-name" \
        "${monitored_slot_path}/image-id"
    mark_observed_state_dirty
    case "${exit_code}" in
        ''|*[!0-9]*) return 0 ;;
    esac
    [ "${exit_code}" -le 255 ] || return 0
    return "${exit_code}"
}
