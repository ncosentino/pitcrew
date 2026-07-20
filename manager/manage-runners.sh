#!/bin/sh
# Reconciles truly-ephemeral GitHub Actions runner slots from mounted desired
# state. Each slot owns one foreground `docker run --rm`; after that runner exits,
# a desired slot launches a clean replacement while a draining slot stops.
set -u

SCRIPT_DIRECTORY=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "${SCRIPT_DIRECTORY}/reconciliation.sh"
. "${SCRIPT_DIRECTORY}/observability.sh"

MANAGER_CONTRACT_VERSION=7
EXPECTED_CONTRACT_VERSION="${PITCREW_MANAGER_CONTRACT_VERSION:-7}"
if [ "${EXPECTED_CONTRACT_VERSION}" != "${MANAGER_CONTRACT_VERSION}" ]; then
    echo "[manager] contract mismatch: setup expects ${EXPECTED_CONTRACT_VERSION}, manager provides ${MANAGER_CONTRACT_VERSION}" >&2
    exit 1
fi

PREFIX="${RUNNER_NAME_PREFIX:-runner}"
IMAGE="${RUNNER_IMAGE:-myoung34/github-runner:ubuntu-noble}"
PROFILE_ID="${RUNNER_PROFILE_ID:-default}"
STATE_DIRECTORY="${PITCREW_STATE_DIRECTORY:-/var/lib/pitcrew}"
DESIRED_STATE_PATH="${STATE_DIRECTORY}/desired-capacity.json"
ACCEPTED_STATE_PATH="${STATE_DIRECTORY}/last-valid-capacity.json"
ACKNOWLEDGEMENT_PATH="${STATE_DIRECTORY}/acknowledged-capacity.json"
OBSERVED_STATE_PATH="${STATE_DIRECTORY}/observed-state.json"
# Cooperative drain markers (contract v7+). Host-side setup drops a
# drain-request to fence the pool before a manager recreate; the manager answers
# with a drain-complete once every job has finished and no runner is left
# listening, so a static/contract replacement never interrupts an active job.
DRAIN_REQUEST_PATH="${STATE_DIRECTORY}/drain-request.json"
DRAIN_COMPLETE_PATH="${STATE_DIRECTORY}/drain-complete.json"
RECONCILE_INTERVAL="${PITCREW_RECONCILE_INTERVAL:-1}"
OBSERVED_STATE_INTERVAL="${PITCREW_OBSERVED_STATE_INTERVAL:-30}"
SLOT_DIRECTORY="/tmp/pitcrew-slots"
CURRENT_DESIRED_SLOTS="/tmp/pitcrew-current-desired-slots.tsv"
PENDING_ACKNOWLEDGEMENT="/tmp/pitcrew-pending-acknowledgement.json"
OBSERVED_STATE_DIRTY="/tmp/pitcrew-observed-state-dirty"
MANAGED_LABEL_KEY="ephemeral-managed-runner-profile"
MANAGED_LABEL="${MANAGED_LABEL_KEY}=${PROFILE_ID}"
SLOT_LABEL_KEY="ephemeral-managed-runner-slot"

case "${RECONCILE_INTERVAL}" in
    ''|*[!0-9]*|0)
        echo "[manager:${PROFILE_ID}] PITCREW_RECONCILE_INTERVAL must be a positive integer." >&2
        exit 1
        ;;
esac
case "${OBSERVED_STATE_INTERVAL}" in
    ''|*[!0-9]*|0)
        echo "[manager:${PROFILE_ID}] PITCREW_OBSERVED_STATE_INTERVAL must be a positive integer." >&2
        exit 1
        ;;
esac

LABELS="${RUNNER_LABELS:-}"
append_label() {
    case ",${LABELS}," in
        *",$1,"*) ;;
        *) LABELS="${LABELS:+${LABELS},}$1" ;;
    esac
}
if [ "${RUNNER_NO_DEFAULT_LABELS:-}" = "1" ]; then
    case "$(uname -m)" in
        x86_64) architecture_label="x64" ;;
        aarch64|arm64) architecture_label="arm64" ;;
        armv7l|armv6l) architecture_label="arm" ;;
        *) architecture_label="$(uname -m | tr '[:upper:]' '[:lower:]')" ;;
    esac
    append_label "linux"
    append_label "${architecture_label}"
fi

# Optional per-runner resource limits. Unset by default so the docker run
# invocation below is byte-for-byte identical to the historical behavior unless
# an operator opts in. Without a cap a single heavy CI job can consume all host
# memory or fork unbounded processes, so the kernel OOM killer reaps runner
# processes host-wide at one instant — the "two runners lost at the same second"
# signature. A malformed value is rejected loudly and dropped rather than
# silently pretending to cap the job.
RUNNER_MEMORY_LIMIT="${RUNNER_MEMORY_LIMIT:-}"
RUNNER_MEMORY_SWAP_LIMIT="${RUNNER_MEMORY_SWAP_LIMIT:-}"
RUNNER_CPU_LIMIT="${RUNNER_CPU_LIMIT:-}"
RUNNER_PIDS_LIMIT="${RUNNER_PIDS_LIMIT:-}"

# >>> pitcrew:resource_limit_validators >>>
# Direct-Compose (bootstrap) startup bypasses Setup-Runner's PowerShell
# validators, so the manager MUST enforce the SAME Docker constraints here or an
# operator who mis-sets a limit gets a silently-uncapped runner — the exact
# fleet-wide OOM footgun issue #8 is about. These predicates mirror
# Resolve-RunnerProfile: memory >= 6MB, memory-swap >= memory, cpu > 0 with at
# most nine decimals (Docker NanoCPU), pids > 0. All conversions are
# overflow-safe: a value is rejected before it could exceed Int64 (POSIX shell
# arithmetic is 64-bit but wraps silently past that), so an enormous limit can
# never wrap into a small one that slips past the minimum checks. Extracted
# between sentinels so the contract suite exercises the real bytes under sh.
RUNNER_MINIMUM_MEMORY_BYTES=6291456

# Expand a Docker byte value (digits with an optional b/k/m/g suffix) to an exact
# byte count. Prints the byte count on success; returns 1 for a malformed value
# OR one large enough that the multiplication could overflow 64-bit arithmetic.
# The per-suffix digit cap guarantees value*multiplier stays below Int64 max, so
# the arithmetic below is always exact.
runner_expand_bytes() {
    case "$1" in
        *[bB]) rb_unit=b; rb_num=${1%?} ;;
        *[kK]) rb_unit=k; rb_num=${1%?} ;;
        *[mM]) rb_unit=m; rb_num=${1%?} ;;
        *[gG]) rb_unit=g; rb_num=${1%?} ;;
        *)     rb_unit=b; rb_num=$1 ;;
    esac
    case "${rb_num}" in
        ''|*[!0-9]*) return 1 ;;
    esac
    rb_stripped=${rb_num#"${rb_num%%[!0]*}"}
    [ -n "${rb_stripped}" ] || rb_stripped=0
    case "${rb_unit}" in
        b) rb_mult=1;          rb_maxlen=18 ;;
        k) rb_mult=1024;       rb_maxlen=15 ;;
        m) rb_mult=1048576;    rb_maxlen=12 ;;
        g) rb_mult=1073741824; rb_maxlen=9  ;;
    esac
    [ "${#rb_stripped}" -le "${rb_maxlen}" ] || return 1
    printf '%s' "$(( rb_stripped * rb_mult ))"
}

is_valid_memory_value() {
    mv_bytes=$(runner_expand_bytes "$1") || return 1
    [ "${mv_bytes}" -ge "${RUNNER_MINIMUM_MEMORY_BYTES}" ]
}

# --memory-swap must be a byte value no smaller than --memory. $1 = swap, $2 =
# memory. Both are expanded overflow-safe before an exact 64-bit comparison.
is_valid_memory_swap_pair() {
    sp_swap=$(runner_expand_bytes "$1") || return 1
    sp_mem=$(runner_expand_bytes "$2") || return 1
    [ "${sp_swap}" -ge "${sp_mem}" ]
}

is_valid_cpu_value() {
    case "$1" in
        ''|.|*[!0-9.]*|*.*.*) return 1 ;;
    esac
    cpu_int=${1%%.*}
    case "$1" in
        *.*) cpu_frac=${1#*.} ;;
        *)   cpu_frac="" ;;
    esac
    case "${cpu_int}" in
        ''|*[!0-9]*) return 1 ;;
    esac
    # Docker converts --cpus to whole NanoCPUs (value * 1e9); more than nine
    # decimals is "too precise" and rejected.
    [ "${#cpu_frac}" -le 9 ] || return 1
    cpu_int_stripped=${cpu_int#"${cpu_int%%[!0]*}"}
    [ -n "${cpu_int_stripped}" ] || cpu_int_stripped=0
    # Cap the integer core count so int*1e9 cannot overflow Int64 NanoCPUs.
    [ "${#cpu_int_stripped}" -le 9 ] || return 1
    cpu_frac_padded="${cpu_frac}000000000"
    cpu_frac_padded=${cpu_frac_padded%"${cpu_frac_padded#?????????}"}
    cpu_frac_nanos=${cpu_frac_padded#"${cpu_frac_padded%%[!0]*}"}
    [ -n "${cpu_frac_nanos}" ] || cpu_frac_nanos=0
    cpu_nano=$(( cpu_int_stripped * 1000000000 + cpu_frac_nanos ))
    # Docker treats a zero cpu limit as unlimited, which defeats the cap.
    [ "${cpu_nano}" -gt 0 ]
}

is_valid_pids_value() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac
    pids_stripped=${1#"${1%%[!0]*}"}
    [ -n "${pids_stripped}" ] || pids_stripped=0
    [ "${pids_stripped}" != "0" ] || return 1
    [ "${#pids_stripped}" -le 18 ]
}
# <<< pitcrew:resource_limit_validators <<<

reject_runner_limit() {
    echo "[manager:${PROFILE_ID}] $1 Refusing to start with an unenforceable resource limit; fix the value and restart." >&2
    exit 1
}

if [ -n "${RUNNER_MEMORY_LIMIT}" ] && ! is_valid_memory_value "${RUNNER_MEMORY_LIMIT}"; then
    reject_runner_limit "invalid RUNNER_MEMORY_LIMIT='${RUNNER_MEMORY_LIMIT}': expected a Docker byte value of at least 6MB (${RUNNER_MINIMUM_MEMORY_BYTES} bytes), e.g. 512m or 6g."
fi
if [ -n "${RUNNER_MEMORY_SWAP_LIMIT}" ]; then
    if [ -z "${RUNNER_MEMORY_LIMIT}" ]; then
        reject_runner_limit "RUNNER_MEMORY_SWAP_LIMIT='${RUNNER_MEMORY_SWAP_LIMIT}' is set without RUNNER_MEMORY_LIMIT; Docker requires --memory alongside --memory-swap."
    fi
    if [ -z "$(runner_expand_bytes "${RUNNER_MEMORY_SWAP_LIMIT}")" ]; then
        reject_runner_limit "invalid RUNNER_MEMORY_SWAP_LIMIT='${RUNNER_MEMORY_SWAP_LIMIT}': expected a Docker byte value, e.g. 512m or 6g."
    fi
    if ! is_valid_memory_swap_pair "${RUNNER_MEMORY_SWAP_LIMIT}" "${RUNNER_MEMORY_LIMIT}"; then
        reject_runner_limit "RUNNER_MEMORY_SWAP_LIMIT='${RUNNER_MEMORY_SWAP_LIMIT}' is smaller than RUNNER_MEMORY_LIMIT='${RUNNER_MEMORY_LIMIT}'; Docker requires --memory-swap >= --memory."
    fi
fi
if [ -n "${RUNNER_CPU_LIMIT}" ] && ! is_valid_cpu_value "${RUNNER_CPU_LIMIT}"; then
    reject_runner_limit "invalid RUNNER_CPU_LIMIT='${RUNNER_CPU_LIMIT}': expected a core count greater than zero with at most nine decimals (Docker NanoCPU), e.g. 2 or 1.5. Docker treats 0 as unlimited."
fi
if [ -n "${RUNNER_PIDS_LIMIT}" ] && ! is_valid_pids_value "${RUNNER_PIDS_LIMIT}"; then
    reject_runner_limit "invalid RUNNER_PIDS_LIMIT='${RUNNER_PIDS_LIMIT}': expected a positive integer process count greater than zero."
fi

runner_resource_limits_summary=""
[ -n "${RUNNER_MEMORY_LIMIT}" ] && runner_resource_limits_summary="${runner_resource_limits_summary} memory=${RUNNER_MEMORY_LIMIT}"
[ -n "${RUNNER_MEMORY_SWAP_LIMIT}" ] && runner_resource_limits_summary="${runner_resource_limits_summary} memory-swap=${RUNNER_MEMORY_SWAP_LIMIT}"
[ -n "${RUNNER_CPU_LIMIT}" ] && runner_resource_limits_summary="${runner_resource_limits_summary} cpus=${RUNNER_CPU_LIMIT}"
[ -n "${RUNNER_PIDS_LIMIT}" ] && runner_resource_limits_summary="${runner_resource_limits_summary} pids=${RUNNER_PIDS_LIMIT}"
if [ -n "${runner_resource_limits_summary}" ]; then
    echo "[manager:${PROFILE_ID}] per-runner resource limits:${runner_resource_limits_summary}"
else
    echo "[manager:${PROFILE_ID}] per-runner resource limits: none (set RUNNER_MEMORY_LIMIT/RUNNER_CPU_LIMIT/RUNNER_PIDS_LIMIT to cap heavy jobs)"
fi

# >>> pitcrew:classify_runner_exit >>>
# Maps a captured container exit-status string to a stable classification token.
# A missing, empty, or non-numeric capture is 'unknown' (an error): the
# container's real disposition could not be observed and MUST NOT be reported as
# a clean job completion. This function is extracted between sentinels so the
# contract suite can source and exercise it under a real POSIX shell.
classify_runner_exit() {
    classify_input="$1"
    case "${classify_input}" in
        ''|*[!0-9]*) printf 'unknown'; return 0 ;;
    esac
    if [ "${classify_input}" -eq 0 ]; then
        printf 'clean'
    elif [ "${classify_input}" -eq 137 ]; then
        printf 'oom-kill'
    elif [ "${classify_input}" -ge 128 ]; then
        printf 'signal:%s' "$((classify_input - 128))"
    else
        printf 'error:%s' "${classify_input}"
    fi
    return 0
}
# <<< pitcrew:classify_runner_exit <<<

CONNECT_MARKER="Listening for Jobs"
MAX_BACKOFF="${RUNNER_MAX_BACKOFF:-120}"
RUNNER_STOP_TIMEOUT=20
SUPERVISOR_STOP_TIMEOUT=5
CURRENT_GENERATION=0
CURRENT_STATE_HASH=""
LAST_DESIRED_DOCUMENT_HASH=""
LAST_REJECTION=""
STOPPING=0
DRAINING=0
MANAGER_STATUS="starting"
LAST_OBSERVED_STATE_PUBLISH_EPOCH=0
rand_hex() {
    tr -dc 'a-f0-9' < /dev/urandom 2>/dev/null | head -c 6
}

if [ -r /proc/sys/kernel/random/uuid ]; then
    MANAGER_INSTANCE_ID=$(tr -d '\r\n' < /proc/sys/kernel/random/uuid)
else
    MANAGER_INSTANCE_ID="${PROFILE_ID}-$(date +%s)-$(rand_hex)"
fi

rand_jitter() {
    random_byte=$(od -An -N1 -tu1 /dev/urandom 2>/dev/null | tr -d ' ')
    echo $(( ${random_byte:-0} % 5 ))
}

mark_observed_state_dirty() {
    : > "${OBSERVED_STATE_DIRTY}"
}

publish_observed_state() {
    force="${1:-0}"
    observed_now=$(date +%s)
    if [ "${force}" != "1" ] &&
        [ ! -f "${OBSERVED_STATE_DIRTY}" ] &&
        [ $((observed_now - LAST_OBSERVED_STATE_PUBLISH_EPOCH)) -lt "${OBSERVED_STATE_INTERVAL}" ]; then
        return
    fi

    rm -f "${OBSERVED_STATE_DIRTY}"
    observed_slots_path="/tmp/pitcrew-observed-slots.json"
    if ! render_observed_slots "${SLOT_DIRECTORY}" "${observed_slots_path}"; then
        rm -f "${observed_slots_path}"
        mark_observed_state_dirty
        echo "[manager:${PROFILE_ID}] could not render observed slot state" >&2
        return
    fi

    observed_scope="${RUNNER_SCOPE:-repo}"
    if [ -f "${ACCEPTED_STATE_PATH}" ] && desired_state_is_valid "${ACCEPTED_STATE_PATH}"; then
        observed_scope=$(jq -r '.scope' "${ACCEPTED_STATE_PATH}")
    fi
    if [ -n "${LAST_REJECTION}" ]; then
        observed_desired_status=${LAST_REJECTION%%:*}
    elif [ "${CURRENT_GENERATION}" -gt 0 ]; then
        observed_desired_status="accepted"
    else
        observed_desired_status="waiting"
    fi

    observed_desired_count=0
    if [ -f "${CURRENT_DESIRED_SLOTS}" ]; then
        observed_desired_count=$(count_lines "${CURRENT_DESIRED_SLOTS}")
    fi

    if write_manager_observed_state \
        "${OBSERVED_STATE_PATH}" \
        "${PROFILE_ID}" \
        "${MANAGER_INSTANCE_ID}" \
        "${MANAGER_CONTRACT_VERSION}" \
        "${MANAGER_STATUS}" \
        "${observed_scope}" \
        "${CURRENT_GENERATION}" \
        "${CURRENT_STATE_HASH}" \
        "${observed_desired_status}" \
        "${observed_desired_count}" \
        "${observed_slots_path}"; then
        LAST_OBSERVED_STATE_PUBLISH_EPOCH="${observed_now}"
    else
        mark_observed_state_dirty
        echo "[manager:${PROFILE_ID}] could not publish observed state" >&2
    fi
    rm -f "${observed_slots_path}"
}

wait_for_cleanup_commands() {
    cleanup_pids="$1"
    cleanup_failed=0
    for cleanup_pid in ${cleanup_pids}; do
        if ! wait "${cleanup_pid}"; then
            cleanup_failed=1
        fi
    done
    [ "${cleanup_failed}" -eq 0 ]
}

stop_managed_gracefully() {
    graceful_ids=$(docker ps -q --filter "label=${MANAGED_LABEL}") || return 1
    graceful_pids=""
    for graceful_id in ${graceful_ids}; do
        docker stop \
            --timeout "${RUNNER_STOP_TIMEOUT}" \
            "${graceful_id}" >/dev/null 2>&1 &
        graceful_pids="${graceful_pids} $!"
    done
    wait_for_cleanup_commands "${graceful_pids}"
}

remove_managed() {
    removal_ids=$(docker ps -aq --filter "label=${MANAGED_LABEL}" 2>/dev/null || true)
    removal_pids=""
    for removal_id in ${removal_ids}; do
        docker rm -f "${removal_id}" >/dev/null 2>&1 &
        removal_pids="${removal_pids} $!"
    done
    wait_for_cleanup_commands "${removal_pids}" || true
}

remove_managed_strict() {
    strict_ids=$(docker ps -aq --filter "label=${MANAGED_LABEL}") || return 1
    strict_pids=""
    for strict_id in ${strict_ids}; do
        docker rm -f "${strict_id}" >/dev/null 2>&1 &
        strict_pids="${strict_pids} $!"
    done
    wait_for_cleanup_commands "${strict_pids}" || return 1
    strict_remaining=$(docker ps -aq --filter "label=${MANAGED_LABEL}") || return 1
    [ -z "${strict_remaining}" ]
}

shutdown() {
    echo "[manager:${PROFILE_ID}] received stop signal — stopping managed runner containers"
    STOPPING=1
    MANAGER_STATUS="stopping"
    for stopping_path in "${SLOT_DIRECTORY}"/*; do
        [ -d "${stopping_path}" ] || continue
        : > "${stopping_path}/drain"
    done
    mark_observed_state_dirty
    publish_observed_state 1
    if ! stop_managed_gracefully; then
        echo "[manager:${PROFILE_ID}] one or more runners did not stop gracefully; forcing cleanup" >&2
    fi
    remove_managed_strict || true
    mark_observed_state_dirty
    publish_observed_state 1

    shutdown_elapsed=0
    while [ "${shutdown_elapsed}" -lt "${SUPERVISOR_STOP_TIMEOUT}" ]; do
        supervisors_running=0
        for stopping_path in "${SLOT_DIRECTORY}"/*; do
            [ -d "${stopping_path}" ] || continue
            if [ -f "${stopping_path}/pid" ]; then
                stopping_pid=$(cat "${stopping_path}/pid")
                if kill -0 "${stopping_pid}" 2>/dev/null; then
                    supervisors_running=1
                fi
            fi
        done
        [ "${supervisors_running}" -eq 0 ] && break
        sleep 1
        shutdown_elapsed=$((shutdown_elapsed + 1))
    done

    for stopping_path in "${SLOT_DIRECTORY}"/*; do
        [ -d "${stopping_path}" ] || continue
        if [ -f "${stopping_path}/pid" ]; then
            stopping_pid=$(cat "${stopping_path}/pid")
            if kill -0 "${stopping_pid}" 2>/dev/null; then
                kill "${stopping_pid}" 2>/dev/null || true
            fi
        fi
    done
    sleep 1
    remove_managed_strict || true
    for stopping_path in "${SLOT_DIRECTORY}"/*; do
        [ -d "${stopping_path}" ] || continue
        if [ -f "${stopping_path}/pid" ]; then
            stopping_pid=$(cat "${stopping_path}/pid")
            if kill -0 "${stopping_pid}" 2>/dev/null; then
                kill -KILL "${stopping_pid}" 2>/dev/null || true
            fi
            wait "${stopping_pid}" 2>/dev/null || true
        fi
    done
    if ! remove_managed_strict; then
        echo "[manager:${PROFILE_ID}] managed runners remain after shutdown cleanup" >&2
        MANAGER_STATUS="stopping"
        mark_observed_state_dirty
        publish_observed_state 1
        exit 1
    fi
    rm -rf "${SLOT_DIRECTORY}"
    mkdir -p "${SLOT_DIRECTORY}"
    MANAGER_STATUS="stopped"
    mark_observed_state_dirty
    publish_observed_state 1
    exit 0
}
trap shutdown TERM INT

slot_path() {
    printf '%s/%s' "${SLOT_DIRECTORY}" "$1"
}

slot_is_running() {
    candidate_path=$(slot_path "$1")
    [ -f "${candidate_path}/pid" ] || return 1
    candidate_pid=$(cat "${candidate_path}/pid")
    kill -0 "${candidate_pid}" 2>/dev/null
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

run_slot() {
    slot_key="$1"
    repo="$2"
    tag="$3"
    slot_state_path=$(slot_path "${slot_key}")
    failures=0
    log_path="/tmp/slot-${slot_key}.log"
    runner_status_path="/tmp/pitcrew-slot-${slot_key}.exit"

    while [ ! -f "${slot_state_path}/drain" ]; do
        name="${PREFIX}-${tag}-$(date +%s)-$(rand_hex)"
        echo "[slot ${slot_key}] starting fresh ephemeral runner: ${name} -> ${repo:-<scope>}"
        : > "${log_path}"
        rm -f "${slot_state_path}/connected"
        rm -f "${slot_state_path}/job-active"
        rm -f "${slot_state_path}/container"
        write_slot_runtime_state \
            "${slot_state_path}" \
            "${OBSERVED_STATE_DIRTY}" \
            "starting" \
            "${name}" \
            "${failures}" \
            0 || true
        set -- docker run --rm \
            --label "${MANAGED_LABEL}" \
            --label "${SLOT_LABEL_KEY}=${slot_key}" \
            --name "${name}" \
            -e REPO_URL="${repo}" \
            -e ACCESS_TOKEN="${ACCESS_TOKEN:-}" \
            -e RUNNER_SCOPE="${RUNNER_SCOPE:-repo}" \
            -e ORG_NAME="${ORG_NAME:-}" \
            -e ENTERPRISE_NAME="${ENTERPRISE_NAME:-}" \
            -e RUNNER_NAME="${name}" \
            -e EPHEMERAL=1 \
            -e DISABLE_AUTO_UPDATE=1 \
            -e UNSET_CONFIG_VARS=false \
            -e DISABLE_AUTOMATIC_DEREGISTRATION=false \
            -e LABELS="${LABELS}"
        if [ -n "${RUNNER_MEMORY_LIMIT}" ]; then
            set -- "$@" --memory "${RUNNER_MEMORY_LIMIT}"
        fi
        if [ -n "${RUNNER_MEMORY_SWAP_LIMIT}" ]; then
            set -- "$@" --memory-swap "${RUNNER_MEMORY_SWAP_LIMIT}"
        fi
        if [ -n "${RUNNER_CPU_LIMIT}" ]; then
            set -- "$@" --cpus "${RUNNER_CPU_LIMIT}"
        fi
        if [ -n "${RUNNER_PIDS_LIMIT}" ]; then
            set -- "$@" --pids-limit "${RUNNER_PIDS_LIMIT}"
        fi
        if [ "${RUNNER_NO_DEFAULT_LABELS:-}" = "1" ]; then
            set -- "$@" -e NO_DEFAULT_LABELS=1
        fi
        if [ -n "${RUNNER_GROUP:-}" ]; then
            set -- "$@" -e RUNNER_GROUP="${RUNNER_GROUP}"
        fi
        set -- "$@" "${IMAGE}"
        rm -f "${runner_status_path}"
        # Record the container name so a cooperative drain can gracefully stop an
        # IDLE runner (no job-active marker) without touching a busy one.
        printf '%s\n' "${name}" > "${slot_state_path}/container"
        # The reader loop is the last stage of the pipe, so a plain pipeline would
        # report the loop's exit status and discard the container's. Persist the
        # container status from inside the pipe so a killed runner (137 / SIGKILL,
        # the OOM-kill signature) is distinguishable from a clean job exit.
        { "$@" 2>&1; printf '%s' "$?" > "${runner_status_path}"; } |
            while IFS= read -r output_line || [ -n "${output_line:-}" ]; do
                printf '%s\n' "${output_line}"
                printf '%s\n' "${output_line}" >> "${log_path}"
                case "${output_line}" in
                    *"${CONNECT_MARKER}"*)
                        if [ ! -f "${slot_state_path}/connected" ]; then
                            : > "${slot_state_path}/connected"
                            write_slot_runtime_state \
                                "${slot_state_path}" \
                                "${OBSERVED_STATE_DIRTY}" \
                                "online" \
                                "${name}" \
                                0 \
                                0 || true
                        fi
                        ;;
                    *"Running job:"*)
                        # The GitHub runner prints "Running job: <name>" the moment
                        # it picks up work. This is the ONLY reliable signal that a
                        # slot is truly busy — the supervisor process is always
                        # alive, so process/supervisor liveness must never be used
                        # as a job-busy proxy (that is the v6->v7 idle-detection bug
                        # issue #8's drain path tripped over). A drain must wait for
                        # this marker to clear, not for the supervisor to exit.
                        : > "${slot_state_path}/job-active"
                        [ -n "${OBSERVED_STATE_DIRTY}" ] && : > "${OBSERVED_STATE_DIRTY}"
                        ;;
                    *"completed with result"*)
                        # "Job <name> completed with result: <...>" — the ephemeral
                        # runner has finished its single job and is exiting.
                        rm -f "${slot_state_path}/job-active"
                        [ -n "${OBSERVED_STATE_DIRTY}" ] && : > "${OBSERVED_STATE_DIRTY}"
                        ;;
                esac
            done

        runner_exit_status=""
        if [ -f "${runner_status_path}" ]; then
            runner_exit_status=$(cat "${runner_status_path}" 2>/dev/null || printf '')
            rm -f "${runner_status_path}"
        fi
        # The container is gone, so no job can still be running on this slot. Clear
        # the busy marker unconditionally: a job-active flag must never outlive the
        # container it describes, or a drain would wait forever on a phantom job.
        rm -f "${slot_state_path}/job-active"
        rm -f "${slot_state_path}/container"
        # A missing, empty, or non-numeric capture means the container's real
        # disposition could not be observed. It MUST NOT be coerced to 0/clean:
        # doing so would mask a killed/lost runner as a graceful completion —
        # exactly the ambiguity this diagnostic exists to remove.
        runner_exit_class=$(classify_runner_exit "${runner_exit_status}")
        case "${runner_exit_class}" in
            unknown)
                echo "[slot ${slot_key}] runner ${name} exit status is UNKNOWN (capture missing/empty/corrupt: '${runner_exit_status}') — treating as ERROR, not a clean exit. The container's real disposition could not be observed; inspect the host for OOM-kills or a crashed supervisor." >&2
                ;;
            clean)
                echo "[slot ${slot_key}] runner ${name} exited cleanly (status 0) — job completed"
                ;;
            oom-kill)
                echo "[slot ${slot_key}] runner ${name} was KILLED (status 137 / SIGKILL) — likely host OOM-kill or 'docker kill'. Inspect host memory/CPU pressure and set RUNNER_MEMORY_LIMIT/RUNNER_CPU_LIMIT/RUNNER_PIDS_LIMIT to keep one job from starving the fleet." >&2
                ;;
            signal:*)
                echo "[slot ${slot_key}] runner ${name} terminated by signal ${runner_exit_class#signal:} (status ${runner_exit_status})" >&2
                ;;
            *)
                echo "[slot ${slot_key}] runner ${name} exited with status ${runner_exit_status}" >&2
                ;;
        esac

        if [ -f "${slot_state_path}/drain" ]; then
            echo "[slot ${slot_key}] current runner exited; drained slot will not respawn"
            break
        fi

        if grep -q "${CONNECT_MARKER}" "${log_path}" 2>/dev/null; then
            failures=0
            wait_seconds=1
            write_slot_runtime_state \
                "${slot_state_path}" \
                "${OBSERVED_STATE_DIRTY}" \
                "restarting" \
                "${name}" \
                0 \
                "${wait_seconds}" || true
        else
            failures=$((failures + 1))
            wait_seconds=$((failures * failures * 3))
            [ "${wait_seconds}" -gt "${MAX_BACKOFF}" ] && wait_seconds="${MAX_BACKOFF}"
            wait_seconds=$((wait_seconds + $(rand_jitter)))
            echo "[slot ${slot_key}] runner never reached '${CONNECT_MARKER}' (connect failure #${failures}) — backing off ${wait_seconds}s before retry."
            if [ "${failures}" -eq 1 ]; then
                echo "[slot ${slot_key}] Check host clock skew, available CPU and memory, and runner-administration token scope."
            fi
            write_slot_runtime_state \
                "${slot_state_path}" \
                "${OBSERVED_STATE_DIRTY}" \
                "backoff" \
                "${name}" \
                "${failures}" \
                "${wait_seconds}" || true
        fi
        rm -f "${log_path}"

        elapsed=0
        while [ "${elapsed}" -lt "${wait_seconds}" ] && [ ! -f "${slot_state_path}/drain" ]; do
            sleep 1
            elapsed=$((elapsed + 1))
        done
    done

    rm -f "${log_path}" "${runner_status_path}"
}

start_slot() {
    started_key="$1"
    started_repo="$2"
    started_tag="$3"
    started_path=$(slot_path "${started_key}")
    rm -rf "${started_path}"
    mkdir -p "${started_path}"
    printf '%s\n' "${started_repo}" > "${started_path}/repo"
    printf '%s\n' "${started_tag}" > "${started_path}/tag"
    write_slot_runtime_state \
        "${started_path}" \
        "${OBSERVED_STATE_DIRTY}" \
        "starting" \
        "" \
        0 \
        0 || true
    run_slot "${started_key}" "${started_repo}" "${started_tag}" &
    printf '%s\n' "$!" > "${started_path}/pid"
}

count_lines() {
    awk 'END { print NR + 0 }' "$1"
}

file_to_json_array() {
    jq -R -s 'split("\n") | map(select(length > 0))' "$1"
}

publish_pending_acknowledgement() {
    [ -f "${PENDING_ACKNOWLEDGEMENT}" ] || return 0
    acknowledgement_temporary="${STATE_DIRECTORY}/.acknowledged-capacity.$$.tmp"
    if ! cp "${PENDING_ACKNOWLEDGEMENT}" "${acknowledgement_temporary}"; then
        rm -f "${acknowledgement_temporary}"
        return 1
    fi
    if ! mv -f "${acknowledgement_temporary}" "${ACKNOWLEDGEMENT_PATH}"; then
        rm -f "${acknowledgement_temporary}"
        return 1
    fi
    rm -f "${PENDING_ACKNOWLEDGEMENT}"
}

write_acknowledgement() {
    desired_slots="$1"
    added_file="$2"
    draining_file="$3"
    unchanged_file="$4"
    added_slots=$(count_lines "${added_file}")
    draining_slots=$(count_lines "${draining_file}")
    unchanged_slots=$(count_lines "${unchanged_file}")
    added_keys=$(file_to_json_array "${added_file}")
    draining_keys=$(file_to_json_array "${draining_file}")
    unchanged_keys=$(file_to_json_array "${unchanged_file}")

    if ! jq -n \
        --argjson schemaVersion 1 \
        --arg status "accepted" \
        --argjson generation "${CURRENT_GENERATION}" \
        --argjson managerContractVersion "${MANAGER_CONTRACT_VERSION}" \
        --arg desiredStateHash "${CURRENT_STATE_HASH}" \
        --arg observedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --argjson desiredSlots "${desired_slots}" \
        --argjson addedSlots "${added_slots}" \
        --argjson drainingSlots "${draining_slots}" \
        --argjson unchangedSlots "${unchanged_slots}" \
        --argjson addedKeys "${added_keys}" \
        --argjson drainingKeys "${draining_keys}" \
        --argjson unchangedKeys "${unchanged_keys}" \
        '{
            schemaVersion: $schemaVersion,
            status: $status,
            generation: $generation,
            managerContractVersion: $managerContractVersion,
            desiredStateHash: $desiredStateHash,
            observedAt: $observedAt,
            desiredSlots: $desiredSlots,
            addedSlots: $addedSlots,
            drainingSlots: $drainingSlots,
            unchangedSlots: $unchangedSlots,
            addedKeys: $addedKeys,
            drainingKeys: $drainingKeys,
            unchangedKeys: $unchangedKeys
        }' > "${PENDING_ACKNOWLEDGEMENT}"; then
        rm -f "${PENDING_ACKNOWLEDGEMENT}"
        return 1
    fi
    publish_pending_acknowledgement
}

acknowledgement_matches_current() {
    [ -f "${ACKNOWLEDGEMENT_PATH}" ] || return 1
    jq -e \
        --argjson generation "${CURRENT_GENERATION}" \
        '
            .schemaVersion == 1
            and .status == "accepted"
            and .generation == $generation
        ' "${ACKNOWLEDGEMENT_PATH}" >/dev/null 2>&1
}

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

# >>> pitcrew:drain_protocol >>>
# Cooperative drain-and-fence (contract v7+). Host-side setup writes a
# drain-request marker before recreating the manager (for a static/limit change
# or a contract upgrade); the manager fences the pool so no NEW job can start,
# lets any IN-FLIGHT job finish on its own, and only then answers with a
# drain-complete marker. This is what lets a replacement wait for real GitHub
# jobs to end instead of force-killing them — the fleet-loss failure mode of
# issue #8. The whole cycle is recoverable: if the request disappears the
# manager resumes normal reconciliation and respawns the pool.
drain_requested() {
    [ -f "${DRAIN_REQUEST_PATH}" ] || return 1
    jq -e '.schemaVersion == 1 and (.nonce | type == "string" and length > 0)' \
        "${DRAIN_REQUEST_PATH}" >/dev/null 2>&1
}

fence_all_slots() {
    # Block new assignments: mark every slot draining so run_slot will not respawn
    # a fresh ephemeral runner once the current one exits.
    for fence_path in "${SLOT_DIRECTORY}"/*; do
        [ -d "${fence_path}" ] || continue
        if [ ! -f "${fence_path}/drain" ]; then
            : > "${fence_path}/drain"
            mark_observed_state_dirty
        fi
    done
}

stop_idle_slot_containers() {
    # Gracefully stop ONLY idle runners (no job-active marker) so their fenced
    # supervisors can exit. A busy runner is never touched: its job finishes
    # naturally, the ephemeral container exits, and the fenced slot then stops
    # without respawning. This is the "wait for the job, kill nothing" guarantee.
    idle_pids=""
    for idle_path in "${SLOT_DIRECTORY}"/*; do
        [ -d "${idle_path}" ] || continue
        [ -f "${idle_path}/job-active" ] && continue
        [ -f "${idle_path}/container" ] || continue
        idle_container=$(cat "${idle_path}/container" 2>/dev/null || printf '')
        [ -n "${idle_container}" ] || continue
        docker stop --timeout "${RUNNER_STOP_TIMEOUT}" "${idle_container}" \
            >/dev/null 2>&1 &
        idle_pids="${idle_pids} $!"
    done
    [ -n "${idle_pids}" ] && wait_for_cleanup_commands "${idle_pids}" || true
}

drain_is_complete() {
    # Complete only when no supervisor is alive AND no job is running, so a
    # replacement can proceed knowing nothing is left to interrupt.
    for check_path in "${SLOT_DIRECTORY}"/*; do
        [ -d "${check_path}" ] || continue
        if [ -f "${check_path}/pid" ]; then
            check_pid=$(cat "${check_path}/pid")
            if kill -0 "${check_pid}" 2>/dev/null; then
                return 1
            fi
        fi
        [ -f "${check_path}/job-active" ] && return 1
    done
    return 0
}

write_drain_complete() {
    drain_nonce=$(jq -r '.nonce // ""' "${DRAIN_REQUEST_PATH}" 2>/dev/null || printf '')
    [ -n "${drain_nonce}" ] || return 1
    drain_complete_temporary="${STATE_DIRECTORY}/.drain-complete.$$.tmp"
    if ! jq -n \
        --argjson schemaVersion 1 \
        --arg nonce "${drain_nonce}" \
        --argjson managerContractVersion "${MANAGER_CONTRACT_VERSION}" \
        --arg completedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{
            schemaVersion: $schemaVersion,
            nonce: $nonce,
            managerContractVersion: $managerContractVersion,
            completedAt: $completedAt
        }' > "${drain_complete_temporary}"; then
        rm -f "${drain_complete_temporary}"
        return 1
    fi
    if ! mv -f "${drain_complete_temporary}" "${DRAIN_COMPLETE_PATH}"; then
        rm -f "${drain_complete_temporary}"
        return 1
    fi
}

run_drain_cycle() {
    fence_all_slots
    stop_idle_slot_containers
    if drain_is_complete; then
        write_drain_complete || true
    fi
}
# <<< pitcrew:drain_protocol <<<

persist_accepted_state() {
    source_path="$1"
    accepted_temporary="${STATE_DIRECTORY}/.last-valid-capacity.$$.tmp"
    if ! cp "${source_path}" "${accepted_temporary}"; then
        rm -f "${accepted_temporary}"
        return 1
    fi
    if ! mv -f "${accepted_temporary}" "${ACCEPTED_STATE_PATH}"; then
        rm -f "${accepted_temporary}"
        return 1
    fi
}

bootstrap_legacy_desired_state() {
    if [ -f "${DESIRED_STATE_PATH}" ] || [ -f "${ACCEPTED_STATE_PATH}" ]; then
        return
    fi

    legacy_temporary="${STATE_DIRECTORY}/.legacy-desired-capacity.$$.tmp"
    legacy_repositories="${REPO_URLS:-${REPO_URL:-}}"
    if ! write_legacy_desired_state \
        "${legacy_temporary}" \
        "${RUNNER_SCOPE:-repo}" \
        "${legacy_repositories}" \
        "${RUNNER_REPLICAS:-1}"; then
        rm -f "${legacy_temporary}"
        echo "[manager:${PROFILE_ID}] no valid desired state or legacy capacity configuration was found" >&2
        return
    fi
    if ! mv -f "${legacy_temporary}" "${DESIRED_STATE_PATH}"; then
        rm -f "${legacy_temporary}"
        echo "[manager:${PROFILE_ID}] legacy capacity could not be published as desired state" >&2
        return
    fi
    echo "[manager:${PROFILE_ID}] imported legacy environment capacity as desired generation 1"
}

load_accepted_state() {
    if [ ! -f "${ACCEPTED_STATE_PATH}" ]; then
        return
    fi
    if ! desired_state_is_valid "${ACCEPTED_STATE_PATH}"; then
        echo "[manager:${PROFILE_ID}] persisted last-valid capacity is invalid; waiting for valid desired state" >&2
        return
    fi

    restored_slots="${CURRENT_DESIRED_SLOTS}.restored"
    if ! render_desired_slots "${ACCEPTED_STATE_PATH}" "${restored_slots}"; then
        rm -f "${restored_slots}"
        echo "[manager:${PROFILE_ID}] could not render persisted capacity; waiting for valid desired state" >&2
        return
    fi
    if ! mv -f "${restored_slots}" "${CURRENT_DESIRED_SLOTS}"; then
        rm -f "${restored_slots}"
        echo "[manager:${PROFILE_ID}] could not activate persisted capacity; waiting for valid desired state" >&2
        return
    fi
    CURRENT_GENERATION=$(desired_state_generation "${ACCEPTED_STATE_PATH}")
    CURRENT_STATE_HASH=$(desired_state_hash "${ACCEPTED_STATE_PATH}")
    echo "[manager:${PROFILE_ID}] restored desired-capacity generation ${CURRENT_GENERATION}"
}

process_desired_state() {
    if [ ! -f "${DESIRED_STATE_PATH}" ]; then
        LAST_DESIRED_DOCUMENT_HASH=""
        if [ -n "${LAST_REJECTION}" ]; then
            LAST_REJECTION=""
            mark_observed_state_dirty
        fi
        return
    fi
    observed_document_hash=$(sha256sum "${DESIRED_STATE_PATH}" 2>/dev/null | awk '{ print $1 }')
    [ -n "${observed_document_hash}" ] || return
    if [ "${observed_document_hash}" = "${LAST_DESIRED_DOCUMENT_HASH}" ]; then
        return
    fi
    state_snapshot="/tmp/pitcrew-desired-capacity-snapshot.json"
    if ! cp "${DESIRED_STATE_PATH}" "${state_snapshot}"; then
        rm -f "${state_snapshot}"
        echo "[manager:${PROFILE_ID}] could not snapshot desired-capacity state; retaining generation ${CURRENT_GENERATION}" >&2
        return
    fi
    classification=$(classify_desired_state \
        "${state_snapshot}" \
        "${CURRENT_GENERATION}" \
        "${CURRENT_STATE_HASH}")
    snapshot_document_hash=$(sha256sum "${state_snapshot}" 2>/dev/null | awk '{ print $1 }')

    case "${classification}" in
        new)
            candidate_slots="${CURRENT_DESIRED_SLOTS}.$$"
            if ! render_desired_slots "${state_snapshot}" "${candidate_slots}"; then
                rm -f "${candidate_slots}" "${state_snapshot}"
                echo "[manager:${PROFILE_ID}] could not render desired-capacity state; retaining generation ${CURRENT_GENERATION}" >&2
                return
            fi
            candidate_generation=$(desired_state_generation "${state_snapshot}")
            candidate_hash=$(desired_state_hash "${state_snapshot}")
            if ! persist_accepted_state "${state_snapshot}"; then
                rm -f "${candidate_slots}" "${state_snapshot}"
                echo "[manager:${PROFILE_ID}] could not persist desired-capacity state; retaining generation ${CURRENT_GENERATION}" >&2
                return
            fi
            if ! mv -f "${candidate_slots}" "${CURRENT_DESIRED_SLOTS}"; then
                rm -f "${candidate_slots}" "${state_snapshot}"
                echo "[manager:${PROFILE_ID}] could not activate desired-capacity state; retaining generation ${CURRENT_GENERATION}" >&2
                return
            fi
            CURRENT_GENERATION="${candidate_generation}"
            CURRENT_STATE_HASH="${candidate_hash}"
            mark_observed_state_dirty

            added_file="/tmp/pitcrew-added.$$"
            draining_file="/tmp/pitcrew-draining.$$"
            unchanged_file="/tmp/pitcrew-unchanged.$$"
            reconcile_slots \
                "${CURRENT_DESIRED_SLOTS}" \
                "${added_file}" \
                "${draining_file}" \
                "${unchanged_file}"
            desired_count=$(count_lines "${CURRENT_DESIRED_SLOTS}")
            if ! write_acknowledgement \
                "${desired_count}" \
                "${added_file}" \
                "${draining_file}" \
                "${unchanged_file}"; then
                echo "[manager:${PROFILE_ID}] generation ${CURRENT_GENERATION} was applied but acknowledgement could not be written" >&2
            fi
            echo "[manager:${PROFILE_ID}] accepted generation ${CURRENT_GENERATION}: $(count_lines "${added_file}") added, $(count_lines "${draining_file}") draining, $(count_lines "${unchanged_file}") unchanged"
            rm -f "${added_file}" "${draining_file}" "${unchanged_file}"
            LAST_REJECTION=""
            LAST_DESIRED_DOCUMENT_HASH="${snapshot_document_hash}"
            ;;
        unchanged)
            if [ -n "${LAST_REJECTION}" ]; then
                LAST_REJECTION=""
                mark_observed_state_dirty
            fi
            LAST_DESIRED_DOCUMENT_HASH="${snapshot_document_hash}"
            ;;
        invalid|stale|conflict)
            rejection="${classification}:${snapshot_document_hash:-unreadable}"
            if [ "${rejection}" != "${LAST_REJECTION}" ]; then
                echo "[manager:${PROFILE_ID}] rejected ${classification} desired-capacity state; retaining generation ${CURRENT_GENERATION}" >&2
                LAST_REJECTION="${rejection}"
                mark_observed_state_dirty
            fi
            LAST_DESIRED_DOCUMENT_HASH="${snapshot_document_hash}"
            ;;
    esac
    rm -f "${state_snapshot}"
}

mkdir -p "${STATE_DIRECTORY}"
# Docker creates a missing bind source as root. This directory contains only
# non-secret reconciliation state and must remain replaceable by host-side setup.
if [ "$(stat -c '%u' "${STATE_DIRECTORY}")" = "0" ]; then
    chmod 0777 "${STATE_DIRECTORY}"
fi
rm -rf "${SLOT_DIRECTORY}"
mkdir -p "${SLOT_DIRECTORY}"
: > "${CURRENT_DESIRED_SLOTS}"
rm -f "${OBSERVED_STATE_DIRTY}"
# Drop any drain markers left by a previous manager life. A freshly (re)created
# manager must start reconciling normally, not immediately re-enter the drain
# that setup requested against the manager it just replaced.
rm -f "${DRAIN_REQUEST_PATH}" "${DRAIN_COMPLETE_PATH}"
mark_observed_state_dirty

echo "[manager:${PROFILE_ID}] clearing any leftover managed runners"
if ! stop_managed_gracefully; then
    echo "[manager:${PROFILE_ID}] one or more leftover runners did not stop gracefully; forcing cleanup" >&2
fi
remove_managed

if [ "${RUNNER_PULL_IMAGE:-1}" = "1" ]; then
    echo "[manager:${PROFILE_ID}] pre-pulling runner image ${IMAGE}"
    docker pull "${IMAGE}" >/dev/null 2>&1 ||
        echo "[manager:${PROFILE_ID}] pull failed; relying on the local image"
else
    echo "[manager:${PROFILE_ID}] using locally prepared runner image ${IMAGE}"
fi

bootstrap_legacy_desired_state
load_accepted_state
if [ "${CURRENT_GENERATION}" -gt 0 ]; then
    startup_added="/tmp/pitcrew-startup-added.$$"
    startup_draining="/tmp/pitcrew-startup-draining.$$"
    startup_unchanged="/tmp/pitcrew-startup-unchanged.$$"
    reconcile_slots \
        "${CURRENT_DESIRED_SLOTS}" \
        "${startup_added}" \
        "${startup_draining}" \
        "${startup_unchanged}"
    if ! acknowledgement_matches_current; then
        write_acknowledgement \
            "$(count_lines "${CURRENT_DESIRED_SLOTS}")" \
            "${startup_added}" \
            "${startup_draining}" \
            "${startup_unchanged}" ||
            echo "[manager:${PROFILE_ID}] restored generation ${CURRENT_GENERATION} but acknowledgement could not be repaired" >&2
    fi
    rm -f "${startup_added}" "${startup_draining}" "${startup_unchanged}"
fi
MANAGER_STATUS="running"
mark_observed_state_dirty
publish_observed_state 1

while [ "${STOPPING}" -eq 0 ]; do
    if drain_requested; then
        if [ "${DRAINING}" -eq 0 ]; then
            DRAINING=1
            rm -f "${DRAIN_COMPLETE_PATH}"
            echo "[manager:${PROFILE_ID}] drain requested; fencing new assignments and waiting for in-flight jobs to finish before any replacement"
        fi
        # While draining, skip reconcile entirely: reconcile clears slot drains
        # and respawns runners, which would defeat the fence and let a new job
        # start in the very window setup is trying to keep empty.
        run_drain_cycle
        publish_observed_state 0
        sleep "${RECONCILE_INTERVAL}"
        continue
    fi
    if [ "${DRAINING}" -eq 1 ]; then
        DRAINING=0
        rm -f "${DRAIN_COMPLETE_PATH}"
        echo "[manager:${PROFILE_ID}] drain request cleared; resuming reconciliation"
    fi
    process_desired_state
    if [ -f "${PENDING_ACKNOWLEDGEMENT}" ]; then
        publish_pending_acknowledgement || true
    fi
    if [ "${CURRENT_GENERATION}" -gt 0 ]; then
        periodic_added="/tmp/pitcrew-periodic-added.$$"
        periodic_draining="/tmp/pitcrew-periodic-draining.$$"
        periodic_unchanged="/tmp/pitcrew-periodic-unchanged.$$"
        reconcile_slots \
            "${CURRENT_DESIRED_SLOTS}" \
            "${periodic_added}" \
            "${periodic_draining}" \
            "${periodic_unchanged}"
        if [ ! -f "${PENDING_ACKNOWLEDGEMENT}" ] &&
            ! acknowledgement_matches_current; then
            write_acknowledgement \
                "$(count_lines "${CURRENT_DESIRED_SLOTS}")" \
                "${periodic_added}" \
                "${periodic_draining}" \
                "${periodic_unchanged}" || true
        fi
        rm -f "${periodic_added}" "${periodic_draining}" "${periodic_unchanged}"
    fi
    publish_observed_state 0
    sleep "${RECONCILE_INTERVAL}"
done
