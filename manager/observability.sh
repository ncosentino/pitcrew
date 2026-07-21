#!/bin/sh

observed_state_is_valid() {
    jq -e '
        def nonnegative_integer:
            type == "number" and . >= 0 and floor == .;
        def valid_resource_usage:
            type == "object"
            and (.cpuCores | type == "number" and . >= 0)
            and (.memoryWorkingSetBytes | nonnegative_integer)
            and (.pids | nonnegative_integer);
        def valid_host_capacity:
            type == "object"
            and (.logicalProcessorCount | nonnegative_integer and . > 0)
            and (.memoryBytes | nonnegative_integer and . > 0);
        def valid_resource_telemetry:
            type == "object"
            and has("host")
            and has("manager")
            and (.sampledAt | type == "string" and length > 0)
            and (
                .status == "available"
                or .status == "partial"
                or .status == "unavailable"
            )
            and (.host == null or (.host | valid_host_capacity))
            and (.manager == null or (.manager | valid_resource_usage));
        def valid_autoscaling:
            type == "object"
            and .mode == "scale-set"
            and (
                .status == "starting"
                or .status == "running"
                or .status == "degraded"
                or .status == "stopping"
            )
            and (.minimumIdleSlots | nonnegative_integer)
            and (.maximumSlots | nonnegative_integer)
            and (.targetSlots | nonnegative_integer)
            and (.assignedJobs | nonnegative_integer)
            and (.runningJobs | nonnegative_integer)
            and (.availableJobs | nonnegative_integer)
            and (.idleRunners | nonnegative_integer)
            and (.busyRunners | nonnegative_integer)
            and (.scaleDownDelaySeconds | nonnegative_integer)
            and (.scaleDownAt == null or (.scaleDownAt | type == "string" and length > 0))
            and (.scaleSetCount | nonnegative_integer)
            and (.lastError == null or (.lastError | type == "string"));
        def valid_update:
            type == "object"
            and (.status == "current" or .status == "rolling" or .status == "degraded")
            and (.targetRevision | type == "string" and test("^[0-9a-f]{64}$"))
            and (.currentWorkers | nonnegative_integer)
            and (.staleWorkers | nonnegative_integer)
            and (.lastError == null or (.lastError | type == "string"));
        def valid_slot:
            type == "object"
            and (.key | type == "string" and length > 0)
            and (.repository == null or (.repository | type == "string"))
            and (.desired | type == "boolean")
            and (.processRunning | type == "boolean")
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
            and (.updatedAt == null or (.updatedAt | type == "string" and length > 0))
            and (.resources == null or (.resources | valid_resource_usage))
            and (
                .activity == null
                or .activity == "starting"
                or .activity == "idle"
                or .activity == "busy"
                or .activity == "draining"
                or .activity == "unknown"
            )
            and (.target == null or (.target | type == "string" and length > 0));
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
        and (.configuredSlots == null or (.configuredSlots | nonnegative_integer))
        and (.activeSlots | nonnegative_integer)
        and (.drainingSlots | nonnegative_integer)
        and (.slots | type == "array")
        and all(.slots[]; valid_slot)
        and (([.slots[].key] | unique | length) == (.slots | length))
        and (
            if .managerContractVersion >= 7 then
                has("resourceTelemetry")
                and (.resourceTelemetry | valid_resource_telemetry)
                and all(.slots[]; has("resources"))
            else
                (.resourceTelemetry == null or (.resourceTelemetry | valid_resource_telemetry))
            end
        )
        and (
            if .managerContractVersion >= 8 then
                has("configuredSlots")
                and has("autoscaling")
                and (.autoscaling == null or (.autoscaling | valid_autoscaling))
            else
                true
            end
        )
        and (
            if .managerContractVersion >= 9 then
                has("update")
                and (.update | valid_update)
            else
                true
            end
        )
        and (
            .resourceTelemetry as $telemetry
            | if $telemetry == null then
                all(.slots[]; .resources == null)
              elif $telemetry.status == "available" then
                $telemetry.host != null
                and $telemetry.manager != null
              elif $telemetry.status == "partial" then
                $telemetry.host != null
                or $telemetry.manager != null
                or any(.slots[]; .resources != null)
              else
                $telemetry.host == null
                and $telemetry.manager == null
                and all(.slots[]; .resources == null)
              end
        )
    ' "$1" >/dev/null 2>&1
}

parse_size_bytes() (
    compact_value=$(printf '%s' "$1" | tr -d '[:space:]')
    number_value=$(printf '%s' "${compact_value}" | sed -n 's/^\([0-9][0-9.]*\)[A-Za-z]*$/\1/p')
    unit_value=$(printf '%s' "${compact_value}" | sed -n 's/^[0-9][0-9.]*\([A-Za-z]*\)$/\1/p')
    [ -n "${number_value}" ] || exit 1

    case "${unit_value}" in
        B|'') multiplier=1 ;;
        kB|KB) multiplier=1000 ;;
        MB) multiplier=1000000 ;;
        GB) multiplier=1000000000 ;;
        TB) multiplier=1000000000000 ;;
        KiB) multiplier=1024 ;;
        MiB) multiplier=1048576 ;;
        GiB) multiplier=1073741824 ;;
        TiB) multiplier=1099511627776 ;;
        *) exit 1 ;;
    esac

    jq -nr \
        --arg numberValue "${number_value}" \
        --argjson multiplier "${multiplier}" \
        '($numberValue | tonumber) * $multiplier | round'
)

parse_cpu_cores() (
    percent_value="$1"
    case "${percent_value}" in
        *%) ;;
        *) exit 1 ;;
    esac
    number_value=${percent_value%\%}
    jq -nr \
        --arg numberValue "${number_value}" \
        '($numberValue | tonumber) / 100'
)

normalize_container_resource_usage() (
    stats_record="$1"
    cpu_percent=$(printf '%s' "${stats_record}" | jq -r '.CPUPerc // empty')
    memory_usage=$(printf '%s' "${stats_record}" | jq -r '.MemUsage // empty')
    pids=$(printf '%s' "${stats_record}" | jq -r '.PIDs // empty')
    memory_working_set=${memory_usage%%/*}
    memory_working_set=$(printf '%s' "${memory_working_set}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')

    cpu_cores=$(parse_cpu_cores "${cpu_percent}") || exit 1
    memory_bytes=$(parse_size_bytes "${memory_working_set}") || exit 1
    case "${pids}" in
        ''|*[!0-9]*) exit 1 ;;
    esac

    jq -n \
        --argjson cpuCores "${cpu_cores}" \
        --argjson memoryWorkingSetBytes "${memory_bytes}" \
        --argjson pids "${pids}" \
        '{
            cpuCores: $cpuCores,
            memoryWorkingSetBytes: $memoryWorkingSetBytes,
            pids: $pids
        }'
)

write_unavailable_resource_telemetry() {
    output_path="$1"
    temporary_path="${output_path%/*}/.resource-telemetry.$$.tmp"
    if ! jq -n \
        --arg sampledAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{
            sampledAt: $sampledAt,
            status: "unavailable",
            host: null,
            manager: null,
            slots: {}
        }' > "${temporary_path}"; then
        rm -f "${temporary_path}"
        return 1
    fi
    if ! mv -f "${temporary_path}" "${output_path}"; then
        rm -f "${temporary_path}"
        return 1
    fi
}

collect_resource_telemetry() (
    output_path="$1"
    managed_label="$2"
    manager_label="$3"
    slot_label_key="$4"
    command_timeout="$5"
    case "${command_timeout}" in
        ''|*[!0-9]*|0) exit 1 ;;
    esac
    working_directory="${output_path%/*}/.resource-telemetry.$$"
    inventory_path="${working_directory}/inventory.tsv"
    ids_path="${working_directory}/ids.txt"
    raw_stats_path="${working_directory}/stats.jsonl"
    normalized_stats_path="${working_directory}/normalized.jsonl"
    host_path="${working_directory}/host.json"
    output_temporary="${output_path%/*}/.resource-telemetry.$$.tmp"
    sampled_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    mkdir -p "${working_directory}" || exit 1
    trap 'rm -rf "${working_directory}" "${output_temporary}"' EXIT
    : > "${inventory_path}"
    : > "${raw_stats_path}"
    : > "${normalized_stats_path}"
    printf 'null\n' > "${host_path}"

    host_available=0
    if timeout "${command_timeout}" docker info \
        --format '{"logicalProcessorCount":{{.NCPU}},"memoryBytes":{{.MemTotal}}}' \
        > "${host_path}.candidate" 2>/dev/null &&
        jq -e '
            (.logicalProcessorCount | type == "number" and . > 0 and floor == .)
            and (.memoryBytes | type == "number" and . > 0 and floor == .)
        ' "${host_path}.candidate" >/dev/null 2>&1; then
        mv -f "${host_path}.candidate" "${host_path}"
        host_available=1
    else
        rm -f "${host_path}.candidate"
    fi

    manager_id="${HOSTNAME:-}"
    if [ -z "${manager_id}" ]; then
        manager_id=$(
            timeout "${command_timeout}" \
                docker ps -q --filter "label=${manager_label}" 2>/dev/null |
                head -n 1
        )
    fi
    if [ -n "${manager_id}" ]; then
        printf '%s\tmanager\t-\t-\n' "${manager_id}" >> "${inventory_path}"
    fi

    worker_inventory_available=0
    if timeout "${command_timeout}" docker ps \
        --filter "label=${managed_label}" \
        --format "{{.ID}} {{.Label \"${slot_label_key}\"}} {{.Names}}" \
        > "${working_directory}/workers.txt" 2>/dev/null; then
        worker_inventory_available=1
        while read -r worker_id worker_slot worker_name; do
            [ -n "${worker_id}" ] || continue
            [ -n "${worker_slot}" ] || continue
            printf '%s\tslot\t%s\t%s\n' \
                "${worker_id}" \
                "${worker_slot}" \
                "${worker_name}" >> "${inventory_path}"
        done < "${working_directory}/workers.txt"
    fi

    cut -f1 "${inventory_path}" > "${ids_path}"
    stats_command_available=1
    if [ -s "${ids_path}" ]; then
        if ! xargs timeout "${command_timeout}" docker stats \
            --no-stream \
            --format '{{json .}}' \
            < "${ids_path}" > "${raw_stats_path}" 2>/dev/null; then
            stats_command_available=0
        fi
    fi

    while IFS= read -r stats_record; do
        [ -n "${stats_record}" ] || continue
        container_id=$(printf '%s' "${stats_record}" | jq -r '.ID // .Container // empty' 2>/dev/null) || continue
        inventory_record=$(awk -F '\t' -v id="${container_id}" '$1 == id { print; exit }' "${inventory_path}")
        [ -n "${inventory_record}" ] || continue
        role=$(printf '%s' "${inventory_record}" | cut -f2)
        slot_key=$(printf '%s' "${inventory_record}" | cut -f3)
        runner_name=$(printf '%s' "${inventory_record}" | cut -f4)
        usage=$(normalize_container_resource_usage "${stats_record}") || continue
        jq -n -c \
            --arg role "${role}" \
            --arg slotKey "${slot_key}" \
            --arg runnerName "${runner_name}" \
            --argjson usage "${usage}" \
            '{
                role: $role,
                slotKey: $slotKey,
                runnerName: $runnerName,
                usage: $usage
            }' >> "${normalized_stats_path}" || exit 1
    done < "${raw_stats_path}"

    manager_available=$(jq -s '[.[] | select(.role == "manager")] | length' "${normalized_stats_path}")
    expected_workers=$(awk -F '\t' '$2 == "slot" { count++ } END { print count + 0 }' "${inventory_path}")
    observed_workers=$(jq -s '[.[] | select(.role == "slot")] | length' "${normalized_stats_path}")
    any_resource_available=$((host_available + manager_available + observed_workers))

    if [ "${host_available}" -eq 1 ] &&
        [ "${manager_available}" -eq 1 ] &&
        [ "${worker_inventory_available}" -eq 1 ] &&
        [ "${stats_command_available}" -eq 1 ] &&
        [ "${expected_workers}" -eq "${observed_workers}" ]; then
        telemetry_status="available"
    elif [ "${any_resource_available}" -gt 0 ]; then
        telemetry_status="partial"
    else
        telemetry_status="unavailable"
    fi

    if ! jq -n \
        --arg sampledAt "${sampled_at}" \
        --arg status "${telemetry_status}" \
        --slurpfile host "${host_path}" \
        --slurpfile records "${normalized_stats_path}" \
        '{
            sampledAt: $sampledAt,
            status: $status,
            host: $host[0],
            manager: (
                [$records[] | select(.role == "manager") | .usage][0] // null
            ),
            slots: (
                reduce (
                    $records[]
                    | select(.role == "slot")
                ) as $record (
                    {};
                    .[$record.slotKey] = {
                        runnerName: $record.runnerName,
                        usage: $record.usage
                    }
                )
            )
        }' > "${output_temporary}"; then
        exit 1
    fi
    mv -f "${output_temporary}" "${output_path}"
)

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
    resource_telemetry_path="$3"
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

            runtime_state="starting"
            failure_count=0
            backoff_seconds=0
            updated_at=""
            runner_name=""
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
                runner_name=$(jq -r '.runnerName // ""' "${runtime_snapshot}")
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
                --arg state "${runtime_state}" \
                --argjson failureCount "${failure_count}" \
                --argjson backoffSeconds "${backoff_seconds}" \
                --arg updatedAt "${updated_at}" \
                --arg runnerName "${runner_name}" \
                --slurpfile resourceTelemetry "${resource_telemetry_path}" \
                '{
                    key: $key,
                    repository: (if $repository == "" then null else $repository end),
                    desired: $desired,
                    processRunning: $processRunning,
                    state: $state,
                    failureCount: $failureCount,
                    backoffSeconds: $backoffSeconds,
                    updatedAt: (if $updatedAt == "" then null else $updatedAt end),
                    resources: (
                        $resourceTelemetry[0].slots[$key] as $slotResources
                        | if $slotResources != null
                            and $slotResources.runnerName == $runnerName
                            and (
                                $state == "starting"
                                or $state == "online"
                                or $state == "draining"
                            )
                          then $slotResources.usage
                          else null
                          end
                    )
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
    resource_telemetry_path="${12}"
    worker_revision="${13}"
    stale_workers="${14}"

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
        --slurpfile resourceTelemetry "${resource_telemetry_path}" \
        --arg workerRevision "${worker_revision}" \
        --argjson staleWorkers "${stale_workers}" \
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
            configuredSlots: $desiredSlots,
            activeSlots: ($slots[0] | map(select(.processRunning)) | length),
            drainingSlots: ($slots[0] | map(select(.state == "draining")) | length),
            slots: $slots[0],
            resourceTelemetry: ($resourceTelemetry[0] | del(.slots)),
            autoscaling: null,
            update: {
                status: (if $staleWorkers > 0 then "rolling" else "current" end),
                targetRevision: $workerRevision,
                currentWorkers: (
                    (($slots[0] | map(select(.processRunning)) | length) - $staleWorkers)
                    | if . < 0 then 0 else . end
                ),
                staleWorkers: $staleWorkers,
                lastError: null
            }
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
