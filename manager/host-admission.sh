#!/bin/sh

HOST_ADMISSION_NAMESPACE="${PITCREW_HOST_ADMISSION_NAMESPACE:-}"
HOST_ADMISSION_SOCKET="${PITCREW_HOST_ADMISSION_SOCKET:-}"
HOST_ADMISSION_CLI_TIMEOUT="${PITCREW_HOST_ADMISSION_CLI_TIMEOUT:-10}"
HOST_ADMISSION_CLI="${PITCREW_HOST_ADMISSION_CLI:-/usr/local/bin/pitcrew-admission}"
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
