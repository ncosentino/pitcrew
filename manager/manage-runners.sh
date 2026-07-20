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
RECONCILE_INTERVAL="${PITCREW_RECONCILE_INTERVAL:-1}"
OBSERVED_STATE_INTERVAL="${PITCREW_OBSERVED_STATE_INTERVAL:-30}"
RESOURCE_TELEMETRY_PATH="/tmp/pitcrew-resource-telemetry.json"
RESOURCE_TELEMETRY_COMMAND_TIMEOUT=3
SLOT_DIRECTORY="/tmp/pitcrew-slots"
CURRENT_DESIRED_SLOTS="/tmp/pitcrew-current-desired-slots.tsv"
PENDING_ACKNOWLEDGEMENT="/tmp/pitcrew-pending-acknowledgement.json"
OBSERVED_STATE_DIRTY="/tmp/pitcrew-observed-state-dirty"
MANAGED_LABEL_KEY="ephemeral-managed-runner-profile"
MANAGED_LABEL="${MANAGED_LABEL_KEY}=${PROFILE_ID}"
MANAGER_LABEL="ephemeral-runner-manager-profile=${PROFILE_ID}"
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

CONNECT_MARKER="Listening for Jobs"
MAX_BACKOFF="${RUNNER_MAX_BACKOFF:-120}"
RUNNER_STOP_TIMEOUT=20
SUPERVISOR_STOP_TIMEOUT=5
CURRENT_GENERATION=0
CURRENT_STATE_HASH=""
LAST_DESIRED_DOCUMENT_HASH=""
LAST_REJECTION=""
STOPPING=0
MANAGER_STATUS="starting"
LAST_OBSERVED_STATE_PUBLISH_EPOCH=0
LAST_RESOURCE_TELEMETRY_SAMPLE_EPOCH=0
LAST_RESOURCE_TELEMETRY_STATUS=""
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

report_resource_telemetry_status() {
    resource_status="$1"
    [ "${resource_status}" = "${LAST_RESOURCE_TELEMETRY_STATUS}" ] && return
    if [ "${resource_status}" = "available" ]; then
        if [ -n "${LAST_RESOURCE_TELEMETRY_STATUS}" ]; then
            echo "[manager:${PROFILE_ID}] resource telemetry is available"
        fi
    else
        echo "[manager:${PROFILE_ID}] resource telemetry is ${resource_status}" >&2
    fi
    LAST_RESOURCE_TELEMETRY_STATUS="${resource_status}"
}

publish_observed_state() {
    force="${1:-0}"
    observed_now=$(date +%s)
    if [ "${force}" != "1" ] &&
        [ ! -f "${OBSERVED_STATE_DIRTY}" ] &&
        [ $((observed_now - LAST_OBSERVED_STATE_PUBLISH_EPOCH)) -lt "${OBSERVED_STATE_INTERVAL}" ] &&
        [ -f "${RESOURCE_TELEMETRY_PATH}" ] &&
        [ $((observed_now - LAST_RESOURCE_TELEMETRY_SAMPLE_EPOCH)) -lt "${OBSERVED_STATE_INTERVAL}" ]; then
        return
    fi

    rm -f "${OBSERVED_STATE_DIRTY}"
    resource_now=$(date +%s)
    if [ "${STOPPING}" -eq 1 ]; then
        if [ ! -f "${RESOURCE_TELEMETRY_PATH}" ]; then
            if ! write_unavailable_resource_telemetry "${RESOURCE_TELEMETRY_PATH}"; then
                mark_observed_state_dirty
                echo "[manager:${PROFILE_ID}] could not write shutdown resource telemetry" >&2
                return
            fi
            report_resource_telemetry_status "unavailable"
        fi
    elif [ ! -f "${RESOURCE_TELEMETRY_PATH}" ] ||
        [ $((resource_now - LAST_RESOURCE_TELEMETRY_SAMPLE_EPOCH)) -ge "${OBSERVED_STATE_INTERVAL}" ]; then
        if collect_resource_telemetry \
            "${RESOURCE_TELEMETRY_PATH}" \
            "${MANAGED_LABEL}" \
            "${MANAGER_LABEL}" \
            "${SLOT_LABEL_KEY}" \
            "${RESOURCE_TELEMETRY_COMMAND_TIMEOUT}"; then
            LAST_RESOURCE_TELEMETRY_SAMPLE_EPOCH="${resource_now}"
            resource_status=$(jq -r '.status' "${RESOURCE_TELEMETRY_PATH}")
            report_resource_telemetry_status "${resource_status}"
        else
            if ! write_unavailable_resource_telemetry "${RESOURCE_TELEMETRY_PATH}"; then
                mark_observed_state_dirty
                echo "[manager:${PROFILE_ID}] could not write unavailable resource telemetry" >&2
                return
            fi
            LAST_RESOURCE_TELEMETRY_SAMPLE_EPOCH="${resource_now}"
            report_resource_telemetry_status "unavailable"
        fi
    fi

    observed_slots_path="/tmp/pitcrew-observed-slots.json"
    if ! render_observed_slots \
        "${SLOT_DIRECTORY}" \
        "${observed_slots_path}" \
        "${RESOURCE_TELEMETRY_PATH}"; then
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
        "${observed_slots_path}" \
        "${RESOURCE_TELEMETRY_PATH}"; then
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

    while [ ! -f "${slot_state_path}/drain" ]; do
        name="${PREFIX}-${tag}-$(date +%s)-$(rand_hex)"
        echo "[slot ${slot_key}] starting fresh ephemeral runner: ${name} -> ${repo:-<scope>}"
        : > "${log_path}"
        rm -f "${slot_state_path}/connected"
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
        if [ "${RUNNER_NO_DEFAULT_LABELS:-}" = "1" ]; then
            set -- "$@" -e NO_DEFAULT_LABELS=1
        fi
        if [ -n "${RUNNER_GROUP:-}" ]; then
            set -- "$@" -e RUNNER_GROUP="${RUNNER_GROUP}"
        fi
        set -- "$@" "${IMAGE}"
        "$@" 2>&1 |
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
                esac
            done

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

    rm -f "${log_path}"
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
rm -f "${OBSERVED_STATE_DIRTY}" "${RESOURCE_TELEMETRY_PATH}"
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
