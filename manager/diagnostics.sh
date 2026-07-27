#!/bin/sh
# Durable manager-contract-12 operation evidence for the fixed shell manager.
# The journal, subsystem summaries, and capacity evidence describe operations
# this manager performed. They never claim the host, Docker daemon, network, or
# GitHub service is healthy, and they never retain command output, credentials,
# URLs, environment data, job output, or container identity.

DIAGNOSTIC_JOURNAL_CAPACITY=32
DIAGNOSTIC_JOURNAL_MAXIMUM_BYTES=16384
DIAGNOSTIC_EVIDENCE_MAXIMUM_LENGTH=160
DIAGNOSTIC_SLOW_OPERATION_MILLISECONDS=5000
DIAGNOSTIC_UNAVAILABLE_FAILURES=3
DIAGNOSTIC_LOCK_TIMEOUT_SECONDS=5

diagnostic_subsystem_is_valid() {
    case "$1" in
        docker|registration|scale-set-session|listener|jit|worker-launch|worker-exit|telemetry|reconciliation|cleanup|admission|recovery)
            return 0
            ;;
    esac
    return 1
}

diagnostic_operation_is_valid() {
    case "$1" in
        docker-ping|docker-run|docker-inspect|docker-remove|docker-events|registration-token-request|runner-registration|runner-removal|session-create|session-refresh|session-delete|message-poll|message-acknowledge|jit-config-generate|worker-launch|worker-exit|telemetry-sample|desired-state-load|desired-state-apply|capacity-acknowledge|observed-state-publish|registration-cleanup|container-cleanup|admission-reserve|admission-settle|manager-start|manager-shutdown|journal-restore)
            return 0
            ;;
    esac
    return 1
}

diagnostic_outcome_is_valid() {
    case "$1" in
        succeeded|failed|timed-out|retry-scheduled|blocked|recovered|unknown) return 0 ;;
    esac
    return 1
}

diagnostic_reason_is_valid() {
    case "$1" in
        none|docker-unavailable|docker-failed|timeout|rate-limited|authorization-failed|not-found|conflict|invalid-state|capacity-ceiling|retry-backoff|cancelled|recovered|unknown)
            return 0
            ;;
    esac
    return 1
}

# Health is tracked only for the two subsystems the contract publishes. An empty
# key means the operation carries no subsystem-health claim.
diagnostic_health_key() {
    case "$1" in
        docker|worker-launch|telemetry|cleanup) printf 'docker' ;;
        registration|jit|scale-set-session|listener) printf 'github' ;;
        *) printf '' ;;
    esac
}

# Evidence is manager-authored, but sanitizing here keeps a future caller from
# relaying a token, URL, header, or raw command output through observed state.
sanitize_diagnostic_evidence() (
    candidate=$(
        printf '%s' "$1" |
            tr -c "A-Za-z0-9 .,_()'-" ' ' |
            tr -s ' ' |
            sed -e 's/^[^A-Za-z0-9]*//' -e 's/[[:space:]]*$//'
    )
    printf '%s' "${candidate}" | cut -c "1-${DIAGNOSTIC_EVIDENCE_MAXIMUM_LENGTH}"
)

diagnostic_journal_state_is_valid() {
    jq -e '
        def nonnegative_integer:
            type == "number" and . >= 0 and floor == .;
        type == "object"
        and .schemaVersion == 1
        and (.status == "current" or .status == "truncated" or .status == "unavailable")
        and (.capacity | type == "number" and . >= 1 and . <= 64 and floor == .)
        and (.highestSequence == null or (.highestSequence | nonnegative_integer and . >= 1))
        and (.droppedEvents | nonnegative_integer)
        and (.events | type == "array")
    ' "$1" >/dev/null 2>&1
}

diagnostic_event_is_valid() {
    jq -e '
        def nonnegative_integer:
            type == "number" and . >= 0 and floor == .;
        type == "object"
        and (.sequence | nonnegative_integer and . >= 1)
        and (.managerInstanceId | type == "string" and length > 0 and length <= 128)
        and (.observedAt | type == "string" and length > 0)
        and (.subsystem | type == "string")
        and (.operation | type == "string")
        and (.target == null or (.target | type == "string" and length > 0 and length <= 128))
        and (.outcome | type == "string")
        and (
            .durationMilliseconds == null
            or (.durationMilliseconds | nonnegative_integer and . <= 86400000)
        )
        and (.attempt == null or (.attempt | nonnegative_integer and . >= 1 and . <= 1000))
        and (
            .consecutiveFailures == null
            or (.consecutiveFailures | nonnegative_integer and . <= 1000)
        )
        and (.retryAt == null or (.retryAt | type == "string" and length > 0))
        and (.reason | type == "string")
        and (
            .evidence == null
            or (
                .evidence
                | type == "string"
                and length <= 160
                and test("^[A-Za-z0-9][A-Za-z0-9 .,_()'"'"'-]*$")
            )
        )
        and (
            if .outcome == "succeeded" then
                (.reason == "none" or .reason == "recovered")
            else true end
        )
        and (
            if .outcome == "failed" or .outcome == "timed-out" or .outcome == "blocked" then
                .reason != "none"
            else true end
        )
        and (if .outcome == "retry-scheduled" then .retryAt != null else true end)
    ' >/dev/null 2>&1
}

diagnostic_subsystem_health_is_valid() {
    jq -e '
        def nonnegative_integer:
            type == "number" and . >= 0 and floor == .;
        def valid_operation_evidence:
            type == "object"
            and (.operation | type == "string")
            and (.observedAt | type == "string" and length > 0)
            and (
                .durationMilliseconds == null
                or (.durationMilliseconds | nonnegative_integer and . <= 86400000)
            )
            and (.reason | type == "string")
            and (
                .evidence == null
                or (
                    .evidence
                    | type == "string"
                    and length <= 160
                    and test("^[A-Za-z0-9][A-Za-z0-9 .,_()'"'"'-]*$")
                )
            );
        type == "object"
        and (
            .state == "healthy"
            or .state == "degraded"
            or .state == "unavailable"
            or .state == "unknown"
        )
        and (.observedAt | type == "string" and length > 0)
        and (.consecutiveFailures | nonnegative_integer and . <= 1000)
        and (.retryAt == null or (.retryAt | type == "string" and length > 0))
        and (.lastSuccess == null or (.lastSuccess | valid_operation_evidence))
        and (.lastFailure == null or (.lastFailure | valid_operation_evidence))
        and (
            if .state == "healthy" then
                .consecutiveFailures == 0 and .lastSuccess != null
            else true end
        )
        and (
            if .state == "degraded" or .state == "unavailable" then
                .consecutiveFailures >= 1 and .lastFailure != null
            else true end
        )
        and (
            if .state == "unknown" then
                .consecutiveFailures == 0
                and .lastSuccess == null
                and .lastFailure == null
                and .retryAt == null
            else true end
        )
    ' "$1" >/dev/null 2>&1
}

diagnostic_journal_path() {
    printf '%s/journal.json' "$1"
}

diagnostic_health_path() {
    printf '%s/subsystem-%s.json' "$1" "$2"
}

diagnostic_write_unknown_health() {
    unknown_path="$1"
    unknown_temporary="${unknown_path}.$$.tmp"
    if ! jq -n \
        --arg observedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{
            state: "unknown",
            observedAt: $observedAt,
            consecutiveFailures: 0,
            retryAt: null,
            lastSuccess: null,
            lastFailure: null
        }' > "${unknown_temporary}"; then
        rm -f "${unknown_temporary}"
        return 1
    fi
    if ! mv -f "${unknown_temporary}" "${unknown_path}"; then
        rm -f "${unknown_temporary}"
        return 1
    fi
}

diagnostic_acquire_lock() (
    lock_path="$1/.lock"
    waited=0
    while ! mkdir "${lock_path}" 2>/dev/null; do
        lock_created=0
        [ -f "${lock_path}/created" ] &&
            lock_created=$(cat "${lock_path}/created" 2>/dev/null || echo 0)
        case "${lock_created}" in
            ''|*[!0-9]*) lock_created=0 ;;
        esac
        if [ $(($(date +%s) - lock_created)) -ge "${DIAGNOSTIC_LOCK_TIMEOUT_SECONDS}" ]; then
            rm -rf "${lock_path}"
            continue
        fi
        [ "${waited}" -ge "${DIAGNOSTIC_LOCK_TIMEOUT_SECONDS}" ] && exit 1
        sleep 1
        waited=$((waited + 1))
    done
    date +%s > "${lock_path}/created" 2>/dev/null || true
    exit 0
)

diagnostic_release_lock() {
    rm -rf "$1/.lock"
}

# Restores the durable journal, discarding only malformed or oversized entries.
# A journal the manager cannot restore degrades to "unavailable" without losing
# desired state or touching workers.
diagnostics_initialize() {
    diagnostics_directory="$1"
    diagnostics_instance_id="$2"
    mkdir -p "${diagnostics_directory}" || return 1
    # The manager runs as root, so a directory it creates under a bind-mounted
    # state directory must stay replaceable by host-side setup. It holds only
    # sanitized, non-secret operation evidence.
    if [ "$(stat -c '%u' "${diagnostics_directory}")" = "0" ]; then
        chmod 0777 "${diagnostics_directory}" 2>/dev/null || true
    fi
    rm -rf "${diagnostics_directory}/.lock"

    journal_path=$(diagnostic_journal_path "${diagnostics_directory}")
    for health_subsystem in docker github; do
        health_path=$(diagnostic_health_path "${diagnostics_directory}" "${health_subsystem}")
        if [ ! -f "${health_path}" ] ||
            ! diagnostic_subsystem_health_is_valid "${health_path}"; then
            diagnostic_write_unknown_health "${health_path}" || return 1
        fi
    done

    if [ ! -f "${journal_path}" ]; then
        diagnostic_write_empty_journal "${journal_path}" current 0 || return 1
        return 0
    fi

    restored_path="${journal_path}.$$.restore"
    if ! diagnostic_journal_state_is_valid "${journal_path}"; then
        diagnostic_write_empty_journal "${journal_path}" unavailable 1 || return 1
        record_manager_event \
            "${diagnostics_directory}" \
            "${diagnostics_instance_id}" \
            recovery \
            journal-restore \
            "" \
            failed \
            "" \
            invalid-state \
            "Operation journal state was unreadable and was reset" \
            "" || true
        return 0
    fi

    retained_path="${journal_path}.$$.events"
    : > "${retained_path}"
    jq -c '.events[]?' "${journal_path}" 2>/dev/null |
        while IFS= read -r journal_event; do
            [ -n "${journal_event}" ] || continue
            printf '%s' "${journal_event}" | diagnostic_event_is_valid || continue
            printf '%s\n' "${journal_event}" >> "${retained_path}"
        done
    persisted_events=$(jq -r '.events | length' "${journal_path}" 2>/dev/null || echo 0)
    retained_events=$(awk 'END { print NR + 0 }' "${retained_path}")
    discarded_events=$((persisted_events - retained_events))
    [ "${discarded_events}" -lt 0 ] && discarded_events=0

    if ! jq \
        --argjson capacity "${DIAGNOSTIC_JOURNAL_CAPACITY}" \
        --argjson discarded "${discarded_events}" \
        --slurpfile events "${retained_path}" \
        '
            .capacity = $capacity
            | .events = $events
            | .droppedEvents = (.droppedEvents + $discarded)
            | .highestSequence = (
                [.highestSequence // 0, ((.events | map(.sequence)) + [0] | max)] | max
                | if . == 0 then null else . end
            )
            | .status = (if .droppedEvents > 0 then "truncated" else "current" end)
        ' "${journal_path}" > "${restored_path}"; then
        rm -f "${restored_path}" "${retained_path}"
        diagnostic_write_empty_journal "${journal_path}" unavailable 1 || return 1
        return 0
    fi
    rm -f "${retained_path}"
    if ! mv -f "${restored_path}" "${journal_path}"; then
        rm -f "${restored_path}"
        return 1
    fi
    diagnostic_enforce_journal_budget "${journal_path}" || return 1
    if [ "${discarded_events}" -gt 0 ]; then
        record_manager_event \
            "${diagnostics_directory}" \
            "${diagnostics_instance_id}" \
            recovery \
            journal-restore \
            "" \
            blocked \
            "" \
            invalid-state \
            "Discarded malformed operation journal entries during restore" \
            "" || true
    fi
    return 0
}

diagnostic_write_empty_journal() {
    empty_path="$1"
    empty_status="$2"
    empty_dropped="$3"
    empty_temporary="${empty_path}.$$.tmp"
    if ! jq -n \
        --arg status "${empty_status}" \
        --argjson capacity "${DIAGNOSTIC_JOURNAL_CAPACITY}" \
        --argjson droppedEvents "${empty_dropped}" \
        '{
            schemaVersion: 1,
            status: $status,
            capacity: $capacity,
            highestSequence: null,
            droppedEvents: $droppedEvents,
            events: []
        }' > "${empty_temporary}"; then
        rm -f "${empty_temporary}"
        return 1
    fi
    if ! mv -f "${empty_temporary}" "${empty_path}"; then
        rm -f "${empty_temporary}"
        return 1
    fi
}

# Retained events are bounded by count and serialized size. Trimming counts the
# discarded entries instead of silently shrinking the window.
diagnostic_enforce_journal_budget() {
    budget_path="$1"
    budget_temporary="${budget_path}.$$.budget"
    while :; do
        if ! jq \
            --argjson capacity "${DIAGNOSTIC_JOURNAL_CAPACITY}" \
            '
                (.events | length) as $count
                | if $count > $capacity then
                    .droppedEvents = (.droppedEvents + ($count - $capacity))
                    | .events = (.events[($count - $capacity):])
                  else . end
                | .status = (
                    if .status == "unavailable" then "unavailable"
                    elif .droppedEvents > 0 then "truncated"
                    else "current" end
                  )
            ' "${budget_path}" > "${budget_temporary}"; then
            rm -f "${budget_temporary}"
            return 1
        fi
        if ! mv -f "${budget_temporary}" "${budget_path}"; then
            rm -f "${budget_temporary}"
            return 1
        fi
        serialized_bytes=$(
            jq -c '{status, capacity, highestSequence, droppedEvents, events}' "${budget_path}" |
                wc -c |
                tr -d ' '
        )
        case "${serialized_bytes}" in
            ''|*[!0-9]*) return 0 ;;
        esac
        [ "${serialized_bytes}" -le "${DIAGNOSTIC_JOURNAL_MAXIMUM_BYTES}" ] && return 0
        remaining=$(jq -r '.events | length' "${budget_path}")
        [ "${remaining}" -le 1 ] && return 0
        if ! jq '
            .droppedEvents = (.droppedEvents + 1)
            | .events = (.events[1:])
            | .status = (if .status == "unavailable" then "unavailable" else "truncated" end)
        ' "${budget_path}" > "${budget_temporary}"; then
            rm -f "${budget_temporary}"
            return 1
        fi
        if ! mv -f "${budget_temporary}" "${budget_path}"; then
            rm -f "${budget_temporary}"
            return 1
        fi
    done
}

# Records one manager operation: it updates the subsystem summary and appends a
# journal entry for failures, retries, recovery, state transitions, and unusually
# slow operations. Ordinary successful reconciliation is not journaled.
record_manager_event() {
    event_directory="$1"
    event_instance_id="$2"
    event_subsystem="$3"
    event_operation="$4"
    event_target="$5"
    event_outcome="$6"
    event_duration="$7"
    event_reason="$8"
    event_evidence="$9"
    event_retry_at="${10:-}"

    [ -n "${event_directory}" ] || return 1
    [ -d "${event_directory}" ] || return 1
    diagnostic_subsystem_is_valid "${event_subsystem}" || return 1
    diagnostic_operation_is_valid "${event_operation}" || return 1
    diagnostic_outcome_is_valid "${event_outcome}" || return 1
    diagnostic_reason_is_valid "${event_reason}" || return 1
    case "${event_duration}" in
        ''|*[!0-9]*) event_duration="" ;;
        *) [ "${event_duration}" -le 86400000 ] || event_duration=86400000 ;;
    esac
    if [ "${event_outcome}" = "retry-scheduled" ] && [ -z "${event_retry_at}" ]; then
        return 1
    fi
    event_evidence=$(sanitize_diagnostic_evidence "${event_evidence}")
    event_target=$(printf '%s' "${event_target}" | cut -c 1-128)

    diagnostic_acquire_lock "${event_directory}" || return 1
    event_status=0

    event_health_key=$(diagnostic_health_key "${event_subsystem}")
    event_failures_before=0
    event_state_before="unknown"
    event_journal=1
    if [ -n "${event_health_key}" ]; then
        event_health_path=$(diagnostic_health_path "${event_directory}" "${event_health_key}")
        if [ ! -f "${event_health_path}" ] ||
            ! diagnostic_subsystem_health_is_valid "${event_health_path}"; then
            diagnostic_write_unknown_health "${event_health_path}" || event_status=1
        fi
        if [ "${event_status}" -eq 0 ]; then
            event_failures_before=$(jq -r '.consecutiveFailures' "${event_health_path}")
            event_state_before=$(jq -r '.state' "${event_health_path}")
        fi
    fi

    event_failures_after="${event_failures_before}"
    event_state_after="${event_state_before}"
    if [ "${event_outcome}" = "succeeded" ] &&
        [ "${event_failures_before}" -gt 0 ] &&
        [ "${event_reason}" = "none" ]; then
        event_reason="recovered"
    fi
    case "${event_outcome}" in
        succeeded|recovered) event_failures_after=0 ;;
        failed|timed-out|blocked)
            event_failures_after=$((event_failures_before + 1))
            [ "${event_failures_after}" -gt 1000 ] && event_failures_after=1000
            ;;
    esac
    if [ -n "${event_health_key}" ] && [ "${event_status}" -eq 0 ]; then
        case "${event_outcome}" in
            succeeded|recovered) event_state_after="healthy" ;;
            failed|timed-out|blocked)
                if [ "${event_failures_after}" -ge "${DIAGNOSTIC_UNAVAILABLE_FAILURES}" ]; then
                    event_state_after="unavailable"
                else
                    event_state_after="degraded"
                fi
                ;;
        esac
        diagnostic_update_subsystem_health \
            "${event_health_path}" \
            "${event_state_after}" \
            "${event_operation}" \
            "${event_outcome}" \
            "${event_duration}" \
            "${event_failures_after}" \
            "${event_reason}" \
            "${event_evidence}" \
            "${event_retry_at}" || event_status=1

        event_journal=0
        if [ "${event_state_after}" != "${event_state_before}" ]; then
            event_journal=1
        fi
        case "${event_outcome}" in
            failed|timed-out|blocked|retry-scheduled)
                # Repeated identical failures stay bounded instead of filling
                # the window with the same evidence.
                if [ "${event_failures_after}" -le "${DIAGNOSTIC_UNAVAILABLE_FAILURES}" ] ||
                    [ $((event_failures_after % 10)) -eq 0 ]; then
                    event_journal=1
                fi
                ;;
        esac
        if [ -n "${event_duration}" ] &&
            [ "${event_duration}" -ge "${DIAGNOSTIC_SLOW_OPERATION_MILLISECONDS}" ]; then
            event_journal=1
        fi
    fi

    if [ "${event_journal}" -eq 1 ]; then
        diagnostic_append_journal_event \
            "${event_directory}" \
            "${event_instance_id}" \
            "${event_subsystem}" \
            "${event_operation}" \
            "${event_target}" \
            "${event_outcome}" \
            "${event_duration}" \
            "$((event_failures_before + 1))" \
            "${event_failures_after}" \
            "${event_retry_at}" \
            "${event_reason}" \
            "${event_evidence}" || event_status=1
    fi

    diagnostic_release_lock "${event_directory}"
    return "${event_status}"
}

diagnostic_update_subsystem_health() {
    health_output_path="$1"
    health_state="$2"
    health_operation="$3"
    health_outcome="$4"
    health_duration="$5"
    health_failures="$6"
    health_reason="$7"
    health_evidence="$8"
    health_retry_at="$9"
    health_temporary="${health_output_path}.$$.tmp"

    case "${health_outcome}" in
        succeeded|recovered) health_result="success" ;;
        failed|timed-out|blocked) health_result="failure" ;;
        *) health_result="none" ;;
    esac
    if ! jq \
        --arg state "${health_state}" \
        --arg observedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg operation "${health_operation}" \
        --arg result "${health_result}" \
        --arg duration "${health_duration}" \
        --argjson consecutiveFailures "${health_failures}" \
        --arg reason "${health_reason}" \
        --arg evidence "${health_evidence}" \
        --arg retryAt "${health_retry_at}" \
        '
            {
                operation: $operation,
                observedAt: $observedAt,
                durationMilliseconds: (
                    if $duration == "" then null else ($duration | tonumber) end
                ),
                reason: (if $result == "success" and $reason == "" then "none" else $reason end),
                evidence: (if $evidence == "" then null else $evidence end)
            } as $evidenceRecord
            | .state = $state
            | .observedAt = $observedAt
            | .consecutiveFailures = $consecutiveFailures
            | .retryAt = (if $retryAt == "" then null else $retryAt end)
            | if $result == "success" then
                .lastSuccess = $evidenceRecord
              elif $result == "failure" then
                .lastFailure = $evidenceRecord
              else . end
        ' "${health_output_path}" > "${health_temporary}"; then
        rm -f "${health_temporary}"
        return 1
    fi
    if ! mv -f "${health_temporary}" "${health_output_path}"; then
        rm -f "${health_temporary}"
        return 1
    fi
}

diagnostic_append_journal_event() {
    append_directory="$1"
    append_instance_id="$2"
    append_subsystem="$3"
    append_operation="$4"
    append_target="$5"
    append_outcome="$6"
    append_duration="$7"
    append_attempt="$8"
    append_failures="$9"
    append_retry_at="${10}"
    append_reason="${11}"
    append_evidence="${12}"

    append_path=$(diagnostic_journal_path "${append_directory}")
    if [ ! -f "${append_path}" ] ||
        ! diagnostic_journal_state_is_valid "${append_path}"; then
        diagnostic_write_empty_journal "${append_path}" unavailable 1 || return 1
    fi
    [ "${append_attempt}" -ge 1 ] || append_attempt=1
    [ "${append_attempt}" -le 1000 ] || append_attempt=1000

    append_temporary="${append_path}.$$.append"
    if ! jq \
        --arg managerInstanceId "${append_instance_id}" \
        --arg observedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg subsystem "${append_subsystem}" \
        --arg operation "${append_operation}" \
        --arg target "${append_target}" \
        --arg outcome "${append_outcome}" \
        --arg duration "${append_duration}" \
        --argjson attempt "${append_attempt}" \
        --argjson consecutiveFailures "${append_failures}" \
        --arg retryAt "${append_retry_at}" \
        --arg reason "${append_reason}" \
        --arg evidence "${append_evidence}" \
        '
            ((.highestSequence // 0) + 1) as $sequence
            | .highestSequence = $sequence
            | .events += [{
                sequence: $sequence,
                managerInstanceId: $managerInstanceId,
                observedAt: $observedAt,
                subsystem: $subsystem,
                operation: $operation,
                target: (if $target == "" then null else $target end),
                outcome: $outcome,
                durationMilliseconds: (
                    if $duration == "" then null else ($duration | tonumber) end
                ),
                attempt: $attempt,
                consecutiveFailures: $consecutiveFailures,
                retryAt: (if $retryAt == "" then null else $retryAt end),
                reason: $reason,
                evidence: (if $evidence == "" then null else $evidence end)
            }]
            | .status = (
                if .droppedEvents > 0 then "truncated" else "current" end
            )
        ' "${append_path}" > "${append_temporary}"; then
        rm -f "${append_temporary}"
        return 1
    fi
    if ! mv -f "${append_temporary}" "${append_path}"; then
        rm -f "${append_temporary}"
        return 1
    fi
    diagnostic_enforce_journal_budget "${append_path}"
}

render_operation_journal() {
    journal_directory="$1"
    journal_output="$2"
    journal_source=$(diagnostic_journal_path "${journal_directory}")
    journal_temporary="${journal_output}.$$.tmp"

    if [ -f "${journal_source}" ] &&
        diagnostic_journal_state_is_valid "${journal_source}" &&
        jq '{status, capacity, highestSequence, droppedEvents, events}' \
            "${journal_source}" > "${journal_temporary}" 2>/dev/null; then
        if mv -f "${journal_temporary}" "${journal_output}"; then
            return 0
        fi
    fi
    rm -f "${journal_temporary}"
    jq -n \
        --argjson capacity "${DIAGNOSTIC_JOURNAL_CAPACITY}" \
        '{
            status: "unavailable",
            capacity: $capacity,
            highestSequence: null,
            droppedEvents: 0,
            events: []
        }' > "${journal_output}"
}

render_subsystem_health() {
    health_directory="$1"
    health_output="$2"
    health_docker=$(diagnostic_health_path "${health_directory}" docker)
    health_github=$(diagnostic_health_path "${health_directory}" github)
    health_temporary="${health_output}.$$.tmp"
    health_unknown="${health_output}.$$.unknown"

    if ! jq -n \
        --arg observedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{
            state: "unknown",
            observedAt: $observedAt,
            consecutiveFailures: 0,
            retryAt: null,
            lastSuccess: null,
            lastFailure: null
        }' > "${health_unknown}"; then
        rm -f "${health_unknown}"
        return 1
    fi
    if [ ! -f "${health_docker}" ] || ! diagnostic_subsystem_health_is_valid "${health_docker}"; then
        health_docker="${health_unknown}"
    fi
    if [ ! -f "${health_github}" ] || ! diagnostic_subsystem_health_is_valid "${health_github}"; then
        health_github="${health_unknown}"
    fi
    if ! jq -n \
        --slurpfile docker "${health_docker}" \
        --slurpfile github "${health_github}" \
        '{
            docker: $docker[0],
            github: $github[0]
        }' > "${health_temporary}"; then
        rm -f "${health_temporary}" "${health_unknown}"
        return 1
    fi
    rm -f "${health_unknown}"
    if ! mv -f "${health_temporary}" "${health_output}"; then
        rm -f "${health_temporary}"
        return 1
    fi
}

write_unavailable_capacity_evidence() {
    unavailable_output="$1"
    unavailable_temporary="${unavailable_output}.$$.tmp"
    if ! jq -n \
        --arg observedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{
            fixed: {
                observedAt: $observedAt,
                freshness: "unavailable",
                targetSlots: 0,
                activeWorkers: 0,
                startingWorkers: 0,
                drainingWorkers: 0,
                cleanupPendingWorkers: 0,
                eligibleWorkers: null,
                localDeficit: 0,
                eligibilityDeficit: null,
                reason: "unknown",
                evidence: null
            },
            targets: []
        }' > "${unavailable_temporary}"; then
        rm -f "${unavailable_temporary}"
        return 1
    fi
    if ! mv -f "${unavailable_temporary}" "${unavailable_output}"; then
        rm -f "${unavailable_temporary}"
        return 1
    fi
}

# Fixed-profile capacity evidence is measured against the accepted desired slot
# count. Local worker counts and GitHub eligibility stay separate, and the reason
# reports the manager's own blocking state instead of an inferred diagnosis.
render_fixed_capacity_evidence() {
    capacity_slots_path="$1"
    capacity_target_slots="$2"
    capacity_desired_status="$3"
    capacity_health_path="$4"
    capacity_output="$5"
    capacity_temporary="${capacity_output}.$$.tmp"

    case "${capacity_target_slots}" in
        ''|*[!0-9]*) capacity_target_slots=0 ;;
    esac
    if [ ! -f "${capacity_health_path}" ]; then
        write_unavailable_capacity_evidence "${capacity_output}"
        return
    fi
    if ! jq -n \
        --arg observedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --argjson targetSlots "${capacity_target_slots}" \
        --arg desiredStatus "${capacity_desired_status}" \
        --slurpfile slots "${capacity_slots_path}" \
        --slurpfile health "${capacity_health_path}" \
        '
            ($slots[0] // []) as $slots
            | ($health[0] // {}) as $health
            | ($slots | map(select(.state == "online" and .processRunning)) | length) as $active
            | ($slots | map(select(.state == "starting" or .state == "restarting")) | length) as $starting
            | ($slots | map(select(.state == "draining")) | length) as $draining
            | ($slots | map(select(.state == "backoff")) | length) as $backoff
            | (
                $slots
                | map(select(
                    .desired
                    and (
                        .registrationStatus == "registration-missing"
                        or .registrationStatus == "disconnected"
                    )))
                | length
              ) as $cleanupPending
            | (
                if ($health.github.state // "unknown") == "unknown"
                    or ($health.github.state // "unknown") == "unavailable" then
                    null
                elif ($slots | length) > 0
                    and all($slots[]; .registrationStatus == "unknown") then
                    null
                else
                    ($slots | map(select(.registrationStatus == "connected")) | length)
                end
              ) as $eligible
            | (
                [$targetSlots - ($active + $starting), 0] | max
              ) as $localDeficit
            | (
                if $eligible == null then null
                else ([$targetSlots - $eligible, 0] | max)
                end
              ) as $eligibilityDeficit
            | (
                if $localDeficit == 0 and (($eligibilityDeficit // 0) == 0) then
                    ["none", null]
                elif $desiredStatus == "invalid"
                    or $desiredStatus == "stale"
                    or $desiredStatus == "conflict" then
                    [
                        "invalid-desired-state",
                        "Desired capacity was rejected so the manager retained its accepted generation"
                    ]
                elif ($health.docker.state // "unknown") == "unavailable" then
                    ["docker-unavailable", "Manager Docker operations are failing"]
                elif ($health.docker.state // "unknown") == "degraded" then
                    ["docker-failed", "A recent manager Docker operation failed"]
                elif $backoff > 0 then
                    ["retry-backoff", "A worker slot is waiting for its launch backoff window"]
                elif $starting > 0 or $localDeficit > 0 then
                    ["launch-pending", "A worker slot has not reached its launched worker yet"]
                elif $cleanupPending > 0 then
                    [
                        "registration-cleanup-pending",
                        "A worker registration is not usable and is pending replacement"
                    ]
                elif $draining > 0 then
                    ["worker-draining", "A worker is draining before its slot is released"]
                else
                    ["unknown", null]
                end
              ) as $deficit
            | {
                fixed: {
                    observedAt: $observedAt,
                    freshness: "current",
                    targetSlots: $targetSlots,
                    activeWorkers: $active,
                    startingWorkers: $starting,
                    drainingWorkers: $draining,
                    cleanupPendingWorkers: $cleanupPending,
                    eligibleWorkers: $eligible,
                    localDeficit: $localDeficit,
                    eligibilityDeficit: $eligibilityDeficit,
                    reason: $deficit[0],
                    evidence: $deficit[1]
                },
                targets: []
            }
        ' > "${capacity_temporary}"; then
        rm -f "${capacity_temporary}"
        write_unavailable_capacity_evidence "${capacity_output}"
        return
    fi
    if ! mv -f "${capacity_temporary}" "${capacity_output}"; then
        rm -f "${capacity_temporary}"
        return 1
    fi
}
