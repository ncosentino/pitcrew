# Slot registry primitives shared by manage-runners.sh and its tests.
# Extracted into their own sourceable file (like container-supervision.sh)
# so slot_is_running's identity validation and reconcile_slots' respawn
# decision can be exercised directly against real/synthetic processes
# without executing manage-runners.sh's own top-level manager startup and
# main loop. Callers must set SLOT_DIRECTORY, source container-supervision.sh
# and reconciliation.sh (for write_undesired_slot_keys), and define
# start_slot and mark_observed_state_dirty before sourcing this file
# (manage-runners.sh already does all of that).

slot_path() {
    printf '%s/%s' "${SLOT_DIRECTORY}" "$1"
}

# slot_is_running proves a recorded run_slot supervisor pid is still the
# exact process this manager forked, never just that its numeric pid is
# currently occupied by some unrelated process: a bare `kill -0` cannot tell
# a live reused pid apart from the original supervisor, so it is never
# trusted alone once a kernel process-birth starttime was recorded for that
# slot.
slot_is_running() {
    candidate_path=$(slot_path "$1")
    [ -f "${candidate_path}/pid" ] || return 1
    candidate_pid=$(cat "${candidate_path}/pid")

    if [ ! -r "/proc/$$/stat" ]; then
        # This host cannot prove kernel process-birth identity at all;
        # degrade to the same liveness-only check every other Linux-only
        # safeguard in this feature falls back to, rather than treating
        # every slot as permanently stopped on such a host.
        kill -0 "${candidate_pid}" 2>/dev/null
        return
    fi

    candidate_starttime=""
    if [ -f "${candidate_path}/pid-starttime" ]; then
        candidate_starttime=$(cat "${candidate_path}/pid-starttime" 2>/dev/null || true)
    fi
    if [ -z "${candidate_starttime}" ]; then
        # A record with no recorded birth identity can never be proven
        # still-original. slot_is_running only ever runs after
        # record_slot_supervisor_pid has already returned earlier in this
        # same single-threaded manager loop, so this is not a legitimate
        # in-flight record racing its own write-ahead identity capture; it
        # is treated as stopped, the same as an actual manager restart
        # already treats any state it cannot verify (discard and let the
        # normal desired-capacity path recreate it).
        return 1
    fi

    slot_supervisor_identity_matches "${candidate_pid}" "${candidate_starttime}" "$$"
}

remove_slot_registry() {
    removed_path=$(slot_path "$1")
    removed_registry=0
    [ -d "${removed_path}" ] && removed_registry=1
    if [ -f "${removed_path}/pid" ]; then
        removed_pid=$(cat "${removed_path}/pid")
        wait "${removed_pid}" 2>/dev/null || true
    fi
    rm -rf "${removed_path}"
    [ "${removed_registry}" -eq 1 ] && mark_observed_state_dirty
}

# record_slot_supervisor_pid durably records a just-backgrounded run_slot
# supervisor's pid alongside its kernel process-birth starttime, in that
# write-ahead order, so slot_is_running and the last-resort supervisor-kill
# fallback in container-supervision.sh can each prove a recorded pid is
# still the exact process this manager forked before ever trusting or
# signaling it.
record_slot_supervisor_pid() {
    recorded_slot_path="$1"
    recorded_pid="$2"

    recorded_starttime=$(process_starttime "${recorded_pid}" 2>/dev/null || true)
    printf '%s\n' "${recorded_pid}" > "${recorded_slot_path}/pid"
    printf '%s\n' "${recorded_starttime}" > "${recorded_slot_path}/pid-starttime"
}

# reconcile_slots respawns any desired slot whose supervisor slot_is_running
# no longer proves alive (dead, or a live pid whose birth identity no longer
# matches what was recorded) and only ever drops bookkeeping, never
# respawns, for an undesired/draining slot in the same state.
reconcile_slots() {
    desired_slots_path="$1"
    added_path="$2"
    draining_path="$3"
    unchanged_path="$4"
    active_keys_path="/tmp/pitcrew-active-keys.$$"
    undesired_keys_path="/tmp/pitcrew-undesired-keys.$$"
    : > "${added_path}"
    : > "${draining_path}"
    : > "${unchanged_path}"

    tab=$(printf '\t')
    while IFS="${tab}" read -r desired_key desired_repo desired_tag; do
        [ -n "${desired_key}" ] || continue
        [ "${desired_repo}" = "-" ] && desired_repo=""
        if slot_is_running "${desired_key}"; then
            desired_drain_path="$(slot_path "${desired_key}")/drain"
            if [ -f "${desired_drain_path}" ]; then
                rm -f "${desired_drain_path}"
                mark_observed_state_dirty
            fi
            printf '%s\n' "${desired_key}" >> "${unchanged_path}"
        else
            remove_slot_registry "${desired_key}"
            start_slot "${desired_key}" "${desired_repo}" "${desired_tag}"
            printf '%s\n' "${desired_key}" >> "${added_path}"
        fi
    done < "${desired_slots_path}"

    : > "${active_keys_path}"
    for active_path in "${SLOT_DIRECTORY}"/*; do
        [ -d "${active_path}" ] || continue
        active_key=${active_path##*/}
        printf '%s\n' "${active_key}" >> "${active_keys_path}"
    done
    write_undesired_slot_keys \
        "${desired_slots_path}" \
        "${active_keys_path}" \
        "${undesired_keys_path}"
    while IFS= read -r active_key; do
        [ -n "${active_key}" ] || continue
        active_path=$(slot_path "${active_key}")
        if slot_is_running "${active_key}"; then
            if [ ! -f "${active_path}/drain" ]; then
                : > "${active_path}/drain"
                mark_observed_state_dirty
            fi
            printf '%s\n' "${active_key}" >> "${draining_path}"
        else
            remove_slot_registry "${active_key}"
        fi
    done < "${undesired_keys_path}"

    rm -f "${active_keys_path}" "${undesired_keys_path}"
}
