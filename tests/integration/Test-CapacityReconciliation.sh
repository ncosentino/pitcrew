#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
RUN_ID="${GITHUB_RUN_ID:-$$}"
PROFILE_NAME="integration-${RUN_ID}"
LEGACY_PROFILE_NAME="legacy-${RUN_ID}"
PROFILE_LABEL="ephemeral-managed-runner-profile=${PROFILE_NAME}"
MANAGER_LABEL="ephemeral-runner-manager-profile=${PROFILE_NAME}"
LEGACY_PROFILE_LABEL="ephemeral-managed-runner-profile=${LEGACY_PROFILE_NAME}"
LEGACY_MANAGER_LABEL="ephemeral-runner-manager-profile=${LEGACY_PROFILE_NAME}"
SLOT_LABEL="ephemeral-managed-runner-slot"
FAKE_IMAGE="pitcrew-fake-runner:${PROFILE_NAME}"
REPOSITORY_URL="https://github.com/example/integration"
STATE_DIRECTORY="${ROOT}/.pitcrew-state/${PROFILE_NAME}"
DESIRED_STATE="${STATE_DIRECTORY}/desired-capacity.json"
ACKNOWLEDGEMENT="${STATE_DIRECTORY}/acknowledged-capacity.json"
LEGACY_STATE_DIRECTORY="${ROOT}/.pitcrew-state/${LEGACY_PROFILE_NAME}"
LEGACY_DESIRED_STATE="${LEGACY_STATE_DIRECTORY}/desired-capacity.json"
LEGACY_COMPOSE_PROJECT="self-hosted-runner-${LEGACY_PROFILE_NAME}"
FIXTURE_DIRECTORY=$(mktemp -d)
PROFILE_PATH="${FIXTURE_DIRECTORY}/profile.json"
MANAGER_ID=""

worker_ids() {
    docker ps -q --filter "label=${PROFILE_LABEL}" | sort
}

worker_count() {
    worker_ids | awk 'END { print NR + 0 }'
}

manager_id() {
    docker ps -q --filter "label=${MANAGER_LABEL}"
}

slot_container_id() {
    docker ps -q \
        --filter "label=${PROFILE_LABEL}" \
        --filter "label=${SLOT_LABEL}=$1"
}

wait_for_worker_count() {
    expected="$1"
    deadline=$((SECONDS + 60))
    while [ "${SECONDS}" -lt "${deadline}" ]; do
        if [ "$(worker_count)" -eq "${expected}" ]; then
            return
        fi
        sleep 1
    done
    echo "Timed out waiting for ${expected} workers; found $(worker_count)." >&2
    return 1
}

wait_for_acknowledgement() {
    expected_generation="$1"
    deadline=$((SECONDS + 60))
    while [ "${SECONDS}" -lt "${deadline}" ]; do
        if [ -f "${ACKNOWLEDGEMENT}" ] &&
            [ "$(jq -r '.generation // 0' "${ACKNOWLEDGEMENT}" 2>/dev/null || echo 0)" -eq "${expected_generation}" ]; then
            return
        fi
        sleep 1
    done
    echo "Timed out waiting for acknowledgement generation ${expected_generation}." >&2
    return 1
}

wait_for_slot_replacement() {
    slot_key="$1"
    previous_id="$2"
    deadline=$((SECONDS + 60))
    while [ "${SECONDS}" -lt "${deadline}" ]; do
        replacement_id=$(slot_container_id "${slot_key}")
        if [ -n "${replacement_id}" ] && [ "${replacement_id}" != "${previous_id}" ]; then
            return
        fi
        sleep 1
    done
    echo "Timed out waiting for slot ${slot_key} to respawn." >&2
    return 1
}

run_setup() {
    workers="$1"
    pwsh -NoProfile -Command \
        "& '${ROOT}/Setup-Runner.ps1' -ProfilePath '${PROFILE_PATH}' -Token 'integration-token' -Repos '${REPOSITORY_URL}=${workers}'"
}

start_legacy_compose() {
    (
        cd "${ROOT}"
        ACCESS_TOKEN="integration-token" \
        REPO_URLS="${REPOSITORY_URL}=2" \
        REPO_URL="" \
        RUNNER_SCOPE="repo" \
        ORG_NAME="" \
        ENTERPRISE_NAME="" \
        RUNNER_PROFILE_ID="${LEGACY_PROFILE_NAME}" \
        RUNNER_REPLICAS="1" \
        RUNNER_IMAGE="${FAKE_IMAGE}" \
        RUNNER_PULL_IMAGE="0" \
        RUNNER_NAME_PREFIX="${LEGACY_PROFILE_NAME}" \
        RUNNER_LABELS="integration" \
        RUNNER_NO_DEFAULT_LABELS="1" \
        RUNNER_GROUP="" \
        PITCREW_STATE_DIR=".pitcrew-state/${LEGACY_PROFILE_NAME}" \
        PITCREW_MANAGER_CONTRACT_VERSION="2" \
            docker compose \
                --file docker-compose.yml \
                --project-name "${LEGACY_COMPOSE_PROJECT}" \
                up -d --build
    )
}

stop_legacy_compose() {
    (
        cd "${ROOT}"
        PITCREW_STATE_DIR=".pitcrew-state/${LEGACY_PROFILE_NAME}" \
            docker compose \
                --file docker-compose.yml \
                --project-name "${LEGACY_COMPOSE_PROJECT}" \
                down --remove-orphans
    )
}

wait_for_legacy_worker_count() {
    expected="$1"
    deadline=$((SECONDS + 60))
    while [ "${SECONDS}" -lt "${deadline}" ]; do
        count=$(docker ps -q --filter "label=${LEGACY_PROFILE_LABEL}" | awk 'END { print NR + 0 }')
        if [ "${count}" -eq "${expected}" ]; then
            return
        fi
        sleep 1
    done
    echo "Timed out waiting for ${expected} legacy-adapter workers." >&2
    return 1
}

assert_running() {
    container_id="$1"
    [ "$(docker inspect --format '{{.State.Running}}' "${container_id}")" = "true" ] ||
        {
            echo "Container ${container_id} is not running." >&2
            return 1
        }
}

cleanup() {
    status=$?
    if [ "${status}" -ne 0 ] && [ -n "${MANAGER_ID}" ]; then
        docker logs "${MANAGER_ID}" 2>&1 || true
    fi
    pwsh -NoProfile -Command \
        "& '${ROOT}/Setup-Runner.ps1' -ProfilePath '${PROFILE_PATH}' -Down" >/dev/null 2>&1 || true
    stop_legacy_compose >/dev/null 2>&1 || true
    docker ps -aq --filter "label=${PROFILE_LABEL}" |
        xargs -r docker rm -f >/dev/null 2>&1 || true
    docker ps -aq --filter "label=${LEGACY_PROFILE_LABEL}" |
        xargs -r docker rm -f >/dev/null 2>&1 || true
    docker image rm -f "${FAKE_IMAGE}" >/dev/null 2>&1 || true
    rm -f "${ROOT}/.env.${PROFILE_NAME}"
    rm -rf "${STATE_DIRECTORY}" "${LEGACY_STATE_DIRECTORY}" "${FIXTURE_DIRECTORY}"
    rmdir "${ROOT}/.pitcrew-state" >/dev/null 2>&1 || true
    trap - EXIT
    exit "${status}"
}
trap cleanup EXIT

cat > "${PROFILE_PATH}" <<EOF
{
  "schemaVersion": 1,
  "name": "${PROFILE_NAME}",
  "description": "Isolated real-Docker reconciliation test profile.",
  "image": "${FAKE_IMAGE}",
  "labels": ["integration"],
  "replicas": 1,
  "pullImage": false,
  "disableDefaultLabels": true
}
EOF

docker build \
    --tag "${FAKE_IMAGE}" \
    "${ROOT}/tests/integration/fake-runner"

mkdir -p "${ROOT}/.pitcrew-state"
start_legacy_compose
wait_for_legacy_worker_count 2
[ -n "$(docker ps -q --filter "label=${LEGACY_MANAGER_LABEL}")" ] || {
    echo "Legacy direct-Compose manager did not start." >&2
    exit 1
}
[ "$(jq -r '.generation' "${LEGACY_DESIRED_STATE}")" -eq 1 ] || {
    echo "Legacy direct-Compose capacity did not bootstrap generation one." >&2
    exit 1
}
[ "$(jq -r '.repositories[0].workers' "${LEGACY_DESIRED_STATE}")" -eq 2 ] || {
    echo "Legacy direct-Compose capacity did not preserve worker count." >&2
    exit 1
}
stop_legacy_compose
wait_for_legacy_worker_count 0

run_setup 5
wait_for_acknowledgement 1
wait_for_worker_count 5
MANAGER_ID=$(manager_id)
[ -n "${MANAGER_ID}" ] || {
    echo "Runner manager did not start." >&2
    exit 1
}
mapfile -t original_workers < <(worker_ids)
[ "${#original_workers[@]}" -eq 5 ]

run_setup 6
wait_for_acknowledgement 2
wait_for_worker_count 6
[ "$(manager_id)" = "${MANAGER_ID}" ] || {
    echo "Capacity scale-up replaced the manager container." >&2
    exit 1
}
for container_id in "${original_workers[@]}"; do
    assert_running "${container_id}"
done
mapfile -t scaled_workers < <(worker_ids)
new_worker_count=$(comm -13 \
    <(printf '%s\n' "${original_workers[@]}" | sort) \
    <(printf '%s\n' "${scaled_workers[@]}" | sort) |
    awk 'END { print NR + 0 }')
[ "${new_worker_count}" -eq 1 ] || {
    echo "Scale-up did not add exactly one worker." >&2
    exit 1
}

run_setup 5
wait_for_acknowledgement 3
[ "$(manager_id)" = "${MANAGER_ID}" ] || {
    echo "Capacity scale-down replaced the manager container." >&2
    exit 1
}
[ "$(worker_count)" -eq 6 ] || {
    echo "Scale-down interrupted a worker before its current run completed." >&2
    exit 1
}
draining_key=$(jq -r '.drainingKeys[0]' "${ACKNOWLEDGEMENT}")
case "${draining_key}" in
    *-000006) ;;
    *)
        echo "Scale-down did not select the highest ordinal: ${draining_key}" >&2
        exit 1
        ;;
esac
draining_container=$(slot_container_id "${draining_key}")
[ -n "${draining_container}" ] || {
    echo "The acknowledged draining slot has no running container." >&2
    exit 1
}
for container_id in "${original_workers[@]}"; do
    assert_running "${container_id}"
done

docker stop --time 5 "${draining_container}" >/dev/null
wait_for_worker_count 5
[ -z "$(slot_container_id "${draining_key}")" ] || {
    echo "The drained slot respawned." >&2
    exit 1
}
for container_id in "${original_workers[@]}"; do
    assert_running "${container_id}"
done

replacement_source="${original_workers[0]}"
replacement_slot=$(docker inspect \
    --format "{{ index .Config.Labels \"${SLOT_LABEL}\" }}" \
    "${replacement_source}")
docker stop --time 5 "${replacement_source}" >/dev/null
wait_for_slot_replacement "${replacement_slot}" "${replacement_source}"
wait_for_worker_count 5

jq '.generation = 2' "${ACKNOWLEDGEMENT}" > "${ACKNOWLEDGEMENT}.stale"
mv -f "${ACKNOWLEDGEMENT}.stale" "${ACKNOWLEDGEMENT}"
docker restart "${MANAGER_ID}" >/dev/null
wait_for_acknowledgement 3
restart_deadline=$((SECONDS + 60))
while [ "${SECONDS}" -lt "${restart_deadline}" ]; do
    restored=$(docker logs "${MANAGER_ID}" 2>&1 |
        grep -c 'restored desired-capacity generation 3' || true)
    mapfile -t restart_slots < <(
        docker ps \
            --filter "label=${PROFILE_LABEL}" \
            --format "{{.Label \"${SLOT_LABEL}\"}}" |
            sort
    )
    if [ "${restored}" -gt 0 ] && [ "${#restart_slots[@]}" -eq 5 ]; then
        break
    fi
    sleep 1
done
[ "${restored}" -gt 0 ] && [ "${#restart_slots[@]}" -eq 5 ] || {
    echo "Manager restart did not reconstruct five desired slots." >&2
    exit 1
}
if printf '%s\n' "${restart_slots[@]}" | grep -Fqx "${draining_key}"; then
    echo "Manager restart reconstructed a drained slot." >&2
    exit 1
fi
[ "$(manager_id)" = "${MANAGER_ID}" ] || {
    echo "Docker restart replaced the manager container." >&2
    exit 1
}

mapfile -t workers_before_invalid_state < <(worker_ids)
printf '{"schemaVersion":1,"generation":4' > "${DESIRED_STATE}"
sleep 3
mapfile -t workers_after_invalid_state < <(worker_ids)
[ "${workers_before_invalid_state[*]}" = "${workers_after_invalid_state[*]}" ] || {
    echo "Malformed desired state churned a healthy worker pool." >&2
    exit 1
}

echo "Real Docker capacity reconciliation passed."
