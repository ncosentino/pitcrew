#!/bin/sh

HOST_ADMISSION_NAMESPACE="${PITCREW_HOST_ADMISSION_NAMESPACE:-}"
HOST_ADMISSION_SOCKET="${PITCREW_HOST_ADMISSION_SOCKET:-}"
HOST_ADMISSION_CLI_TIMEOUT="${PITCREW_HOST_ADMISSION_CLI_TIMEOUT:-10}"
HOST_ADMISSION_CLI="${PITCREW_HOST_ADMISSION_CLI:-/usr/local/bin/pitcrew-admission}"
HOST_ADMISSION_HOST_FINGERPRINT="${PITCREW_HOST_ADMISSION_HOST_FINGERPRINT:-}"
HOST_ADMISSION_PROFILE_FINGERPRINT="${PITCREW_HOST_ADMISSION_PROFILE_FINGERPRINT:-}"
HOST_ADMISSION_WAIT_MARKER="host-admission-waiting"
HOST_ADMISSION_LEASE_FILE="host-admission-lease.json"

host_admission_enabled() {
    [ -n "${HOST_ADMISSION_NAMESPACE}" ]
}

host_admission_configuration_is_valid() {
    if ! host_admission_enabled; then
        [ -z "${HOST_ADMISSION_SOCKET}" ]
        return
    fi
    printf '%s' "${HOST_ADMISSION_NAMESPACE}" |
        grep -Eq '^[a-z][a-z0-9-]{0,31}$' || return 1
    [ "${HOST_ADMISSION_SOCKET}" = "/var/lib/pitcrew-admission/coordinator.sock" ] ||
        return 1
    [ -x "${HOST_ADMISSION_CLI}" ] || return 1
    case "${HOST_ADMISSION_CLI_TIMEOUT}" in
        ''|*[!0-9]*|0) return 1 ;;
    esac
}

host_admission_cli() {
    timeout "${HOST_ADMISSION_CLI_TIMEOUT}" \
        "${HOST_ADMISSION_CLI}" \
        "$@" \
        --socket "${HOST_ADMISSION_SOCKET}"
}

host_admission_publish_demand() {
    slot_directory="$1"
    host_admission_enabled || return 0
    pending=0
    for slot_state_path in "${slot_directory}"/*; do
        [ -d "${slot_state_path}" ] || continue
        [ -f "${slot_state_path}/${HOST_ADMISSION_WAIT_MARKER}" ] || continue
        pending=$((pending + 1))
    done
    host_admission_cli \
        set-demand \
        --profile "${PROFILE_ID}" \
        --demand "${pending}" >/dev/null 2>&1
}

host_admission_begin_wait() {
    slot_state_path="$1"
    slot_directory="$2"
    host_admission_enabled || return 0
    : > "${slot_state_path}/${HOST_ADMISSION_WAIT_MARKER}"
    host_admission_publish_demand "${slot_directory}" || true
}

host_admission_end_wait() {
    slot_state_path="$1"
    slot_directory="$2"
    host_admission_enabled || return 0
    rm -f "${slot_state_path}/${HOST_ADMISSION_WAIT_MARKER}"
    host_admission_publish_demand "${slot_directory}" || true
}

# Returns 0 when a lease was acquired, 2 when host budget withheld the
# request, and 1 when coordinator availability or protocol failed.
host_admission_acquire() {
    slot_state_path="$1"
    slot_key="$2"
    slot_directory="$3"
    host_admission_enabled || return 0

    host_admission_begin_wait "${slot_state_path}" "${slot_directory}"
    lease_temporary="${slot_state_path}/.${HOST_ADMISSION_LEASE_FILE}.$$"
    host_admission_cli \
        acquire \
        --profile "${PROFILE_ID}" \
        --slot "${slot_key}" \
        --demand 1 > "${lease_temporary}" 2>"${lease_temporary}.error"
    acquire_status=$?
    if [ "${acquire_status}" -eq 3 ]; then
        rm -f "${lease_temporary}" "${lease_temporary}.error"
        return 2
    fi
    if [ "${acquire_status}" -ne 0 ] ||
        ! jq -e \
            --arg profile "${PROFILE_ID}" \
            --arg slot "${slot_key}" \
            '
                .profileId == $profile
                and .slotKey == $slot
                and (.status == "provisional" or .status == "active")
                and (.units | (type == "number" and . > 0))
                and (.leaseId | (type == "string" and length > 0))
            ' "${lease_temporary}" >/dev/null 2>&1; then
        rm -f "${lease_temporary}" "${lease_temporary}.error"
        return 1
    fi
    mv -f "${lease_temporary}" "${slot_state_path}/${HOST_ADMISSION_LEASE_FILE}"
    rm -f "${lease_temporary}.error"
    host_admission_end_wait "${slot_state_path}" "${slot_directory}"
    return 0
}

host_admission_activate() {
    slot_state_path="$1"
    slot_key="$2"
    host_admission_enabled || return 0

    lease_temporary="${slot_state_path}/.${HOST_ADMISSION_LEASE_FILE}.$$"
    if ! host_admission_cli \
        activate \
        --profile "${PROFILE_ID}" \
        --slot "${slot_key}" > "${lease_temporary}" 2>/dev/null ||
        ! jq -e \
            --arg profile "${PROFILE_ID}" \
            --arg slot "${slot_key}" \
            '
                .profileId == $profile
                and .slotKey == $slot
                and .status == "active"
            ' "${lease_temporary}" >/dev/null 2>&1; then
        rm -f "${lease_temporary}"
        return 1
    fi
    mv -f "${lease_temporary}" "${slot_state_path}/${HOST_ADMISSION_LEASE_FILE}"
}

host_admission_release() {
    slot_state_path="$1"
    slot_key="$2"
    host_admission_enabled || return 0

    host_admission_cli \
        release \
        --profile "${PROFILE_ID}" \
        --slot "${slot_key}" >/dev/null 2>&1
    release_status=$?
    if [ "${release_status}" -ne 0 ] && [ "${release_status}" -ne 4 ]; then
        return 1
    fi
    rm -f "${slot_state_path}/${HOST_ADMISSION_LEASE_FILE}"
    if [ -n "${PITCREW_HOST_ADMISSION_RELEASE_DIRECTORY:-}" ]; then
        rm -f \
            "${PITCREW_HOST_ADMISSION_RELEASE_DIRECTORY}/${slot_key}.pending"
    fi
}

host_admission_reconcile_absent() {
    slot_state_path="$1"
    slot_key="$2"
    host_admission_enabled || return 0

    host_admission_cli \
        reconcile \
        --profile "${PROFILE_ID}" \
        --slot "${slot_key}" \
        --evidence "worker-and-registration-absent" >/dev/null 2>&1
    reconcile_status=$?
    if [ "${reconcile_status}" -ne 0 ] && [ "${reconcile_status}" -ne 4 ]; then
        return 1
    fi
    rm -f "${slot_state_path}/${HOST_ADMISSION_LEASE_FILE}"
}

host_admission_queue_release() {
    slot_key="$1"
    host_admission_enabled || return 0
    release_directory="${PITCREW_HOST_ADMISSION_RELEASE_DIRECTORY:-}"
    [ -n "${release_directory}" ] || return 1
    mkdir -p "${release_directory}"
    release_temporary="${release_directory}/.${slot_key}.$$.tmp"
    printf '%s\n' "${slot_key}" > "${release_temporary}" || {
        rm -f "${release_temporary}"
        return 1
    }
    mv -f \
        "${release_temporary}" \
        "${release_directory}/${slot_key}.pending"
}

host_admission_release_or_queue() {
    slot_state_path="$1"
    slot_key="$2"
    if host_admission_release "${slot_state_path}" "${slot_key}"; then
        return 0
    fi
    host_admission_queue_release "${slot_key}" || true
    return 1
}

host_admission_retry_releases() {
    release_directory="${PITCREW_HOST_ADMISSION_RELEASE_DIRECTORY:-}"
    host_admission_enabled || return 0
    [ -n "${release_directory}" ] || return 1
    [ -d "${release_directory}" ] || return 0
    for pending_path in "${release_directory}"/*.pending; do
        [ -f "${pending_path}" ] || continue
        pending_slot=${pending_path##*/}
        pending_slot=${pending_slot%.pending}
        host_admission_cli \
            release \
            --profile "${PROFILE_ID}" \
            --slot "${pending_slot}" >/dev/null 2>&1
        release_status=$?
        if [ "${release_status}" -eq 0 ] || [ "${release_status}" -eq 4 ]; then
            rm -f "${pending_path}"
        fi
    done
}

_host_admission_write_closed_status() {
    output_path="$1"
    closed_status="$2"
    namespace_argument="$3"
    jq -n \
        --arg status "${closed_status}" \
        --arg namespace "${namespace_argument}" \
        '{
            status: $status,
            namespace: (if $namespace == "" then null else $namespace end),
            epoch: null,
            decisionSequence: null,
            capacityUnits: null,
            safetyMarginUnits: null,
            effectiveTotalUnits: null,
            availableUnits: null,
            hostPolicyFingerprint: null,
            accounting: null,
            lastDecision: null
        }' > "${output_path}"
}

# host_admission_status writes this profile's scoped hostAdmission
# observed-state object to "${output_path}". It never fails the caller:
# reading the coordinator's status is diagnostics-only, so an unreachable
# coordinator is reported as status "unavailable" (every measured field
# null, never a fabricated zero) rather than surfaced as an error that
# could influence lifecycle. This mirrors
# hostAdmissionCoordinator.sampleObservedHostAdmission in the autoscaler:
# only this profile's own accounting entry and (if it belongs to this
# profile) last decision are ever reported, never another profile's
# identity, even though `host_admission_cli status` itself returns the
# full multi-profile ledger.
host_admission_status() {
    output_path="$1"
    if ! host_admission_enabled; then
        _host_admission_write_closed_status "${output_path}" "disabled" ""
        return 0
    fi

    status_temporary="${output_path}.$$.tmp"
    if ! host_admission_cli status > "${status_temporary}" 2>/dev/null ||
        ! jq -e 'type == "object"' "${status_temporary}" >/dev/null 2>&1; then
        rm -f "${status_temporary}"
        _host_admission_write_closed_status \
            "${output_path}" \
            "unavailable" \
            "${HOST_ADMISSION_NAMESPACE}"
        return 0
    fi

    if jq \
        --arg profile "${PROFILE_ID}" \
        --arg namespace "${HOST_ADMISSION_NAMESPACE}" \
        --arg hostFingerprint "${HOST_ADMISSION_HOST_FINGERPRINT}" \
        --arg profileFingerprint "${HOST_ADMISSION_PROFILE_FINGERPRINT}" \
        '
            (.accounting // [] | map(select(.profileId == $profile)) | .[0]) as $own
            | ($own != null) as $known
            | (
                (
                    $hostFingerprint != ""
                    and (.hostPolicyFingerprint // "") != ""
                    and .hostPolicyFingerprint != $hostFingerprint
                )
                or (
                    $known
                    and $profileFingerprint != ""
                    and ($own.profilePolicyFingerprint // "") != ""
                    and $own.profilePolicyFingerprint != $profileFingerprint
                )
                or ($known | not)
            ) as $degraded
            | (.lastDecision // null) as $decision
            | (
                if $decision != null and $decision.profileId == $profile then
                    {
                        sequence: $decision.sequence,
                        command: $decision.command,
                        granted: $decision.granted,
                        failureCategory: ($decision.failureCategory // null),
                        decidedAtUnixNano: $decision.decidedAtUnixNano
                    }
                else
                    null
                end
            ) as $ownDecision
            | {
                status: (if $degraded then "degraded" else "available" end),
                namespace: (if $namespace == "" then null else $namespace end),
                epoch: .epoch,
                decisionSequence: .decisionSequence,
                capacityUnits: (
                    if (.capacityUnits // 0) > 0 then .capacityUnits else null end
                ),
                safetyMarginUnits: (
                    if (.capacityUnits // 0) > 0 then (.safetyMarginUnits // 0) else null end
                ),
                effectiveTotalUnits: .effectiveTotalUnits,
                availableUnits: .availableUnits,
                hostPolicyFingerprint: (.hostPolicyFingerprint // null),
                accounting: (
                    if $known then {
                        unitCost: $own.unitCost,
                        reservedUnits: $own.reservedUnits,
                        borrowable: $own.borrowable,
                        profilePolicyFingerprint: ($own.profilePolicyFingerprint // null),
                        activeUnits: $own.activeUnits,
                        provisionalUnits: $own.provisionalUnits,
                        heldUnits: $own.heldUnits,
                        borrowedUnits: $own.borrowedUnits,
                        pendingUnits: $own.pendingUnits,
                        withheldUnits: $own.withheldUnits
                    } else null end
                ),
                lastDecision: $ownDecision
            }
        ' "${status_temporary}" > "${output_path}"; then
        rm -f "${status_temporary}"
        return 0
    fi
    rm -f "${status_temporary}"
    _host_admission_write_closed_status \
        "${output_path}" \
        "unavailable" \
        "${HOST_ADMISSION_NAMESPACE}"
    return 0
}
