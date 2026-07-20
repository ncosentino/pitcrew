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
OBSERVED_STATE="${STATE_DIRECTORY}/observed-state.json"
LEGACY_STATE_DIRECTORY="${ROOT}/.pitcrew-state/${LEGACY_PROFILE_NAME}"
LEGACY_DESIRED_STATE="${LEGACY_STATE_DIRECTORY}/desired-capacity.json"
LEGACY_COMPOSE_PROJECT="self-hosted-runner-${LEGACY_PROFILE_NAME}"
UPGRADE_PROFILE_NAME="upgrade-${RUN_ID}"
UPGRADE_PROFILE_LABEL="ephemeral-managed-runner-profile=${UPGRADE_PROFILE_NAME}"
UPGRADE_MANAGER_LABEL="ephemeral-runner-manager-profile=${UPGRADE_PROFILE_NAME}"
UPGRADE_STATE_DIRECTORY="${ROOT}/.pitcrew-state/${UPGRADE_PROFILE_NAME}"
UPGRADE_OBSERVED_STATE="${UPGRADE_STATE_DIRECTORY}/observed-state.json"
UPGRADE_ACK="${UPGRADE_STATE_DIRECTORY}/acknowledged-capacity.json"
UPGRADE_COMPOSE_PROJECT="self-hosted-runner-${UPGRADE_PROFILE_NAME}"
FIXTURE_DIRECTORY=$(mktemp -d)
PROFILE_PATH="${FIXTURE_DIRECTORY}/profile.json"
UPGRADE_PROFILE_PATH="${FIXTURE_DIRECTORY}/upgrade-profile.json"
V6_ROOT=""
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
    if [ -f "${UPGRADE_PROFILE_PATH}" ]; then
        pwsh -NoProfile -Command \
            "& '${ROOT}/Setup-Runner.ps1' -ProfilePath '${UPGRADE_PROFILE_PATH}' -Down" >/dev/null 2>&1 || true
    fi
    stop_legacy_compose >/dev/null 2>&1 || true
    docker ps -aq --filter "label=${PROFILE_LABEL}" |
        xargs -r docker rm -f >/dev/null 2>&1 || true
    docker ps -aq --filter "label=${LEGACY_PROFILE_LABEL}" |
        xargs -r docker rm -f >/dev/null 2>&1 || true
    docker ps -aq --filter "label=${UPGRADE_PROFILE_LABEL}" |
        xargs -r docker rm -f >/dev/null 2>&1 || true
    docker ps -aq --filter "label=${UPGRADE_MANAGER_LABEL}" |
        xargs -r docker rm -f >/dev/null 2>&1 || true
    docker image rm -f "${FAKE_IMAGE}" >/dev/null 2>&1 || true
    rm -f "${ROOT}/.env.${PROFILE_NAME}" "${ROOT}/.env.${UPGRADE_PROFILE_NAME}"
    rm -rf "${STATE_DIRECTORY}" "${LEGACY_STATE_DIRECTORY}" \
        "${UPGRADE_STATE_DIRECTORY}" "${FIXTURE_DIRECTORY}"
    [ -n "${V6_ROOT}" ] && rm -rf "${V6_ROOT}"
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
# Issue #8 follow-up (3): the direct-Compose path above sets no
# PITCREW_MANAGER_CONTRACT_VERSION override, so the manager booted only because
# docker-compose.yml defaults it to the current contract. A stale default would
# have tripped the manager's contract guard and no workers would exist.
LEGACY_OBSERVED_STATE="${LEGACY_STATE_DIRECTORY}/observed-state.json"
legacy_observed_deadline=$((SECONDS + 60))
while [ "${SECONDS}" -lt "${legacy_observed_deadline}" ]; do
    if [ -f "${LEGACY_OBSERVED_STATE}" ] &&
        [ "$(jq -r '.managerContractVersion // 0' "${LEGACY_OBSERVED_STATE}" 2>/dev/null || echo 0)" -eq 7 ]; then
        break
    fi
    sleep 1
done
[ "$(jq -r '.managerContractVersion // 0' "${LEGACY_OBSERVED_STATE}" 2>/dev/null || echo 0)" -eq 7 ] || {
    echo "Direct-Compose startup without an explicit contract override did not default to manager contract seven." >&2
    exit 1
}
stop_legacy_compose
wait_for_legacy_worker_count 0

run_setup 5
wait_for_acknowledgement 1
wait_for_observed_generation 1 accepted
wait_for_worker_count 5
manager_image_kib=$(docker run \
    --rm \
    --entrypoint /bin/sh \
    ephemeral-runner-manager:local \
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
[ "$(jq -r '.managerContractVersion' "${OBSERVED_STATE}")" -eq 7 ] || {
    echo "Observed state did not report manager contract version seven." >&2
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
mapfile -t original_workers < <(worker_ids)
[ "${#original_workers[@]}" -eq 5 ]

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

jq '.generation = 2' "${ACKNOWLEDGEMENT}" > "${ACKNOWLEDGEMENT}.stale"
mv -f "${ACKNOWLEDGEMENT}.stale" "${ACKNOWLEDGEMENT}"
graceful_shutdowns_before=$(docker logs "${MANAGER_ID}" 2>&1 |
    grep -c 'Graceful runner deregistration' || true)
docker restart --timeout 35 "${MANAGER_ID}" >/dev/null
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
graceful_shutdowns_after=$(docker logs "${MANAGER_ID}" 2>&1 |
    grep -c 'Graceful runner deregistration' || true)
[ $((graceful_shutdowns_after - graceful_shutdowns_before)) -eq 5 ] || {
    echo "Manager restart did not gracefully deregister all five workers." >&2
    exit 1
}

mapfile -t workers_before_invalid_state < <(worker_ids)
printf '{"schemaVersion":1,"generation":4' > "${DESIRED_STATE}"
wait_for_observed_generation 3 invalid
mapfile -t workers_after_invalid_state < <(worker_ids)
[ "${workers_before_invalid_state[*]}" = "${workers_after_invalid_state[*]}" ] || {
    echo "Malformed desired state churned a healthy worker pool." >&2
    exit 1
}

echo "Real Docker capacity reconciliation passed."

# ===== Issue #8 follow-up (1): genuine real-Docker v6 -> v7 manager upgrade =====
# The reviewer's blocking concern was that the earlier idle signal counted the
# persistent slot supervisors, so a v6->v7 upgrade could never observe an idle
# pool and would churn (lose) workers. This scenario proves the fix end to end
# against real Docker: a genuine v6 manager (built from the v6 commit) supervises
# a real worker container, and the current (v7) tooling upgrades it IN PLACE via
# the drain-and-fence path, recreating ONLY the manager while the worker
# container survives with an unchanged id.
cat > "${UPGRADE_PROFILE_PATH}" <<EOF
{
  "schemaVersion": 1,
  "name": "${UPGRADE_PROFILE_NAME}",
  "description": "Isolated real-Docker v6 to v7 upgrade profile.",
  "image": "${FAKE_IMAGE}",
  "labels": ["integration"],
  "replicas": 1,
  "pullImage": false,
  "disableDefaultLabels": true
}
EOF

V6_ROOT=$(mktemp -d)
V6_COMMIT="f053db1"
if ! git -C "${ROOT}" cat-file -e "${V6_COMMIT}^{commit}" 2>/dev/null; then
    git -C "${ROOT}" fetch --depth 1 origin "${V6_COMMIT}" 2>/dev/null || true
fi
if ! git -C "${ROOT}" cat-file -e "${V6_COMMIT}^{commit}" 2>/dev/null; then
    echo "ERROR: v6 baseline commit ${V6_COMMIT} is not available; a full-history checkout (fetch-depth: 0) is required for the v6->v7 upgrade scenario." >&2
    exit 1
fi
git -C "${ROOT}" archive "${V6_COMMIT}" | tar -x -C "${V6_ROOT}"

run_upgrade_setup() {
    pwsh -NoProfile -Command \
        "& '${ROOT}/Setup-Runner.ps1' -ProfilePath '${UPGRADE_PROFILE_PATH}' -Token 'integration-token' -Repos '${REPOSITORY_URL}=1'"
}

upgrade_manager_id() { docker ps -q --filter "label=${UPGRADE_MANAGER_LABEL}"; }
upgrade_worker_ids() { docker ps -q --filter "label=${UPGRADE_PROFILE_LABEL}" | sort; }
upgrade_worker_count() { upgrade_worker_ids | awk 'END { print NR + 0 }'; }

wait_for_upgrade_worker_count() {
    expected="$1"
    deadline=$((SECONDS + 90))
    while [ "${SECONDS}" -lt "${deadline}" ]; do
        if [ "$(upgrade_worker_count)" -eq "${expected}" ]; then
            return
        fi
        sleep 1
    done
    echo "Timed out waiting for ${expected} upgrade workers; found $(upgrade_worker_count)." >&2
    return 1
}

wait_for_upgrade_contract() {
    expected="$1"
    deadline=$((SECONDS + 90))
    while [ "${SECONDS}" -lt "${deadline}" ]; do
        if [ -f "${UPGRADE_OBSERVED_STATE}" ] &&
            [ "$(jq -r '.managerContractVersion // 0' "${UPGRADE_OBSERVED_STATE}" 2>/dev/null || echo 0)" -eq "${expected}" ]; then
            return
        fi
        sleep 1
    done
    echo "Timed out waiting for upgrade manager contract ${expected}." >&2
    return 1
}

wait_for_upgrade_ack() {
    expected="$1"
    deadline=$((SECONDS + 90))
    while [ "${SECONDS}" -lt "${deadline}" ]; do
        if [ -f "${UPGRADE_ACK}" ] &&
            [ "$(jq -r '.managerContractVersion // 0' "${UPGRADE_ACK}" 2>/dev/null || echo 0)" -eq "${expected}" ]; then
            return
        fi
        sleep 1
    done
    echo "Timed out waiting for upgrade manager to acknowledge contract ${expected}." >&2
    return 1
}

# 1. Provision with the CURRENT (v7) tooling: writes a v7 static-profile.json +
#    environment file + desired-capacity and boots a v7 manager supervising one
#    worker. This establishes the v7-fingerprinted static contract the later
#    upgrade matches against.
run_upgrade_setup
wait_for_upgrade_worker_count 1
wait_for_upgrade_contract 7
v7_manager_before=$(upgrade_manager_id)
[ -n "${v7_manager_before}" ] || {
    echo "The v7 upgrade-profile manager did not start." >&2
    exit 1
}

# 2. Replace ONLY the manager container with a genuine v6 manager built from the
#    v6 commit, over the SAME Compose project and state directory. The worker is
#    not a Compose service, so it keeps running; the v6 manager reconciles the
#    existing desired-capacity and republishes the pool as contract six.
#
#    The outgoing v7 manager already wrote an acknowledgement for the current
#    generation. v6's acknowledgement_matches_current only checks schemaVersion,
#    status and generation (NOT managerContractVersion), so it would treat that
#    v7 ack as still-current and never republish contract six. Remove the stale
#    ack so the v6 manager writes a fresh contract-six acknowledgement on its
#    boot reconcile -- which is also what the v7 upgrade path reads to detect the
#    running contract in step 3.
docker rm -f "${v7_manager_before}" >/dev/null
rm -f "${UPGRADE_ACK}"
(
    cd "${V6_ROOT}"
    ACCESS_TOKEN="integration-token" \
    REPO_URLS="${REPOSITORY_URL}=1" \
    REPO_URL="" \
    RUNNER_SCOPE="repo" \
    ORG_NAME="" \
    ENTERPRISE_NAME="" \
    RUNNER_REPLICAS="1" \
    RUNNER_IMAGE="${FAKE_IMAGE}" \
    RUNNER_PULL_IMAGE="0" \
    RUNNER_PROFILE_ID="${UPGRADE_PROFILE_NAME}" \
    RUNNER_NAME_PREFIX="${UPGRADE_PROFILE_NAME}" \
    RUNNER_LABELS="integration" \
    RUNNER_NO_DEFAULT_LABELS="1" \
    RUNNER_GROUP="" \
    PITCREW_STATE_DIR="${UPGRADE_STATE_DIRECTORY}" \
        docker compose \
            --file docker-compose.yml \
            --project-name "${UPGRADE_COMPOSE_PROJECT}" \
            up -d --build
)
wait_for_upgrade_contract 6
v6_manager=$(upgrade_manager_id)
[ -n "${v6_manager}" ] || {
    echo "The genuine v6 manager did not take over the upgrade profile." >&2
    exit 1
}
wait_for_upgrade_worker_count 1
wait_for_upgrade_ack 6 || {
    echo "The v6 manager did not acknowledge contract six." >&2
    exit 1
}
mapfile -t worker_under_v6 < <(upgrade_worker_ids)
[ "${#worker_under_v6[@]}" -eq 1 ] || {
    echo "The v6 manager did not stabilize on a single worker." >&2
    exit 1
}

# 3. Re-run the CURRENT (v7) tooling. It observes a running manager reporting
#    contract six with a matching v7 static contract, so it takes the drain-safe
#    IN-PLACE upgrade: the host-side idle probe confirms the worker is not
#    running a job, then only the manager is recreated (compose up
#    --force-recreate). The worker container MUST survive with its id unchanged.
run_upgrade_setup
wait_for_upgrade_contract 7
upgraded_manager=$(upgrade_manager_id)
[ -n "${upgraded_manager}" ] || {
    echo "The upgraded manager did not start." >&2
    exit 1
}
[ "${upgraded_manager}" != "${v6_manager}" ] || {
    echo "The v6->v7 upgrade did not recreate the manager onto the new contract." >&2
    exit 1
}
wait_for_upgrade_worker_count 1
mapfile -t worker_after_upgrade < <(upgrade_worker_ids)
[ "${worker_under_v6[*]}" = "${worker_after_upgrade[*]}" ] || {
    echo "The v6->v7 in-place upgrade churned the worker container (worker-loss regression)." >&2
    exit 1
}
assert_running "${worker_after_upgrade[0]}"
echo "Real Docker v6->v7 in-place manager upgrade preserved the worker pool."
