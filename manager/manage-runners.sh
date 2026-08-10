#!/bin/sh
# Reconciles truly-ephemeral GitHub Actions runner slots from mounted desired
# state. Each slot owns one foreground `docker run --rm`; after that runner exits,
# a desired slot launches a clean replacement while a draining slot stops.
set -u

SCRIPT_DIRECTORY=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "${SCRIPT_DIRECTORY}/reconciliation.sh"
. "${SCRIPT_DIRECTORY}/observability.sh"
. "${SCRIPT_DIRECTORY}/registration.sh"
. "${SCRIPT_DIRECTORY}/diagnostics.sh"
. "${SCRIPT_DIRECTORY}/host-admission.sh"

MANAGER_CONTRACT_VERSION=18
EXPECTED_CONTRACT_VERSION="${PITCREW_MANAGER_CONTRACT_VERSION:-18}"
if [ "${EXPECTED_CONTRACT_VERSION}" != "${MANAGER_CONTRACT_VERSION}" ]; then
    echo "[manager] contract mismatch: setup expects ${EXPECTED_CONTRACT_VERSION}, manager provides ${MANAGER_CONTRACT_VERSION}" >&2
    exit 1
fi

PREFIX="${RUNNER_NAME_PREFIX:-runner}"
IMAGE="${RUNNER_IMAGE:-myoung34/github-runner:ubuntu-noble}"
WORKER_REVISION="${PITCREW_WORKER_REVISION:-}"
WORKER_IMAGE_ID="${PITCREW_WORKER_IMAGE_ID:-}"
WORKER_MEMORY_BYTES="${PITCREW_WORKER_MEMORY_BYTES:-}"
WORKER_MEMORY_SWAP_BYTES="${PITCREW_WORKER_MEMORY_SWAP_BYTES:-}"
WORKER_CPU_CORES="${PITCREW_WORKER_CPU_CORES:-}"
WORKER_PIDS_LIMIT="${PITCREW_WORKER_PIDS_LIMIT:-}"
READ_ONLY_VOLUMES="${PITCREW_READ_ONLY_VOLUMES:-}"
SERVICE_NETWORK="${PITCREW_SERVICE_NETWORK:-}"
ASSUME_UNVERSIONED_CURRENT="${PITCREW_ASSUME_UNVERSIONED_CURRENT:-0}"
PROFILE_ID="${RUNNER_PROFILE_ID:-default}"
STATE_DIRECTORY="${PITCREW_STATE_DIRECTORY:-/var/lib/pitcrew}"
PITCREW_HOST_ADMISSION_RELEASE_DIRECTORY="${STATE_DIRECTORY}/host-admission-releases"
PITCREW_HOST_ADMISSION_ADOPTION_DIRECTORY="${STATE_DIRECTORY}/host-admission-adoptions"
export \
    PITCREW_HOST_ADMISSION_RELEASE_DIRECTORY \
    PITCREW_HOST_ADMISSION_ADOPTION_DIRECTORY
DESIRED_STATE_PATH="${STATE_DIRECTORY}/desired-capacity.json"
ACCEPTED_STATE_PATH="${STATE_DIRECTORY}/last-valid-capacity.json"
ACKNOWLEDGEMENT_PATH="${STATE_DIRECTORY}/acknowledged-capacity.json"
OBSERVED_STATE_PATH="${STATE_DIRECTORY}/observed-state.json"
DIAGNOSTICS_DIRECTORY="${STATE_DIRECTORY}/diagnostics"
SHUTDOWN_REQUEST_PATH="${STATE_DIRECTORY}/manager-shutdown.json"
RECONCILE_INTERVAL="${PITCREW_RECONCILE_INTERVAL:-1}"
OBSERVED_STATE_INTERVAL="${PITCREW_OBSERVED_STATE_INTERVAL:-30}"
RESOURCE_TELEMETRY_PATH="/tmp/pitcrew-resource-telemetry.json"
RESOURCE_POLICY_PATH="/tmp/pitcrew-resource-policy.json"
HOST_HARDWARE_PATH="${STATE_DIRECTORY}/host-hardware.json"
HOST_HARDWARE_FALLBACK_PATH="/tmp/pitcrew-host-hardware.json"
RESOURCE_TELEMETRY_COMMAND_TIMEOUT=3
HOST_HARDWARE_INTERVAL=300
EXIT_EVIDENCE_EVENT_GRACE_SECONDS=2
EXIT_EVIDENCE_COMMAND_TIMEOUT=5
REGISTRATION_RECONCILE_INTERVAL="${PITCREW_REGISTRATION_RECONCILE_INTERVAL:-60}"
REGISTRATION_CLEANUP_THRESHOLD="${PITCREW_REGISTRATION_CLEANUP_THRESHOLD:-2}"
REGISTRATION_GRACE_SECONDS="${PITCREW_REGISTRATION_GRACE_SECONDS:-90}"
REGISTRATION_API_TIMEOUT=5
REGISTRATION_INVENTORY_DIRECTORY="/tmp/pitcrew-registration-inventory"
SLOT_DIRECTORY="/tmp/pitcrew-slots"
CURRENT_DESIRED_SLOTS="/tmp/pitcrew-current-desired-slots.tsv"
PENDING_ACKNOWLEDGEMENT="/tmp/pitcrew-pending-acknowledgement.json"
OBSERVED_STATE_DIRTY="/tmp/pitcrew-observed-state-dirty"
MANAGED_LABEL_KEY="ephemeral-managed-runner-profile"
MANAGED_LABEL="${MANAGED_LABEL_KEY}=${PROFILE_ID}"
MANAGER_LABEL="ephemeral-runner-manager-profile=${PROFILE_ID}"
SLOT_LABEL_KEY="ephemeral-managed-runner-slot"
WORKER_REVISION_LABEL_KEY="pitcrew-worker-revision"
HOST_ADMISSION_NAMESPACE_LABEL_KEY="pitcrew-host-admission-namespace"
HOST_ADMISSION_PROFILE_LABEL_KEY="pitcrew-host-admission-profile"
HOST_ADMISSION_SLOT_LABEL_KEY="pitcrew-host-admission-slot"

read_only_volumes_are_valid() (
    configured_volumes="$1"
    [ -z "${configured_volumes}" ] && exit 0
    IFS=','
    volume_count=0
    seen_names=","
    seen_sources=","
    for configured_volume in ${configured_volumes}; do
        volume_count=$((volume_count + 1))
        [ "${volume_count}" -le 8 ] || exit 1
        case "${configured_volume}" in
            *=*) ;;
            *) exit 1 ;;
        esac
        volume_name=${configured_volume%%=*}
        volume_source=${configured_volume#*=}
        printf '%s' "${volume_name}" |
            grep -Eq '^[a-z][a-z0-9-]{0,31}$' || exit 1
        printf '%s' "${volume_source}" |
            grep -Eq '^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$' || exit 1
        case "${seen_names}" in
            *,"${volume_name}",*) exit 1 ;;
        esac
        case "${seen_sources}" in
            *,"${volume_source}",*) exit 1 ;;
        esac
        seen_names="${seen_names}${volume_name},"
        seen_sources="${seen_sources}${volume_source},"
    done
)

verify_read_only_volumes() (
    configured_volumes="$1"
    [ -z "${configured_volumes}" ] && exit 0
    IFS=','
    for configured_volume in ${configured_volumes}; do
        volume_source=${configured_volume#*=}
        inspected_name=$(
            docker volume inspect \
                --format '{{.Name}}' \
                "${volume_source}" 2>/dev/null
        ) || exit 1
        [ "${inspected_name}" = "${volume_source}" ] || exit 1
    done
)

service_network_is_valid() {
    configured_network="$1"
    [ -z "${configured_network}" ] && return 0
    printf '%s' "${configured_network}" |
        grep -Eq '^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$' || return 1
    [ "${configured_network}" != "bridge" ] || return 1
    ! printf '%s' "${configured_network}" |
        grep -Eq '^self-hosted-runner(-[a-z][a-z0-9-]{0,31})?_default$'
}

verify_service_network() {
    configured_network="$1"
    [ -z "${configured_network}" ] && return 0
    inspected_network=$(
        docker network inspect \
            --format '{{.Name}}|{{.Driver}}|{{.Scope}}|{{.Internal}}' \
            "${configured_network}" 2>/dev/null
    ) || return 1
    [ "${inspected_network}" = "${configured_network}|bridge|local|false" ]
}

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
case "${REGISTRATION_RECONCILE_INTERVAL}" in
    ''|*[!0-9]*|0)
        echo "[manager:${PROFILE_ID}] PITCREW_REGISTRATION_RECONCILE_INTERVAL must be a positive integer." >&2
        exit 1
        ;;
esac
case "${REGISTRATION_CLEANUP_THRESHOLD}" in
    ''|*[!0-9]*|0)
        echo "[manager:${PROFILE_ID}] PITCREW_REGISTRATION_CLEANUP_THRESHOLD must be a positive integer." >&2
        exit 1
        ;;
esac
case "${REGISTRATION_GRACE_SECONDS}" in
    ''|*[!0-9]*)
        echo "[manager:${PROFILE_ID}] PITCREW_REGISTRATION_GRACE_SECONDS must be a nonnegative integer." >&2
        exit 1
        ;;
esac
case "${WORKER_REVISION}" in
    ''|*[!0-9a-f]*)
        echo "[manager:${PROFILE_ID}] PITCREW_WORKER_REVISION must be a lowercase SHA-256 digest." >&2
        exit 1
        ;;
esac
[ "${#WORKER_REVISION}" -eq 64 ] || {
    echo "[manager:${PROFILE_ID}] PITCREW_WORKER_REVISION must be a lowercase SHA-256 digest." >&2
    exit 1
}
if ! host_admission_configuration_is_valid; then
    echo "[manager:${PROFILE_ID}] host-admission environment is incomplete or invalid." >&2
    exit 1
fi
case "${ASSUME_UNVERSIONED_CURRENT}" in
    0|1) ;;
    *)
        echo "[manager:${PROFILE_ID}] PITCREW_ASSUME_UNVERSIONED_CURRENT must be 0 or 1." >&2
        exit 1
        ;;
esac
if [ -n "${WORKER_IMAGE_ID}" ] &&
    ! printf '%s' "${WORKER_IMAGE_ID}" | grep -Eq '^sha256:[0-9a-f]{64}$'; then
    echo "[manager:${PROFILE_ID}] PITCREW_WORKER_IMAGE_ID must be a local sha256 image identity." >&2
    exit 1
fi
if ! worker_resource_policy_is_valid \
    "${WORKER_MEMORY_BYTES}" \
    "${WORKER_MEMORY_SWAP_BYTES}" \
    "${WORKER_CPU_CORES}" \
    "${WORKER_PIDS_LIMIT}"; then
    echo "[manager:${PROFILE_ID}] worker resource policy is invalid; refusing to launch unlimited workers." >&2
    exit 1
fi
if ! read_only_volumes_are_valid "${READ_ONLY_VOLUMES}"; then
    echo "[manager:${PROFILE_ID}] PITCREW_READ_ONLY_VOLUMES is invalid." >&2
    exit 1
fi
if ! verify_read_only_volumes "${READ_ONLY_VOLUMES}"; then
    echo "[manager:${PROFILE_ID}] a required external read-only volume is unavailable." >&2
    exit 1
fi
if ! service_network_is_valid "${SERVICE_NETWORK}"; then
    echo "[manager:${PROFILE_ID}] PITCREW_SERVICE_NETWORK is invalid or identifies a reserved Docker or manager network." >&2
    exit 1
fi
if ! verify_service_network "${SERVICE_NETWORK}"; then
    echo "[manager:${PROFILE_ID}] the required external service network is unavailable or incompatible." >&2
    exit 1
fi
WORKER_RESOURCE_ARGUMENTS=$(render_worker_resource_arguments \
    "${WORKER_MEMORY_BYTES}" \
    "${WORKER_MEMORY_SWAP_BYTES}" \
    "${WORKER_CPU_CORES}" \
    "${WORKER_PIDS_LIMIT}") || {
    echo "[manager:${PROFILE_ID}] worker resource policy could not be rendered." >&2
    exit 1
}

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
LAST_HOST_HARDWARE_SAMPLE_EPOCH=0
LAST_REGISTRATION_RECONCILE_EPOCH=0
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

# Diagnostic writes are best effort. A failed journal or health write never
# stops, drains, or tears down a worker.
record_manager_diagnostic() {
    record_manager_event \
        "${DIAGNOSTICS_DIRECTORY}" \
        "${MANAGER_INSTANCE_ID}" \
        "$@" || true
    return 0
}

elapsed_milliseconds() {
    printf '%s' "$(( ($(date +%s) - $1) * 1000 ))"
}

diagnostic_retry_timestamp() {
    date -u -d "@$(( $(date +%s) + $1 ))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ||
        date -u +%Y-%m-%dT%H:%M:%SZ
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
    observed_hardware_path="${HOST_HARDWARE_PATH}"
    if [ "${force}" != "1" ] &&
        [ ! -f "${OBSERVED_STATE_DIRTY}" ] &&
        [ $((observed_now - LAST_OBSERVED_STATE_PUBLISH_EPOCH)) -lt "${OBSERVED_STATE_INTERVAL}" ] &&
        [ -f "${RESOURCE_TELEMETRY_PATH}" ] &&
        [ $((observed_now - LAST_RESOURCE_TELEMETRY_SAMPLE_EPOCH)) -lt "${OBSERVED_STATE_INTERVAL}" ] &&
        [ -f "${HOST_HARDWARE_PATH}" ] &&
        [ $((observed_now - LAST_HOST_HARDWARE_SAMPLE_EPOCH)) -lt "${HOST_HARDWARE_INTERVAL}" ]; then
        return
    fi
    if [ "${STOPPING}" -eq 0 ] &&
        (
            [ ! -f "${HOST_HARDWARE_PATH}" ] ||
            [ $((observed_now - LAST_HOST_HARDWARE_SAMPLE_EPOCH)) -ge "${HOST_HARDWARE_INTERVAL}" ]
        ); then
        if ! collect_host_hardware \
            "${HOST_HARDWARE_PATH}" \
            "${RESOURCE_TELEMETRY_COMMAND_TIMEOUT}"; then
            echo "[manager:${PROFILE_ID}] could not collect host hardware inventory" >&2
            if ! write_stale_or_unavailable_host_hardware \
                "${HOST_HARDWARE_PATH}" \
                "${HOST_HARDWARE_FALLBACK_PATH}"; then
                mark_observed_state_dirty
                echo "[manager:${PROFILE_ID}] could not render fallback host hardware inventory" >&2
                return
            fi
            observed_hardware_path="${HOST_HARDWARE_FALLBACK_PATH}"
        fi
        LAST_HOST_HARDWARE_SAMPLE_EPOCH="${observed_now}"
    elif [ ! -f "${HOST_HARDWARE_PATH}" ]; then
        if ! write_unavailable_host_hardware "${HOST_HARDWARE_PATH}"; then
            if ! write_unavailable_host_hardware "${HOST_HARDWARE_FALLBACK_PATH}"; then
                mark_observed_state_dirty
                echo "[manager:${PROFILE_ID}] could not render unavailable host hardware inventory" >&2
                return
            fi
            observed_hardware_path="${HOST_HARDWARE_FALLBACK_PATH}"
        fi
    fi
    rm -f "${OBSERVED_STATE_DIRTY}"
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
        telemetry_started_epoch=$(date +%s)
        if collect_resource_telemetry \
            "${RESOURCE_TELEMETRY_PATH}" \
            "${MANAGED_LABEL}" \
            "${MANAGER_LABEL}" \
            "${SLOT_LABEL_KEY}" \
            "${RESOURCE_TELEMETRY_COMMAND_TIMEOUT}"; then
            LAST_RESOURCE_TELEMETRY_SAMPLE_EPOCH="${resource_now}"
            resource_status=$(jq -r '.status' "${RESOURCE_TELEMETRY_PATH}")
            report_resource_telemetry_status "${resource_status}"
            if [ "${resource_status}" = "available" ]; then
                record_manager_diagnostic \
                    telemetry \
                    telemetry-sample \
                    "" \
                    succeeded \
                    "$(elapsed_milliseconds "${telemetry_started_epoch}")" \
                    none \
                    ""
            else
                record_manager_diagnostic \
                    telemetry \
                    telemetry-sample \
                    "" \
                    failed \
                    "$(elapsed_milliseconds "${telemetry_started_epoch}")" \
                    docker-failed \
                    "Resource telemetry collection was incomplete"
            fi
        else
            record_manager_diagnostic \
                telemetry \
                telemetry-sample \
                "" \
                failed \
                "$(elapsed_milliseconds "${telemetry_started_epoch}")" \
                docker-unavailable \
                "Resource telemetry collection failed"

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
    observed_stale_count=0
    for observed_slot_path in "${SLOT_DIRECTORY}"/*; do
        [ -d "${observed_slot_path}" ] || continue
        [ -f "${observed_slot_path}/stale" ] &&
            observed_stale_count=$((observed_stale_count + 1))
    done

    observed_journal_path="/tmp/pitcrew-observed-journal.json"
    observed_health_path="/tmp/pitcrew-observed-subsystem-health.json"
    observed_capacity_path="/tmp/pitcrew-observed-capacity-evidence.json"
    observed_host_admission_path="/tmp/pitcrew-observed-host-admission.json"
    observed_host_admission_wait_state=$(host_admission_wait_state "${SLOT_DIRECTORY}")
    render_operation_journal "${DIAGNOSTICS_DIRECTORY}" "${observed_journal_path}" || true
    if render_subsystem_health "${DIAGNOSTICS_DIRECTORY}" "${observed_health_path}"; then
        render_fixed_capacity_evidence \
            "${observed_slots_path}" \
            "${observed_desired_count}" \
            "${observed_desired_status}" \
            "${observed_health_path}" \
            "${observed_capacity_path}" \
            "${observed_host_admission_wait_state}" || true
    else
        write_unavailable_capacity_evidence "${observed_capacity_path}" || true
    fi
    host_admission_status "${observed_host_admission_path}" || true

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
        "${RESOURCE_TELEMETRY_PATH}" \
        "${WORKER_REVISION}" \
        "${observed_stale_count}" \
        "${RESOURCE_POLICY_PATH}" \
        "${observed_journal_path}" \
        "${observed_health_path}" \
        "${observed_capacity_path}" \
        "${IMAGE}" \
        "${WORKER_IMAGE_ID}" \
        "${observed_hardware_path}" \
        "${observed_host_admission_path}"; then
        LAST_OBSERVED_STATE_PUBLISH_EPOCH="${observed_now}"
    else
        mark_observed_state_dirty
        echo "[manager:${PROFILE_ID}] could not publish observed state" >&2
        record_manager_diagnostic \
            reconciliation \
            observed-state-publish \
            "" \
            failed \
            "" \
            invalid-state \
            "Observed state could not be published"
    fi
    rm -f \
        "${observed_slots_path}" \
        "${observed_journal_path}" \
        "${observed_health_path}" \
        "${observed_capacity_path}" \
        "${observed_host_admission_path}"
    rm -f "${HOST_HARDWARE_FALLBACK_PATH}"
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
    STOPPING=1
    MANAGER_STATUS="stopping"
    if ! jq -e \
        --arg managerContainerId "${HOSTNAME:-}" \
        '
            .schemaVersion == 1
            and ($managerContainerId | length > 0)
            and (.managerContainerId | type == "string")
            and (.managerContainerId | startswith($managerContainerId))
            and (.requestedAt | type == "string" and length > 0)
        ' "${SHUTDOWN_REQUEST_PATH}" >/dev/null 2>&1; then
        echo "[manager:${PROFILE_ID}] received manager handoff signal; preserving managed runner containers"
        record_manager_diagnostic \
            recovery \
            manager-shutdown \
            "" \
            succeeded \
            "" \
            none \
            "Manager handoff preserved managed workers"
        mark_observed_state_dirty
        publish_observed_state 1
        exit 0
    fi

    echo "[manager:${PROFILE_ID}] received explicit shutdown request; stopping managed runner containers"
    record_manager_diagnostic \
        recovery \
        manager-shutdown \
        "" \
        succeeded \
        "" \
        none \
        "Manager shutdown is stopping managed workers"
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
        record_manager_diagnostic \
            cleanup \
            container-cleanup \
            "" \
            failed \
            "" \
            docker-failed \
            "Managed workers remained after shutdown cleanup"
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

record_container_image_identity() {
    identity_slot_path="$1"
    identity_container_id="$2"
    identity_image=$(
        docker inspect --format '{{.Image}}' "${identity_container_id}" 2>/dev/null || true
    )
    if printf '%s' "${identity_image}" | grep -Eq '^sha256:[0-9a-f]{64}$'; then
        printf '%s\n' "${identity_image}" > "${identity_slot_path}/image-id"
    else
        rm -f "${identity_slot_path}/image-id"
    fi
    mark_observed_state_dirty
}

monitor_runner_container() {
    monitored_slot_path="$1"
    monitored_name="$2"
    monitored_id="$3"
    monitored_log_path="$4"
    monitored_since="${5:-}"

    monitored_started_epoch=$(date +%s)
    : > "${monitored_log_path}"
    if [ -n "${monitored_since}" ]; then
        docker logs --since "${monitored_since}" --follow "${monitored_id}" 2>&1
    else
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

    wait_output=$(docker wait "${monitored_id}" 2>/dev/null || true)
    wait "${logs_pid}" 2>/dev/null || true
    case "${wait_output}" in
        ''|*[!0-9]*) wait_exit_code="" ;;
        *) wait_exit_code="${wait_output}" ;;
    esac

    # Docker removes an ephemeral worker as soon as it exits, so exit state is
    # captured immediately and never inferred when the record is already gone.
    exit_evidence="unavailable"
    exit_code="${wait_exit_code}"
    exit_oom_killed=""
    exit_inspect_path="${monitored_slot_path}/.container-exit.$$.json"
    if docker inspect "${monitored_id}" > "${exit_inspect_path}" 2>/dev/null &&
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

run_slot() {
    slot_key="$1"
    repo="$2"
    tag="$3"
    slot_state_path=$(slot_path "${slot_key}")
    failures=0
    log_path="/tmp/slot-${slot_key}.log"

    if [ -f "${slot_state_path}/recovered-container-id" ]; then
        recovered_id=$(cat "${slot_state_path}/recovered-container-id")
        recovered_name=$(cat "${slot_state_path}/recovered-container-name")
        recovered_status=$(cat "${slot_state_path}/recovered-container-status")
        consume_slot_connect_marker "${slot_state_path}"
        printf '%s\n' "${recovered_id}" > "${slot_state_path}/container-id"
        printf '%s\n' "${recovered_name}" > "${slot_state_path}/container-name"
        write_slot_runtime_state \
            "${slot_state_path}" \
            "${OBSERVED_STATE_DIRTY}" \
            "starting" \
            "${recovered_name}" \
            0 \
            0 || true
        write_registration_observation \
            "${slot_state_path}" \
            "${OBSERVED_STATE_DIRTY}" \
            "unknown" \
            "unknown" \
            0 || true
        printf '%s\n' \
            "$(( $(date +%s) + REGISTRATION_GRACE_SECONDS ))" \
            > "${slot_state_path}/registration-grace-until"
        if docker inspect "${recovered_id}" >/dev/null 2>&1; then
            recovered_adoption_pid=""
            if host_admission_enabled; then
                if [ "${recovered_status}" = "created" ]; then
                    while [ ! -f "${slot_state_path}/drain" ]; do
                        host_admission_acquire \
                            "${slot_state_path}" \
                            "${slot_key}" \
                            "${SLOT_DIRECTORY}"
                        admission_status=$?
                        if [ "${admission_status}" -eq 0 ] &&
                            host_admission_activate \
                                "${slot_state_path}" \
                                "${slot_key}" &&
                            docker start "${recovered_id}" >/dev/null 2>&1; then
                            recovered_status="running"
                            break
                        fi
                        if [ "${admission_status}" -eq 0 ]; then
                            host_admission_release_or_queue \
                                "${slot_state_path}" \
                                "${slot_key}" || true
                        fi
                        sleep 2
                    done
                    if [ "${recovered_status}" != "running" ]; then
                        docker rm --force "${recovered_id}" >/dev/null 2>&1 || true
                        host_admission_reconcile_absent \
                            "${slot_state_path}" \
                            "${slot_key}" || true
                    fi
                else
                    host_admission_adopt_running \
                        "${slot_state_path}" \
                        "${slot_key}" \
                        "${recovered_id}" &
                    recovered_adoption_pid=$!
                fi
            fi
            record_container_image_identity "${slot_state_path}" "${recovered_id}"
            # Docker's --since boundary is inclusive. Skip the current second so
            # a pre-handoff connect marker cannot be replayed as fresh evidence.
            recovered_logs_since=$(( $(date +%s) + 1 ))
            if [ "${recovered_status}" = "running" ]; then
                monitor_runner_container \
                    "${slot_state_path}" \
                    "${recovered_name}" \
                    "${recovered_id}" \
                    "${log_path}" \
                    "${recovered_logs_since}" || true
                if host_admission_enabled; then
                    if [ -n "${recovered_adoption_pid}" ]; then
                        wait "${recovered_adoption_pid}" || true
                    fi
                    while ! host_admission_release \
                        "${slot_state_path}" \
                        "${slot_key}"; do
                        host_admission_queue_release "${slot_key}" || true
                        if [ -f "${slot_state_path}/drain" ]; then
                            echo "[slot ${slot_key}] coordinator unavailable during drain; active lease remains fenced" >&2
                            break
                        fi
                        sleep 2
                    done
                fi
            fi
        fi
        host_admission_finish_tracked_adoption "${slot_key}"
        rm -f \
            "${slot_state_path}/recovered-container-id" \
            "${slot_state_path}/recovered-container-name" \
            "${slot_state_path}/recovered-container-status" \
            "${slot_state_path}/stale"
        if [ -f "${slot_state_path}/drain" ]; then
            echo "[slot ${slot_key}] recovered runner exited; drained slot will not respawn"
            host_admission_end_wait \
                "${slot_state_path}" \
                "${SLOT_DIRECTORY}"
            rm -f "${log_path}"
            return
        fi
    fi

    while [ ! -f "${slot_state_path}/drain" ]; do
        if host_admission_enabled; then
            host_admission_acquire \
                "${slot_state_path}" \
                "${slot_key}" \
                "${SLOT_DIRECTORY}"
            admission_status=$?
            if [ "${admission_status}" -ne 0 ]; then
                if [ "${admission_status}" -eq 2 ]; then
                    echo "[slot ${slot_key}] host admission withheld worker launch"
                elif [ "${admission_status}" -eq 3 ]; then
                    echo "[slot ${slot_key}] host admission policy is degraded; preserving current pool" >&2
                else
                    echo "[slot ${slot_key}] host admission unavailable; preserving current pool" >&2
                fi
                write_slot_runtime_state \
                    "${slot_state_path}" \
                    "${OBSERVED_STATE_DIRTY}" \
                    "backoff" \
                    "" \
                    "${failures}" \
                    2 || true
                sleep 2
                continue
            fi
            if [ -f "${slot_state_path}/drain" ]; then
                host_admission_release_or_queue \
                    "${slot_state_path}" \
                    "${slot_key}" || true
                break
            fi
        fi
        name="${PREFIX}-${tag}-$(date +%s)-$(rand_hex)"
        echo "[slot ${slot_key}] starting fresh ephemeral runner: ${name} -> ${repo:-<scope>}"
        : > "${log_path}"
        reset_slot_connect_marker "${slot_state_path}"
        write_slot_runtime_state \
            "${slot_state_path}" \
            "${OBSERVED_STATE_DIRTY}" \
            "starting" \
            "${name}" \
            "${failures}" \
            0 || true
        write_registration_observation \
            "${slot_state_path}" \
            "${OBSERVED_STATE_DIRTY}" \
            "unknown" \
            "unknown" \
            0 || true
        printf '%s\n' \
            "$(( $(date +%s) + REGISTRATION_GRACE_SECONDS ))" \
            > "${slot_state_path}/registration-grace-until"
        if host_admission_enabled; then
            set -- docker create --rm
        else
            set -- docker run --rm --detach
        fi
        set -- "$@" \
            --label "${MANAGED_LABEL}" \
            --label "${SLOT_LABEL_KEY}=${slot_key}" \
            --label "${WORKER_REVISION_LABEL_KEY}=${WORKER_REVISION}" \
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
        if host_admission_enabled; then
            set -- "$@" \
                --label "${HOST_ADMISSION_NAMESPACE_LABEL_KEY}=${HOST_ADMISSION_NAMESPACE}" \
                --label "${HOST_ADMISSION_PROFILE_LABEL_KEY}=${PROFILE_ID}" \
                --label "${HOST_ADMISSION_SLOT_LABEL_KEY}=${slot_key}"
        fi
        if [ "${RUNNER_NO_DEFAULT_LABELS:-}" = "1" ]; then
            set -- "$@" -e NO_DEFAULT_LABELS=1
        fi
        if [ -n "${RUNNER_GROUP:-}" ]; then
            set -- "$@" -e RUNNER_GROUP="${RUNNER_GROUP}"
        fi
        if [ -n "${SERVICE_NETWORK}" ]; then
            set -- "$@" --network "${SERVICE_NETWORK}"
        fi
        if [ -n "${READ_ONLY_VOLUMES}" ]; then
            previous_ifs=${IFS}
            IFS=','
            for configured_volume in ${READ_ONLY_VOLUMES}; do
                volume_name=${configured_volume%%=*}
                volume_source=${configured_volume#*=}
                set -- "$@" \
                    --mount \
                    "type=volume,src=${volume_source},dst=/mnt/pitcrew-data/${volume_name},readonly,volume-nocopy"
            done
            IFS=${previous_ifs}
        fi
        # Canonical policy values are validated at startup, so unquoted expansion
        # only splits manager-owned Docker arguments.
        set -- "$@" ${WORKER_RESOURCE_ARGUMENTS} "${IMAGE}"
        launch_started_epoch=$(date +%s)
        launch_output=$("$@" 2>&1)
        launch_status=$?
        if [ "${launch_status}" -eq 0 ] && [ -n "${launch_output}" ]; then
            container_id=$(printf '%s\n' "${launch_output}" | tail -n 1)
            if host_admission_enabled; then
                if ! host_admission_activate \
                    "${slot_state_path}" \
                    "${slot_key}"; then
                    docker rm --force "${container_id}" >/dev/null 2>&1 || true
                    host_admission_release_or_queue \
                        "${slot_state_path}" \
                        "${slot_key}" || true
                    launch_status=1
                    launch_output='Host admission lease could not be activated'
                elif ! docker start "${container_id}" >/dev/null 2>&1; then
                    docker rm --force "${container_id}" >/dev/null 2>&1 || true
                    host_admission_release_or_queue \
                        "${slot_state_path}" \
                        "${slot_key}" || true
                    launch_status=1
                    launch_output='Created worker container could not be started'
                fi
            fi
        fi
        if [ "${launch_status}" -eq 0 ] && [ -n "${launch_output}" ]; then
            record_manager_diagnostic \
                worker-launch \
                worker-launch \
                "${slot_key}" \
                succeeded \
                "$(elapsed_milliseconds "${launch_started_epoch}")" \
                none \
                ""
            printf '%s\n' "${container_id}" > "${slot_state_path}/container-id"
            printf '%s\n' "${name}" > "${slot_state_path}/container-name"
            printf '%s\n' "${WORKER_REVISION}" > "${slot_state_path}/worker-revision"
            record_container_image_identity "${slot_state_path}" "${container_id}"
            monitor_runner_container \
                "${slot_state_path}" \
                "${name}" \
                "${container_id}" \
                "${log_path}" \
                "" || true
            if host_admission_enabled; then
                while ! host_admission_release \
                    "${slot_state_path}" \
                    "${slot_key}"; do
                    host_admission_queue_release "${slot_key}" || true
                    if [ -f "${slot_state_path}/drain" ]; then
                        echo "[slot ${slot_key}] coordinator unavailable during drain; active lease remains fenced" >&2
                        break
                    fi
                    sleep 2
                done
            fi
        else
            if host_admission_enabled; then
                host_admission_release_or_queue \
                    "${slot_state_path}" \
                    "${slot_key}" || true
            fi
            record_manager_diagnostic \
                worker-launch \
                worker-launch \
                "${slot_key}" \
                failed \
                "$(elapsed_milliseconds "${launch_started_epoch}")" \
                docker-failed \
                "Worker launch command did not return a container"
            printf '%s\n' "${launch_output}" | tee -a "${log_path}" >&2
            write_slot_exit_evidence \
                "${slot_state_path}" \
                "${OBSERVED_STATE_DIRTY}" \
                "launch" \
                "" \
                "" || true
        fi

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
            record_manager_diagnostic \
                worker-launch \
                worker-launch \
                "${slot_key}" \
                retry-scheduled \
                "" \
                retry-backoff \
                "Worker slot is waiting for its launch backoff window" \
                "$(diagnostic_retry_timestamp "${wait_seconds}")"
        fi
        rm -f "${log_path}"

        elapsed=0
        while [ "${elapsed}" -lt "${wait_seconds}" ] && [ ! -f "${slot_state_path}/drain" ]; do
            sleep 1
            elapsed=$((elapsed + 1))
        done
    done

    host_admission_end_wait "${slot_state_path}" "${SLOT_DIRECTORY}"
    rm -f "${log_path}"
}

registration_endpoint_for_slot() {
    slot_repository="$1"
    github_runner_endpoint \
        "${RUNNER_SCOPE:-repo}" \
        "${slot_repository}" \
        "${ORG_NAME:-}" \
        "${ENTERPRISE_NAME:-}"
}

reconcile_runner_registrations() {
    registration_now=$(date +%s)
    if [ $((registration_now - LAST_REGISTRATION_RECONCILE_EPOCH)) -lt "${REGISTRATION_RECONCILE_INTERVAL}" ]; then
        return
    fi
    LAST_REGISTRATION_RECONCILE_EPOCH="${registration_now}"
    rm -rf "${REGISTRATION_INVENTORY_DIRECTORY}"
    mkdir -p "${REGISTRATION_INVENTORY_DIRECTORY}"
    targets_path="${REGISTRATION_INVENTORY_DIRECTORY}/targets.tsv"
    slots_path="${REGISTRATION_INVENTORY_DIRECTORY}/slots.tsv"
    : > "${targets_path}"
    : > "${slots_path}"

    for registration_slot_path in "${SLOT_DIRECTORY}"/*; do
        [ -d "${registration_slot_path}" ] || continue
        runner_name=""
        runtime_path="${registration_slot_path}/runtime-state.json"
        if [ -f "${runtime_path}" ]; then
            runner_name=$(jq -r '.runnerName // ""' "${runtime_path}" 2>/dev/null || true)
        fi
        if [ -z "${runner_name}" ]; then
            write_registration_observation \
                "${registration_slot_path}" \
                "${OBSERVED_STATE_DIRTY}" \
                "unknown" \
                "unknown" \
                0 || true
            continue
        fi
        slot_repository=""
        [ -f "${registration_slot_path}/repo" ] &&
            slot_repository=$(cat "${registration_slot_path}/repo")
        endpoint=$(registration_endpoint_for_slot "${slot_repository}") || {
            write_registration_observation \
                "${registration_slot_path}" \
                "${OBSERVED_STATE_DIRTY}" \
                "unknown" \
                "unknown" \
                0 || true
            continue
        }
        target_hash=$(printf '%s' "${endpoint}" | sha256sum | awk '{ print $1 }')
        if ! awk -F '\t' -v hash="${target_hash}" '$1 == hash { found=1 } END { exit !found }' \
            "${targets_path}"; then
            printf '%s\t%s\n' "${target_hash}" "${endpoint}" >> "${targets_path}"
        fi
        printf '%s\t%s\t%s\t%s\n' \
            "${registration_slot_path}" \
            "${target_hash}" \
            "${runner_name}" \
            "${endpoint}" >> "${slots_path}"
    done

    inventory_started_epoch=$(date +%s)
    inventory_pids=""
    tab=$(printf '\t')
    while IFS="${tab}" read -r target_hash endpoint; do
        [ -n "${target_hash}" ] || continue
        (
            if ! fetch_github_runner_inventory \
                "${REGISTRATION_INVENTORY_DIRECTORY}/${target_hash}.json" \
                "${endpoint}" \
                "${ACCESS_TOKEN:-}" \
                "${REGISTRATION_API_TIMEOUT}"; then
                : > "${REGISTRATION_INVENTORY_DIRECTORY}/${target_hash}.error"
            fi
        ) &
        inventory_pids="${inventory_pids} $!"
    done < "${targets_path}"
    for inventory_pid in ${inventory_pids}; do
        wait "${inventory_pid}" 2>/dev/null || true
    done
    inventory_targets=$(count_lines "${targets_path}")
    inventory_failures=0
    for inventory_error in "${REGISTRATION_INVENTORY_DIRECTORY}"/*.error; do
        [ -f "${inventory_error}" ] || continue
        inventory_failures=$((inventory_failures + 1))
    done
    if [ "${inventory_targets}" -gt 0 ]; then
        if [ "${inventory_failures}" -gt 0 ]; then
            record_manager_diagnostic \
                registration \
                runner-registration \
                "" \
                failed \
                "$(elapsed_milliseconds "${inventory_started_epoch}")" \
                unknown \
                "GitHub runner inventory could not be reconciled"
        else
            record_manager_diagnostic \
                registration \
                runner-registration \
                "" \
                succeeded \
                "$(elapsed_milliseconds "${inventory_started_epoch}")" \
                none \
                ""
        fi
    fi

    while IFS="${tab}" read -r registration_slot_path target_hash runner_name endpoint; do
        [ -d "${registration_slot_path}" ] || continue
        inventory_path="${REGISTRATION_INVENTORY_DIRECTORY}/${target_hash}.json"
        if [ -f "${REGISTRATION_INVENTORY_DIRECTORY}/${target_hash}.error" ] ||
            [ ! -f "${inventory_path}" ]; then
            status="unknown"
            activity="unknown"
            cleanup_candidate=0
        else
            classification=$(classify_github_runner_registration \
                "${inventory_path}" \
                "${runner_name}")
            status=$(printf '%s\n' "${classification}" | cut -f1)
            activity=$(printf '%s\n' "${classification}" | cut -f2)
            cleanup_candidate=$(printf '%s\n' "${classification}" | cut -f3)
        fi
        evidence_count=$(registration_evidence_count \
            "${registration_slot_path}" \
            "${status}" \
            "${cleanup_candidate}")
        write_registration_observation \
            "${registration_slot_path}" \
            "${OBSERVED_STATE_DIRTY}" \
            "${status}" \
            "${activity}" \
            "${evidence_count}" || true
        grace_until=0
        [ -f "${registration_slot_path}/registration-grace-until" ] &&
            grace_until=$(cat "${registration_slot_path}/registration-grace-until")
        if [ "${cleanup_candidate}" = "1" ] &&
            [ "${evidence_count}" -ge "${REGISTRATION_CLEANUP_THRESHOLD}" ] &&
            [ "${registration_now}" -ge "${grace_until}" ]; then
            recheck_path="${REGISTRATION_INVENTORY_DIRECTORY}/${target_hash}.recheck.json"
            if ! fetch_github_runner_inventory \
                "${recheck_path}" \
                "${endpoint}" \
                "${ACCESS_TOKEN:-}" \
                "${REGISTRATION_API_TIMEOUT}"; then
                write_registration_observation \
                    "${registration_slot_path}" \
                    "${OBSERVED_STATE_DIRTY}" \
                    "unknown" \
                    "unknown" \
                    0 || true
                echo "[slot ${registration_slot_path##*/}] GitHub registration could not be rechecked; preserving container" >&2
                record_manager_diagnostic \
                    cleanup \
                    registration-cleanup \
                    "${registration_slot_path##*/}" \
                    blocked \
                    "" \
                    unknown \
                    "Registration cleanup was blocked because evidence could not be rechecked"
                continue
            fi
            recheck_classification=$(classify_github_runner_registration \
                "${recheck_path}" \
                "${runner_name}")
            rm -f "${recheck_path}"
            recheck_status=$(printf '%s\n' "${recheck_classification}" | cut -f1)
            recheck_activity=$(printf '%s\n' "${recheck_classification}" | cut -f2)
            recheck_candidate=$(printf '%s\n' "${recheck_classification}" | cut -f3)
            if [ "${recheck_candidate}" != "1" ] ||
                [ "${recheck_status}" != "${status}" ]; then
                recheck_evidence_count=$(registration_evidence_count \
                    "${registration_slot_path}" \
                    "${recheck_status}" \
                    "${recheck_candidate}")
                write_registration_observation \
                    "${registration_slot_path}" \
                    "${OBSERVED_STATE_DIRTY}" \
                    "${recheck_status}" \
                    "${recheck_activity}" \
                    "${recheck_evidence_count}" || true
                echo "[slot ${registration_slot_path##*/}] GitHub registration evidence changed before cleanup; preserving container" >&2
                record_manager_diagnostic \
                    cleanup \
                    registration-cleanup \
                    "${registration_slot_path##*/}" \
                    blocked \
                    "" \
                    invalid-state \
                    "Registration cleanup was blocked because evidence changed"
                continue
            fi
            if stop_confirmed_ghost \
                "${registration_slot_path}" \
                "${runner_name}" \
                "${PROFILE_ID}" \
                "${MANAGED_LABEL_KEY}" \
                "${SLOT_LABEL_KEY}" \
                "${RUNNER_STOP_TIMEOUT}" \
                "${REGISTRATION_CLEANUP_THRESHOLD}"; then
                record_manager_diagnostic \
                    cleanup \
                    registration-cleanup \
                    "${registration_slot_path##*/}" \
                    succeeded \
                    "" \
                    none \
                    ""
            else
                record_manager_diagnostic \
                    cleanup \
                    container-cleanup \
                    "${registration_slot_path##*/}" \
                    failed \
                    "" \
                    docker-failed \
                    "Confirmed ghost container could not be stopped"
            fi
        fi
    done < "${slots_path}"
    rm -rf "${REGISTRATION_INVENTORY_DIRECTORY}"
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

start_recovered_slot() {
    recovered_key="$1"
    recovered_repo="$2"
    recovered_tag="$3"
    recovered_id="$4"
    recovered_name="$5"
    recovered_revision="$6"
    recovered_desired="$7"
    recovered_status="$8"
    recovered_path=$(slot_path "${recovered_key}")

    if [ -d "${recovered_path}" ]; then
        echo "[manager:${PROFILE_ID}] duplicate recovered slot ${recovered_key}" >&2
        return 1
    fi
    mkdir -p "${recovered_path}"
    printf '%s\n' "${recovered_repo}" > "${recovered_path}/repo"
    printf '%s\n' "${recovered_tag}" > "${recovered_path}/tag"
    printf '%s\n' "${recovered_id}" > "${recovered_path}/recovered-container-id"
    printf '%s\n' "${recovered_name}" > "${recovered_path}/recovered-container-name"
    printf '%s\n' "${recovered_status}" > "${recovered_path}/recovered-container-status"
    effective_revision="${recovered_revision}"
    if [ -z "${effective_revision}" ] && [ "${ASSUME_UNVERSIONED_CURRENT}" = "1" ]; then
        effective_revision="${WORKER_REVISION}"
    fi
    printf '%s\n' "${effective_revision}" > "${recovered_path}/worker-revision"
    if [ "${effective_revision}" != "${WORKER_REVISION}" ]; then
        : > "${recovered_path}/stale"
    fi
    if [ "${recovered_desired}" != "1" ]; then
        : > "${recovered_path}/drain"
    fi
    if [ "${recovered_status}" = "running" ]; then
        host_admission_track_adoption "${recovered_key}" || return 1
    fi
    run_slot "${recovered_key}" "${recovered_repo}" "${recovered_tag}" &
    printf '%s\n' "$!" > "${recovered_path}/pid"
}

restore_managed_slots() {
    recovered_ids=$(docker ps -aq --filter "label=${MANAGED_LABEL}") || return 1
    [ -n "${recovered_ids}" ] || return 0

    recovered_inventory="/tmp/pitcrew-recovered.$$"
    if ! docker inspect ${recovered_ids} |
        jq -r \
            --arg profile "${PROFILE_ID}" \
            --arg managedLabel "${MANAGED_LABEL_KEY}" \
            --arg slotLabel "${SLOT_LABEL_KEY}" \
            --arg revisionLabel "${WORKER_REVISION_LABEL_KEY}" \
            '
                .[]
                | select(.State.Running == true or .State.Status == "created")
                | select(.Config.Labels[$managedLabel] == $profile)
                | [
                    .Id,
                    (.Name | ltrimstr("/")),
                    (.Config.Labels[$slotLabel] // ""),
                    (.Config.Labels[$revisionLabel] // ""),
                    .State.Status,
                    (
                        [
                            .Config.Env[]
                            | select(startswith("REPO_URL="))
                            | ltrimstr("REPO_URL=")
                        ][0] // ""
                    )
                ]
                | @tsv
            ' > "${recovered_inventory}"; then
        rm -f "${recovered_inventory}"
        return 1
    fi

    tab=$(printf '\t')
    while IFS="${tab}" read -r recovered_id recovered_name recovered_key recovered_revision recovered_status recovered_repo; do
        [ -n "${recovered_id}" ] || continue
        if [ -z "${recovered_key}" ]; then
            echo "[manager:${PROFILE_ID}] recovered container ${recovered_id} has no slot label" >&2
            rm -f "${recovered_inventory}"
            return 1
        fi
        desired_record=$(
            awk -F "${tab}" -v key="${recovered_key}" '
                $1 == key { print $2 "\t" $3; exit }
            ' "${CURRENT_DESIRED_SLOTS}"
        )
        recovered_desired=0
        recovered_tag="retired"
        if [ -n "${desired_record}" ]; then
            recovered_desired=1
            recovered_repo=$(printf '%s\n' "${desired_record}" | cut -f1)
            recovered_tag=$(printf '%s\n' "${desired_record}" | cut -f2)
            [ "${recovered_repo}" = "-" ] && recovered_repo=""
        fi
        if ! start_recovered_slot \
            "${recovered_key}" \
            "${recovered_repo}" \
            "${recovered_tag}" \
            "${recovered_id}" \
            "${recovered_name}" \
            "${recovered_revision}" \
            "${recovered_desired}" \
            "${recovered_status}"; then
            rm -f "${recovered_inventory}"
            return 1
        fi
    done < "${recovered_inventory}"
    rm -f "${recovered_inventory}"
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
            activationMode: "fixed",
            activeSlots: $desiredSlots,
            minimumIdleSlots: $desiredSlots,
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
        --argjson managerContractVersion "${MANAGER_CONTRACT_VERSION}" \
        '
            .schemaVersion == 1
            and .status == "accepted"
            and .generation == $generation
            and .managerContractVersion == $managerContractVersion
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
                record_manager_diagnostic \
                    reconciliation \
                    capacity-acknowledge \
                    "" \
                    failed \
                    "" \
                    invalid-state \
                    "Accepted capacity could not be acknowledged"
            fi
            record_manager_diagnostic \
                reconciliation \
                desired-state-apply \
                "" \
                succeeded \
                "" \
                none \
                "Accepted a new desired capacity generation"
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
                record_manager_diagnostic \
                    reconciliation \
                    desired-state-load \
                    "" \
                    blocked \
                    "" \
                    invalid-state \
                    "Desired capacity was rejected and the accepted generation was retained"
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
diagnostics_initialize "${DIAGNOSTICS_DIRECTORY}" "${MANAGER_INSTANCE_ID}" ||
    echo "[manager:${PROFILE_ID}] operation diagnostics could not be initialized" >&2
rm -rf "${SLOT_DIRECTORY}"
mkdir -p "${SLOT_DIRECTORY}"
rm -rf "${PITCREW_HOST_ADMISSION_ADOPTION_DIRECTORY}"
mkdir -p "${PITCREW_HOST_ADMISSION_ADOPTION_DIRECTORY}"
: > "${CURRENT_DESIRED_SLOTS}"
rm -f "${OBSERVED_STATE_DIRTY}" "${RESOURCE_TELEMETRY_PATH}"
if ! write_worker_resource_policy \
    "${RESOURCE_POLICY_PATH}" \
    "${WORKER_MEMORY_BYTES}" \
    "${WORKER_MEMORY_SWAP_BYTES}" \
    "${WORKER_CPU_CORES}" \
    "${WORKER_PIDS_LIMIT}"; then
    echo "[manager:${PROFILE_ID}] worker resource policy could not be published." >&2
    exit 1
fi
mark_observed_state_dirty

if [ "${RUNNER_PULL_IMAGE:-1}" = "1" ]; then
    echo "[manager:${PROFILE_ID}] pre-pulling runner image ${IMAGE}"
    docker pull "${IMAGE}" >/dev/null 2>&1 ||
        echo "[manager:${PROFILE_ID}] pull failed; relying on the local image"
else
    echo "[manager:${PROFILE_ID}] using locally prepared runner image ${IMAGE}"
fi

bootstrap_legacy_desired_state
load_accepted_state
echo "[manager:${PROFILE_ID}] adopting any managed runners left by the previous manager"
if ! host_admission_begin_adoption; then
    echo "[manager:${PROFILE_ID}] could not establish the recovery admission barrier" >&2
    exit 1
fi
if ! restore_managed_slots; then
    echo "[manager:${PROFILE_ID}] managed runner recovery failed; preserving containers and stopping" >&2
    record_manager_diagnostic \
        docker \
        docker-inspect \
        "" \
        failed \
        "" \
        docker-unavailable \
        "Managed worker discovery failed during manager adoption"
    exit 1
fi
while host_admission_adoption_pending; do
    sleep 1
done
if ! host_admission_complete_adoption; then
    echo "[manager:${PROFILE_ID}] could not clear the recovery admission barrier" >&2
    exit 1
fi
adopted_slot_count=0
for adopted_slot_path in "${SLOT_DIRECTORY}"/*; do
    [ -d "${adopted_slot_path}" ] || continue
    adopted_slot_count=$((adopted_slot_count + 1))
done
if [ "${adopted_slot_count}" -gt 0 ]; then
    record_manager_diagnostic \
        recovery \
        manager-start \
        "" \
        recovered \
        "" \
        recovered \
        "Manager adopted managed workers left by its predecessor"
else
    record_manager_diagnostic \
        recovery \
        manager-start \
        "" \
        succeeded \
        "" \
        none \
        "Manager started with no adopted workers"
fi
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
reconcile_runner_registrations
publish_observed_state 1

while [ "${STOPPING}" -eq 0 ]; do
    host_admission_retry_releases || true
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
    reconcile_runner_registrations
    publish_observed_state 0
    sleep "${RECONCILE_INTERVAL}"
done
