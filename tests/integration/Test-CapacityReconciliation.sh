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
VOLUME_NAME="pitcrew-integration-data-${RUN_ID}"
SERVICE_NETWORK="pitcrew-integration-services-${RUN_ID}"
SERVICE_CONTAINER="pitcrew-integration-service-${RUN_ID}"
REPOSITORY_URL="https://github.com/example/integration"
STATE_DIRECTORY="${ROOT}/.pitcrew-state/${PROFILE_NAME}"
DESIRED_STATE="${STATE_DIRECTORY}/desired-capacity.json"
ACKNOWLEDGEMENT="${STATE_DIRECTORY}/acknowledged-capacity.json"
OBSERVED_STATE="${STATE_DIRECTORY}/observed-state.json"
LEGACY_STATE_DIRECTORY="${ROOT}/.pitcrew-state/${LEGACY_PROFILE_NAME}"
LEGACY_DESIRED_STATE="${LEGACY_STATE_DIRECTORY}/desired-capacity.json"
LEGACY_COMPOSE_PROJECT="self-hosted-runner-${LEGACY_PROFILE_NAME}"
LEGACY_OBSERVED_STATE="${LEGACY_STATE_DIRECTORY}/observed-state.json"
FAKE_IMAGE_ID=""
FIXTURE_DIRECTORY=$(mktemp -d)
PROFILE_PATH="${FIXTURE_DIRECTORY}/profile.json"
POWERSHELL_ROOT="${ROOT}"
POWERSHELL_PROFILE_PATH="${PROFILE_PATH}"
if command -v cygpath >/dev/null 2>&1; then
    POWERSHELL_ROOT=$(cygpath -w "${ROOT}")
    POWERSHELL_PROFILE_PATH=$(cygpath -w "${PROFILE_PATH}")
fi
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

wait_for_observed_generation() {
    expected_generation="$1"
    expected_status="$2"
    deadline=$((SECONDS + 60))
    while [ "${SECONDS}" -lt "${deadline}" ]; do
        if [ -f "${OBSERVED_STATE}" ] &&
            [ "$(jq -r '.generation // -1' "${OBSERVED_STATE}" 2>/dev/null || echo -1)" -eq "${expected_generation}" ] &&
            [ "$(jq -r '.desiredStateStatus // ""' "${OBSERVED_STATE}" 2>/dev/null || true)" = "${expected_status}" ]; then
            return
        fi
        sleep 1
    done
    echo "Timed out waiting for observed generation ${expected_generation} with status ${expected_status}." >&2
    return 1
}

wait_for_resource_slot_count() {
    expected="$1"
    deadline=$((SECONDS + 60))
    while [ "${SECONDS}" -lt "${deadline}" ]; do
        if [ -f "${OBSERVED_STATE}" ] &&
            [ "$(jq '[.slots[].resources | select(. != null)] | length' "${OBSERVED_STATE}" 2>/dev/null || echo 0)" -eq "${expected}" ]; then
            return
        fi
        sleep 1
    done
    echo "Timed out waiting for resource telemetry for ${expected} worker slots." >&2
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

wait_for_slot_exit_classification() {
    slot_key="$1"
    expected_classification="$2"
    deadline=$((SECONDS + 60))
    while [ "${SECONDS}" -lt "${deadline}" ]; do
        observed_classification=$(jq -r \
            --arg key "${slot_key}" \
            '.slots[] | select(.key == $key) | .lastExit.classification // ""' \
            "${OBSERVED_STATE}" 2>/dev/null || true)
        if [ "${observed_classification}" = "${expected_classification}" ]; then
            return
        fi
        sleep 1
    done
    echo "Timed out waiting for slot ${slot_key} to report a ${expected_classification} exit." >&2
    return 1
}

run_setup() {
    workers="$1"
    pwsh -NoProfile -Command \
        "function Invoke-RestMethod { param(\$Method, \$Uri, \$Headers, \$ErrorAction) [pscustomobject]@{ token = 'integration-registration-token' } }; & '${POWERSHELL_ROOT}\\Setup-Runner.ps1' -ProfilePath '${POWERSHELL_PROFILE_PATH}' -Token 'integration-token' -Repos '${REPOSITORY_URL}=${workers}'"
}

run_refresh() {
    pwsh -NoProfile -Command \
        "function Invoke-RestMethod { param(\$Method, \$Uri, \$Headers, \$ErrorAction) [pscustomobject]@{ token = 'integration-registration-token' } }; & '${POWERSHELL_ROOT}\\Setup-Runner.ps1' -ProfilePath '${POWERSHELL_PROFILE_PATH}' -Token 'integration-token' -Refresh -Repos '${REPOSITORY_URL}=5'"
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
        PITCREW_WORKER_REVISION="0000000000000000000000000000000000000000000000000000000000000000" \
        PITCREW_WORKER_IMAGE_ID="${FAKE_IMAGE_ID}" \
        PITCREW_WORKER_MEMORY_BYTES="536870912" \
        PITCREW_WORKER_MEMORY_SWAP_BYTES="1073741824" \
        PITCREW_WORKER_CPU_CORES="0.5" \
        PITCREW_WORKER_PIDS_LIMIT="512" \
        PITCREW_SESSION_OWNER="${LEGACY_PROFILE_NAME}" \
        PITCREW_ASSUME_UNVERSIONED_CURRENT="0" \
        PITCREW_STATE_DIR=".pitcrew-state/${LEGACY_PROFILE_NAME}" \
        PITCREW_MANAGER_CONTRACT_VERSION="12" \
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
        "& '${POWERSHELL_ROOT}\\Setup-Runner.ps1' -ProfilePath '${POWERSHELL_PROFILE_PATH}' -Down" >/dev/null 2>&1 || true
    stop_legacy_compose >/dev/null 2>&1 || true
    docker ps -aq --filter "label=${PROFILE_LABEL}" |
        xargs -r docker rm -f >/dev/null 2>&1 || true
    docker ps -aq --filter "label=${LEGACY_PROFILE_LABEL}" |
        xargs -r docker rm -f >/dev/null 2>&1 || true
    docker rm -f "${SERVICE_CONTAINER}" >/dev/null 2>&1 || true
    docker network rm "${SERVICE_NETWORK}" >/dev/null 2>&1 || true
    docker image rm -f "${FAKE_IMAGE}" >/dev/null 2>&1 || true
    docker volume rm "${VOLUME_NAME}" >/dev/null 2>&1 || true
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
  "disableDefaultLabels": true,
  "readOnlyVolumes": [
    {
      "name": "reference-data",
      "source": "${VOLUME_NAME}"
    }
  ],
  "serviceNetwork": {
    "source": "${SERVICE_NETWORK}"
  },
  "verificationCommands": [
    "test -f /mnt/pitcrew-data/reference-data/marker.txt",
    "test \"\$(wget -qO- http://package-mirror:8080/health)\" = \"ready\""
  ]
}
EOF

docker build \
    --tag "${FAKE_IMAGE}" \
    "${ROOT}/tests/integration/fake-runner"
FAKE_IMAGE_ID=$(docker image inspect --format '{{.Id}}' "${FAKE_IMAGE}")
docker volume create "${VOLUME_NAME}" >/dev/null
docker run \
    --rm \
    --mount "type=volume,src=${VOLUME_NAME},dst=/data" \
    --entrypoint /bin/sh \
    "${FAKE_IMAGE}" \
    -c "printf 'verified\n' > /data/marker.txt"
docker network create --driver bridge "${SERVICE_NETWORK}" >/dev/null
docker run \
    --detach \
    --name "${SERVICE_CONTAINER}" \
    --network "${SERVICE_NETWORK}" \
    --network-alias package-mirror \
    --env PITCREW_FAKE_SERVICE=1 \
    "${FAKE_IMAGE}" \
    >/dev/null

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

legacy_worker_sample=$(docker ps -q --filter "label=${LEGACY_PROFILE_LABEL}" | head -n 1)
if docker exec "${legacy_worker_sample}" wget -qO- http://package-mirror:8080/health >/dev/null 2>&1; then
    echo "A worker without serviceNetwork resolved the profile-scoped service alias." >&2
    exit 1
fi
[ "$(docker inspect --format '{{.HostConfig.Memory}}' "${legacy_worker_sample}")" -eq 536870912 ] || {
    echo "The configured memory limit did not reach the worker container." >&2
    exit 1
}
[ "$(docker inspect --format '{{.HostConfig.MemorySwap}}' "${legacy_worker_sample}")" -eq 1073741824 ] || {
    echo "The configured memory-swap limit did not reach the worker container." >&2
    exit 1
}
[ "$(docker inspect --format '{{.HostConfig.NanoCpus}}' "${legacy_worker_sample}")" -eq 500000000 ] || {
    echo "The configured CPU limit did not reach the worker container." >&2
    exit 1
}
[ "$(docker inspect --format '{{.HostConfig.PidsLimit}}' "${legacy_worker_sample}")" -eq 512 ] || {
    echo "The configured PID limit did not reach the worker container." >&2
    exit 1
}
legacy_policy_deadline=$((SECONDS + 60))
while [ "${SECONDS}" -lt "${legacy_policy_deadline}" ]; do
    [ -f "${LEGACY_OBSERVED_STATE}" ] &&
        [ "$(jq -r '.resourcePolicy.memoryBytes // 0' "${LEGACY_OBSERVED_STATE}")" -eq 536870912 ] &&
        break
    sleep 1
done
[ "$(jq -r '.resourcePolicy.memoryBytes' "${LEGACY_OBSERVED_STATE}")" -eq 536870912 ] || {
    echo "Observed state did not publish the configured memory policy." >&2
    exit 1
}
[ "$(jq -r '.resourcePolicy.memorySwapBytes' "${LEGACY_OBSERVED_STATE}")" -eq 1073741824 ] || {
    echo "Observed state did not publish the configured memory-swap policy." >&2
    exit 1
}
[ "$(jq -r '.resourcePolicy.cpuCores' "${LEGACY_OBSERVED_STATE}")" = "0.5" ] || {
    echo "Observed state did not publish the canonical CPU policy." >&2
    exit 1
}
[ "$(jq -r '.resourcePolicy.pids' "${LEGACY_OBSERVED_STATE}")" -eq 512 ] || {
    echo "Observed state did not publish the configured PID policy." >&2
    exit 1
}

stop_legacy_compose
wait_for_legacy_worker_count 2
docker ps -q --filter "label=${LEGACY_PROFILE_LABEL}" |
    xargs -r docker rm -f >/dev/null
wait_for_legacy_worker_count 0

run_setup 5
wait_for_acknowledgement 1
wait_for_observed_generation 1 accepted
wait_for_worker_count 5
wait_for_resource_slot_count 5
manager_image_kib=$(docker run \
    --rm \
    --entrypoint /bin/sh \
    "ephemeral-runner-manager:profile-${PROFILE_NAME}" \
    -c "du -sk / 2>/dev/null | awk '{ print \$1 }'")
[ "${manager_image_kib}" -le 61440 ] || {
    echo "Manager filesystem is ${manager_image_kib} KiB; expected at most 60 MiB." >&2
    exit 1
}
echo "Manager filesystem size: ${manager_image_kib} KiB"
MANAGER_ID=$(manager_id)
[ -n "${MANAGER_ID}" ] || {
    echo "Runner manager did not start." >&2
    exit 1
}
[ "$(jq -r '.managerContractVersion' "${OBSERVED_STATE}")" -eq 12 ] || {
    echo "Observed state did not report manager contract version twelve." >&2
    exit 1
}
[ "$(jq -r '.profileId' "${OBSERVED_STATE}")" = "${PROFILE_NAME}" ] || {
    echo "Observed state was not isolated to the integration profile." >&2
    exit 1
}
[ "$(jq -r '.desiredSlots' "${OBSERVED_STATE}")" -eq 5 ] || {
    echo "Observed state did not report five desired slots." >&2
    exit 1
}
[ "$(jq -r '.resourceTelemetry.status' "${OBSERVED_STATE}")" = "available" ] || {
    echo "Observed state did not report available resource telemetry." >&2
    exit 1
}
[ "$(jq -r '.resourceTelemetry.host.logicalProcessorCount' "${OBSERVED_STATE}")" -gt 0 ] || {
    echo "Observed state did not report host processor capacity." >&2
    exit 1
}
[ "$(jq -r '.resourceTelemetry.manager.memoryWorkingSetBytes' "${OBSERVED_STATE}")" -gt 0 ] || {
    echo "Observed state did not report manager memory usage." >&2
    exit 1
}
[ "$(jq '[.slots[].resources | select(. != null)] | length' "${OBSERVED_STATE}")" -eq 5 ] || {
    echo "Observed state did not report resources for every live worker." >&2
    exit 1
}
manager_full_id=$(docker inspect --format '{{.Id}}' "${MANAGER_ID}")
docker network inspect --format '{{json .Containers}}' "${SERVICE_NETWORK}" |
    jq -e --arg manager "${manager_full_id}" 'has($manager) | not' >/dev/null || {
    echo "The socket-owning manager joined the worker service network." >&2
    exit 1
}
for worker_id in $(worker_ids); do
    docker inspect --format '{{json .NetworkSettings.Networks}}' "${worker_id}" |
        jq -e --arg network "${SERVICE_NETWORK}" 'has($network)' >/dev/null || {
        echo "Worker ${worker_id} did not join the configured service network." >&2
        exit 1
    }
done
service_worker=$(worker_ids | head -n 1)
[ "$(docker exec "${service_worker}" wget -qO- http://package-mirror:8080/health)" = "ready" ] || {
    echo "A managed worker could not reach the stable service alias." >&2
    exit 1
}
[ "$(jq '.eligibleSlots == ([.slots[] | select(.registrationStatus == "connected")] | length)' "${OBSERVED_STATE}")" = "true" ] || {
    echo "Observed state reported inconsistent GitHub-eligible capacity." >&2
    exit 1
}
mapfile -t original_workers < <(worker_ids)
[ "${#original_workers[@]}" -eq 5 ]
worker_mount=$(docker inspect \
    --format '{{json .Mounts}}' \
    "${original_workers[0]}")
[ "$(printf '%s' "${worker_mount}" | jq -r \
    --arg volume "${VOLUME_NAME}" \
    '[.[] | select(
        .Type == "volume"
        and .Name == $volume
        and .Destination == "/mnt/pitcrew-data/reference-data"
        and .RW == false)] | length')" -eq 1 ] || {
    echo "Worker did not receive the required external volume read-only." >&2
    exit 1
}

[ "$(jq -r --arg imageId "${FAKE_IMAGE_ID}" \
    '[.slots[] | select(.imageId == $imageId)] | length' "${OBSERVED_STATE}")" -eq 5 ] || {
    echo "Observed state did not tie every worker slot to the exact local image identity." >&2
    exit 1
}
[ "$(jq -r '.resourcePolicy' "${OBSERVED_STATE}")" = "null" ] || {
    echo "A profile without a resource policy published a policy object." >&2
    exit 1
}
[ "$(docker inspect --format '{{.HostConfig.Memory}}' "${original_workers[0]}")" -eq 0 ] || {
    echo "A profile without a resource policy applied a memory limit." >&2
    exit 1
}
[ "$(jq '[
        .slots[].resources
        | select(. != null)
        | select(
            has("networkRxBytes")
            and has("networkTxBytes")
            and has("blockReadBytes")
            and has("blockWriteBytes")
        )
    ] | length' "${OBSERVED_STATE}")" -eq 5 ] || {
    echo "Observed state did not publish I/O counters for every live worker." >&2
    exit 1
}
[ "$(jq '[
        .slots[].resources
        | select(. != null)
        | (.networkRxBytes, .networkTxBytes, .blockReadBytes, .blockWriteBytes)
        | select(. != null and . < 0)
    ] | length' "${OBSERVED_STATE}")" -eq 0 ] || {
    echo "Observed state published a negative I/O counter." >&2
    exit 1
}
[ "$(jq '[.slots[] | select(.lastExit != null)] | length' "${OBSERVED_STATE}")" -eq 0 ] || {
    echo "Freshly launched workers reported exit evidence." >&2
    exit 1
}

run_setup 6
wait_for_acknowledgement 2
wait_for_observed_generation 2 accepted
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
wait_for_observed_generation 3 accepted
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
wait_for_slot_exit_classification "${replacement_slot}" clean
[ "$(jq -r --arg key "${replacement_slot}" \
    '.slots[] | select(.key == $key) | .lastExit.exitCode' "${OBSERVED_STATE}")" -eq 0 ] || {
    echo "A graceful worker exit did not report a zero exit code." >&2
    exit 1
}

killed_source=$(slot_container_id "${replacement_slot}")
docker kill --signal KILL "${killed_source}" >/dev/null
wait_for_slot_replacement "${replacement_slot}" "${killed_source}"
wait_for_worker_count 5
wait_for_slot_exit_classification "${replacement_slot}" sigkill
[ "$(jq -r --arg key "${replacement_slot}" \
    '.slots[] | select(.key == $key) | .lastExit.exitCode' "${OBSERVED_STATE}")" -eq 137 ] || {
    echo "A killed worker did not report its Docker exit status." >&2
    exit 1
}
[ "$(jq -r --arg key "${replacement_slot}" \
    '.slots[] | select(.key == $key) | .lastExit.dockerOomKilled' "${OBSERVED_STATE}")" != "true" ] || {
    echo "Status 137 was reported as an out-of-memory kill without Docker evidence." >&2
    exit 1
}
[ "$(jq -r --arg key "${replacement_slot}" \
    '.slots[] | select(.key == $key) | .lastExit.signal' "${OBSERVED_STATE}")" -eq 9 ] || {
    echo "A killed worker did not report its terminating signal." >&2
    exit 1
}

jq '.generation = 2' "${ACKNOWLEDGEMENT}" > "${ACKNOWLEDGEMENT}.stale"
mv -f "${ACKNOWLEDGEMENT}.stale" "${ACKNOWLEDGEMENT}"
graceful_shutdowns_before=$(docker logs "${MANAGER_ID}" 2>&1 |
    grep -c 'Graceful runner deregistration' || true)
manager_instance_before_restart=$(jq -r '.managerInstanceId' "${OBSERVED_STATE}")
mapfile -t workers_before_manager_restart < <(worker_ids)
docker restart --timeout 60 "${MANAGER_ID}" >/dev/null
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
    manager_instance_after_restart=$(jq -r '.managerInstanceId // ""' "${OBSERVED_STATE}" 2>/dev/null || true)
    if [ "${restored}" -gt 0 ] &&
        [ "${#restart_slots[@]}" -eq 5 ] &&
        [ -n "${manager_instance_after_restart}" ] &&
        [ "${manager_instance_after_restart}" != "${manager_instance_before_restart}" ]; then
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
mapfile -t workers_after_manager_restart < <(worker_ids)
[ "${workers_before_manager_restart[*]}" = "${workers_after_manager_restart[*]}" ] || {
    echo "Manager restart replaced workers instead of adopting them." >&2
    exit 1
}
graceful_shutdowns_after=$(docker logs "${MANAGER_ID}" 2>&1 |
    grep -c 'Graceful runner deregistration' || true)
[ $((graceful_shutdowns_after - graceful_shutdowns_before)) -eq 0 ] || {
    echo "Manager restart deregistered workers during handoff." >&2
    exit 1
}
[ "$(jq '.eligibleSlots == ([.slots[] | select(.registrationStatus == "connected")] | length)' "${OBSERVED_STATE}")" = "true" ] || {
    echo "Recovered workers reported inconsistent GitHub-eligible capacity." >&2
    exit 1
}
[ "$(jq '[.slots[] | select(.state == "online" and .registrationStatus != "connected")] | length' "${OBSERVED_STATE}")" -eq 0 ] || {
    echo "Manager recovery reported an online slot without authoritative GitHub connectivity." >&2
    exit 1
}

[ "$(jq '[.slots[] | select(.lastExit != null)] | length' "${OBSERVED_STATE}")" -eq 0 ] || {
    echo "Manager recovery replayed stale exit evidence for adopted workers." >&2
    exit 1
}

mapfile -t workers_before_refresh < <(worker_ids)
manager_before_refresh=$(manager_id)
run_refresh
wait_for_acknowledgement 3
wait_for_worker_count 5
manager_after_refresh=$(manager_id)
[ -n "${manager_after_refresh}" ] && [ "${manager_after_refresh}" != "${manager_before_refresh}" ] || {
    echo "Manager refresh did not replace the manager container." >&2
    exit 1
}
mapfile -t workers_after_refresh < <(worker_ids)
[ "${workers_before_refresh[*]}" = "${workers_after_refresh[*]}" ] || {
    echo "Manager refresh replaced workers instead of handing them off." >&2
    exit 1
}
docker volume inspect "${VOLUME_NAME}" >/dev/null || {
    echo "Manager refresh removed the operator-owned external volume." >&2
    exit 1
}
docker network inspect "${SERVICE_NETWORK}" >/dev/null || {
    echo "Manager refresh removed the operator-owned external service network." >&2
    exit 1
}
MANAGER_ID="${manager_after_refresh}"

mapfile -t workers_before_invalid_state < <(worker_ids)
printf '{"schemaVersion":1,"generation":4' > "${DESIRED_STATE}"
wait_for_observed_generation 3 invalid
mapfile -t workers_after_invalid_state < <(worker_ids)
[ "${workers_before_invalid_state[*]}" = "${workers_after_invalid_state[*]}" ] || {
    echo "Malformed desired state churned a healthy worker pool." >&2
    exit 1
}

echo "Real Docker capacity reconciliation passed."
