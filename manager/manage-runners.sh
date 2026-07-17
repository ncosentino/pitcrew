#!/bin/sh
# Reconciles truly-ephemeral GitHub Actions runner slots from mounted desired
# state. Each slot owns one foreground `docker run --rm`; after that runner exits,
# a desired slot launches a clean replacement while a draining slot stops.
set -u

SCRIPT_DIRECTORY=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "${SCRIPT_DIRECTORY}/reconciliation.sh"

MANAGER_CONTRACT_VERSION=4
EXPECTED_CONTRACT_VERSION="${PITCREW_MANAGER_CONTRACT_VERSION:-4}"
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
RECONCILE_INTERVAL="${PITCREW_RECONCILE_INTERVAL:-1}"
SLOT_DIRECTORY="/tmp/pitcrew-slots"
CURRENT_DESIRED_SLOTS="/tmp/pitcrew-current-desired-slots.tsv"
PENDING_ACKNOWLEDGEMENT="/tmp/pitcrew-pending-acknowledgement.json"
MANAGED_LABEL_KEY="ephemeral-managed-runner-profile"
MANAGED_LABEL="${MANAGED_LABEL_KEY}=${PROFILE_ID}"
SLOT_LABEL_KEY="ephemeral-managed-runner-slot"

case "${RECONCILE_INTERVAL}" in
    ''|*[!0-9]*|0)
        echo "[manager:${PROFILE_ID}] PITCREW_RECONCILE_INTERVAL must be a positive integer." >&2
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
CURRENT_GENERATION=0
CURRENT_STATE_HASH=""
LAST_DESIRED_DOCUMENT_HASH=""
LAST_REJECTION=""
STOPPING=0

rand_hex() {
    tr -dc 'a-f0-9' < /dev/urandom 2>/dev/null | head -c 6
}

rand_jitter() {
    random_byte=$(od -An -N1 -tu1 /dev/urandom 2>/dev/null | tr -d ' ')
    echo $(( ${random_byte:-0} % 5 ))
}

remove_managed() {
    ids=$(docker ps -aq --filter "label=${MANAGED_LABEL}" 2>/dev/null || true)
    if [ -n "${ids}" ]; then
        echo "${ids}" | xargs -r docker rm -f >/dev/null 2>&1 || true
    fi
}

shutdown() {
    echo "[manager:${PROFILE_ID}] received stop signal — removing managed runner containers"
    STOPPING=1
    remove_managed
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
    if [ -f "${removed_path}/pid" ]; then
        removed_pid=$(cat "${removed_path}/pid")
        wait "${removed_pid}" 2>/dev/null || true
    fi
    rm -rf "${removed_path}"
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
            -e UNSET_CONFIG_VARS=true \
            -e LABELS="${LABELS}"
        if [ "${RUNNER_NO_DEFAULT_LABELS:-}" = "1" ]; then
            set -- "$@" -e NO_DEFAULT_LABELS=1
        fi
        if [ -n "${RUNNER_GROUP:-}" ]; then
            set -- "$@" -e RUNNER_GROUP="${RUNNER_GROUP}"
        fi
        set -- "$@" "${IMAGE}"
        "$@" 2>&1 | tee "${log_path}"

        if [ -f "${slot_state_path}/drain" ]; then
            echo "[slot ${slot_key}] current runner exited; drained slot will not respawn"
            break
        fi

        if grep -q "${CONNECT_MARKER}" "${log_path}" 2>/dev/null; then
            failures=0
            wait_seconds=1
        else
            failures=$((failures + 1))
            wait_seconds=$((failures * failures * 3))
            [ "${wait_seconds}" -gt "${MAX_BACKOFF}" ] && wait_seconds="${MAX_BACKOFF}"
            wait_seconds=$((wait_seconds + $(rand_jitter)))
            echo "[slot ${slot_key}] runner never reached '${CONNECT_MARKER}' (connect failure #${failures}) — backing off ${wait_seconds}s before retry."
            if [ "${failures}" -eq 1 ]; then
                echo "[slot ${slot_key}] Check host clock skew, available CPU and memory, and runner-administration token scope."
            fi
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
            rm -f "$(slot_path "${desired_key}")/drain"
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
            : > "${active_path}/drain"
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
            LAST_DESIRED_DOCUMENT_HASH="${snapshot_document_hash}"
            ;;
        invalid|stale|conflict)
            rejection="${classification}:${snapshot_document_hash:-unreadable}"
            if [ "${rejection}" != "${LAST_REJECTION}" ]; then
                echo "[manager:${PROFILE_ID}] rejected ${classification} desired-capacity state; retaining generation ${CURRENT_GENERATION}" >&2
                LAST_REJECTION="${rejection}"
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

echo "[manager:${PROFILE_ID}] clearing any leftover managed runners"
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
    sleep "${RECONCILE_INTERVAL}"
done
