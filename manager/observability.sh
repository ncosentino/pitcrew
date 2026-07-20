#!/bin/sh

observed_state_is_valid() {
    jq -e '
        def nonnegative_integer:
            type == "number" and . >= 0 and floor == .;
        def valid_slot:
            type == "object"
            and (.key | type == "string" and length > 0)
            and (.repository == null or (.repository | type == "string"))
            and (.desired | type == "boolean")
            and (.processRunning | type == "boolean")
            and (.jobRunning | type == "boolean")
            and (
                .state == "starting"
                or .state == "online"
                or .state == "backoff"
                or .state == "restarting"
                or .state == "draining"
                or .state == "stopped"
            )
            and (.failureCount | nonnegative_integer)
            and (.backoffSeconds | nonnegative_integer)
            and (.updatedAt == null or (.updatedAt | type == "string" and length > 0));
        type == "object"
        and .schemaVersion == 1
        and (.managerContractVersion | nonnegative_integer and . >= 1)
        and (.profileId | type == "string" and length > 0)
        and (.managerInstanceId | type == "string" and length > 0)
        and (
            .managerStatus == "starting"
            or .managerStatus == "running"
            or .managerStatus == "stopping"
            or .managerStatus == "stopped"
        )
        and (.observedAt | type == "string" and length > 0)
        and (.scope == "repo" or .scope == "org" or .scope == "ent")
        and (.generation | nonnegative_integer)
        and (.desiredStateHash == null or (.desiredStateHash | type == "string" and length > 0))
        and (
            .desiredStateStatus == "waiting"
            or .desiredStateStatus == "accepted"
            or .desiredStateStatus == "invalid"
            or .desiredStateStatus == "stale"
            or .desiredStateStatus == "conflict"
        )
        and (.desiredSlots | nonnegative_integer)
        and (.activeSlots | nonnegative_integer)
        and (.busySlots | nonnegative_integer)
        and (.drainingSlots | nonnegative_integer)
        and (.slots | type == "array")
        and all(.slots[]; valid_slot)
        and (([.slots[].key] | unique | length) == (.slots | length))
    ' "$1" >/dev/null 2>&1
}

write_slot_runtime_state() {
    slot_state_path="$1"
    observed_dirty_path="$2"
    runtime_state="$3"
    runner_name="$4"
    failure_count="$5"
    backoff_seconds="$6"

    case "${runtime_state}" in
        starting|online|backoff|restarting) ;;
        *) return 1 ;;
    esac
    case "${failure_count}" in
        ''|*[!0-9]*) return 1 ;;
    esac
    case "${backoff_seconds}" in
        ''|*[!0-9]*) return 1 ;;
    esac

    runtime_temporary="${slot_state_path}/.runtime-state.$$.tmp"
    if ! jq -n \
        --arg state "${runtime_state}" \
        --arg runnerName "${runner_name}" \
        --argjson failureCount "${failure_count}" \
        --argjson backoffSeconds "${backoff_seconds}" \
        --arg updatedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{
            state: $state,
            runnerName: (if $runnerName == "" then null else $runnerName end),
            failureCount: $failureCount,
            backoffSeconds: $backoffSeconds,
            updatedAt: $updatedAt
        }' > "${runtime_temporary}"; then
        rm -f "${runtime_temporary}"
        return 1
    fi
    if ! mv -f "${runtime_temporary}" "${slot_state_path}/runtime-state.json"; then
        rm -f "${runtime_temporary}"
        return 1
    fi
    [ -n "${observed_dirty_path}" ] && : > "${observed_dirty_path}"
}

render_observed_slots() {
    slot_directory="$1"
    output_path="$2"
    records_path="${output_path}.records"
    : > "${records_path}"

    if [ -d "${slot_directory}" ]; then
        for candidate_path in "${slot_directory}"/*; do
            [ -d "${candidate_path}" ] || continue
            slot_key=${candidate_path##*/}
            repository=""
            if [ -f "${candidate_path}/repo" ]; then
                repository=$(
                    sed \
                        -e 's/^[[:space:]]*//; s/[[:space:]]*$//' \
                        -e 's#^\([A-Za-z][A-Za-z0-9+.-]*://\)[^/@]*@#\1#' \
                        -e 's/[?#].*$//' \
                        "${candidate_path}/repo"
                )
            fi

            process_running=false
            if [ -f "${candidate_path}/pid" ]; then
                candidate_pid=$(cat "${candidate_path}/pid")
                if kill -0 "${candidate_pid}" 2>/dev/null; then
                    process_running=true
                fi
            fi

            # jobRunning is the REAL busy signal: this slot's live supervisor is
            # currently running a GitHub job (its runner printed "Running job:" and
            # not yet "completed with result"). It is gated on process_running so a
            # marker left behind by a crashed supervisor is never mistaken for a
            # live job. Drains must wait on this, never on supervisor liveness.
            job_running=false
            if [ "${process_running}" = "true" ] && [ -f "${candidate_path}/job-active" ]; then
                job_running=true
            fi

            runtime_state="starting"
            failure_count=0
            backoff_seconds=0
            updated_at=""
            runtime_path="${candidate_path}/runtime-state.json"
            runtime_snapshot="${output_path}.${slot_key}.runtime"
            if [ -f "${runtime_path}" ] &&
                cp "${runtime_path}" "${runtime_snapshot}" &&
                jq -e '
                type == "object"
                and (.state == "starting" or .state == "online" or .state == "backoff" or .state == "restarting")
                and (.failureCount | type == "number" and . >= 0 and floor == .)
                and (.backoffSeconds | type == "number" and . >= 0 and floor == .)
            ' "${runtime_snapshot}" >/dev/null 2>&1; then
                runtime_state=$(jq -r '.state' "${runtime_snapshot}")
                failure_count=$(jq -r '.failureCount' "${runtime_snapshot}")
                backoff_seconds=$(jq -r '.backoffSeconds' "${runtime_snapshot}")
                updated_at=$(jq -r '.updatedAt // ""' "${runtime_snapshot}")
            fi
            rm -f "${runtime_snapshot}"

            desired=true
            if [ -f "${candidate_path}/drain" ]; then
                desired=false
                runtime_state="draining"
            elif [ "${process_running}" != "true" ]; then
                runtime_state="stopped"
            fi

            jq -n -c \
                --arg key "${slot_key}" \
                --arg repository "${repository}" \
                --argjson desired "${desired}" \
                --argjson processRunning "${process_running}" \
                --argjson jobRunning "${job_running}" \
                --arg state "${runtime_state}" \
                --argjson failureCount "${failure_count}" \
                --argjson backoffSeconds "${backoff_seconds}" \
                --arg updatedAt "${updated_at}" \
                '{
                    key: $key,
                    repository: (if $repository == "" then null else $repository end),
                    desired: $desired,
                    processRunning: $processRunning,
                    jobRunning: $jobRunning,
                    state: $state,
                    failureCount: $failureCount,
                    backoffSeconds: $backoffSeconds,
                    updatedAt: (if $updatedAt == "" then null else $updatedAt end)
                }' >> "${records_path}" || {
                    rm -f "${records_path}" "${output_path}"
                    return 1
                }
        done
    fi

    if ! jq -s 'sort_by(.key)' "${records_path}" > "${output_path}"; then
        rm -f "${records_path}" "${output_path}"
        return 1
    fi
    rm -f "${records_path}"
}

write_manager_observed_state() {
    output_path="$1"
    profile_id="$2"
    manager_instance_id="$3"
    manager_contract_version="$4"
    manager_status="$5"
    scope="$6"
    generation="$7"
    desired_state_hash="$8"
    desired_state_status="$9"
    desired_slots="${10}"
    slots_path="${11}"

    observed_temporary="${output_path%/*}/.observed-state.$$.tmp"
    if ! jq -n \
        --argjson schemaVersion 1 \
        --argjson managerContractVersion "${manager_contract_version}" \
        --arg profileId "${profile_id}" \
        --arg managerInstanceId "${manager_instance_id}" \
        --arg managerStatus "${manager_status}" \
        --arg observedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg scope "${scope}" \
        --argjson generation "${generation}" \
        --arg desiredStateHash "${desired_state_hash}" \
        --arg desiredStateStatus "${desired_state_status}" \
        --argjson desiredSlots "${desired_slots}" \
        --slurpfile slots "${slots_path}" \
        '{
            schemaVersion: $schemaVersion,
            managerContractVersion: $managerContractVersion,
            profileId: $profileId,
            managerInstanceId: $managerInstanceId,
            managerStatus: $managerStatus,
            observedAt: $observedAt,
            scope: $scope,
            generation: $generation,
            desiredStateHash: (if $desiredStateHash == "" then null else $desiredStateHash end),
            desiredStateStatus: $desiredStateStatus,
            desiredSlots: $desiredSlots,
            activeSlots: ($slots[0] | map(select(.processRunning)) | length),
            busySlots: ($slots[0] | map(select(.jobRunning)) | length),
            drainingSlots: ($slots[0] | map(select(.state == "draining")) | length),
            slots: $slots[0]
        }' > "${observed_temporary}"; then
        rm -f "${observed_temporary}"
        return 1
    fi
    if ! observed_state_is_valid "${observed_temporary}"; then
        rm -f "${observed_temporary}"
        return 1
    fi
    if ! mv -f "${observed_temporary}" "${output_path}"; then
        rm -f "${observed_temporary}"
        return 1
    fi
}
