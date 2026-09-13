#!/bin/bash
set -euo pipefail

SOURCE_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
RUN_ID="${GITHUB_RUN_ID:-$$}"
PROFILE_NAME="adoption-${RUN_ID}"
NAMESPACE="adoption-${RUN_ID}"
REPOSITORY_URL="https://github.com/example/adoption"
FAKE_IMAGE="pitcrew-fake-adoption:${RUN_ID}"
MANAGER_LABEL="ephemeral-runner-manager-profile=${PROFILE_NAME}"
WORKER_LABEL="ephemeral-managed-runner-profile=${PROFILE_NAME}"
ADMISSION_LABEL="pitcrew-host-admission-namespace=${NAMESPACE}"
SOCKET="/var/lib/pitcrew-admission/coordinator.sock"
TEMP_DIRECTORY=$(mktemp -d)
TEST_ROOT="${TEMP_DIRECTORY}/repo"
PROFILE_PATH="${TEST_ROOT}/profile.json"
STATE_DIRECTORY="${TEST_ROOT}/.pitcrew-state/${PROFILE_NAME}"
ACKNOWLEDGEMENT="${STATE_DIRECTORY}/acknowledged-capacity.json"
OBSERVED_STATE="${STATE_DIRECTORY}/observed-state.json"
RELEASE_ADOPTION="${STATE_DIRECTORY}/release-adoption"
REFRESH_LOG="${TEMP_DIRECTORY}/refresh.log"
REFRESH_PID=""

fail() {
    echo "ERROR: $1" >&2
    exit 1
}

manager_id() {
    docker ps -q --filter "label=${MANAGER_LABEL}"
}

worker_ids() {
    docker ps -q --filter "label=${WORKER_LABEL}" | sort
}

coordinator_id() {
    docker ps -q --filter "label=${ADMISSION_LABEL}"
}

coordinator_status() {
    docker run \
        --rm \
        --mount "type=volume,src=pitcrew-host-admission-${NAMESPACE},dst=/var/lib/pitcrew-admission" \
        --entrypoint /usr/local/bin/pitcrew-admission \
        "ephemeral-runner-manager:host-admission" \
        status \
        --socket "${SOCKET}"
}

run_setup() {
    pwsh -NoProfile -Command \
        "function Invoke-RestMethod { param(\$Method, \$Uri, \$Headers, \$ErrorAction) [pscustomobject]@{ token = 'integration-registration-token' } }; & '${TEST_ROOT}/Setup-Runner.ps1' -ProfilePath '${PROFILE_PATH}' -Token 'integration-token' -Repos '${REPOSITORY_URL}=1'"
}

run_refresh() {
    pwsh -NoProfile -Command \
        "function Invoke-RestMethod { param(\$Method, \$Uri, \$Headers, \$ErrorAction) [pscustomobject]@{ token = 'integration-registration-token' } }; & '${TEST_ROOT}/Setup-Runner.ps1' -ProfilePath '${PROFILE_PATH}' -Refresh -Repos '${REPOSITORY_URL}=1'"
}

wait_for_initial_state() {
    deadline=$((SECONDS + 120))
    while [ "${SECONDS}" -lt "${deadline}" ]; do
        if [ -f "${ACKNOWLEDGEMENT}" ] &&
            [ -f "${OBSERVED_STATE}" ] &&
            [ "$(jq -r '.generation // 0' "${ACKNOWLEDGEMENT}" 2>/dev/null || echo 0)" -eq 1 ] &&
            [ "$(jq -r '.managerStatus // ""' "${OBSERVED_STATE}" 2>/dev/null || true)" = "running" ] &&
            [ "$(worker_ids | wc -l | tr -d ' ')" -eq 1 ] &&
            coordinator_status |
                jq -e \
                    --arg profile "${PROFILE_NAME}" \
                    '[(.adoptionFences // [])[] | select(.profileId == $profile)] | length == 0' \
                    >/dev/null 2>&1; then
            return
        fi
        sleep 1
    done
    echo "Acknowledgement:" >&2
    cat "${ACKNOWLEDGEMENT}" >&2 2>/dev/null || true
    echo "Observed state:" >&2
    cat "${OBSERVED_STATE}" >&2 2>/dev/null || true
    echo "Manager containers:" >&2
    docker ps --filter "label=${MANAGER_LABEL}" >&2 || true
    echo "Worker containers:" >&2
    docker ps --filter "label=${WORKER_LABEL}" >&2 || true
    echo "Coordinator status:" >&2
    coordinator_status >&2 2>/dev/null || true
    fail "Initial fixed profile did not reach a healthy one-worker state."
}

wait_for_stalled_adoption_evidence() {
    previous_manager="$1"
    previous_instance="$2"
    deadline=$((SECONDS + 75))
    while [ "${SECONDS}" -lt "${deadline}" ]; do
        current_manager=$(manager_id)
        if [ -n "${current_manager}" ] &&
            [ "$(printf '%s\n' "${current_manager}" | wc -l | tr -d ' ')" -eq 1 ] &&
            [ "${current_manager}" != "${previous_manager}" ] &&
            [ -f "${ACKNOWLEDGEMENT}" ] &&
            [ -f "${OBSERVED_STATE}" ] &&
            [ "$(jq -r '.generation // 0' "${ACKNOWLEDGEMENT}" 2>/dev/null || echo 0)" -eq 1 ] &&
            [ "$(jq -r '.managerStatus // ""' "${OBSERVED_STATE}" 2>/dev/null || true)" = "running" ] &&
            [ "$(jq -r '.hostAdmission.status // ""' "${OBSERVED_STATE}" 2>/dev/null || true)" = "degraded" ] &&
            [ "$(jq -r '.managerInstanceId // ""' "${OBSERVED_STATE}" 2>/dev/null || true)" != "${previous_instance}" ] &&
            jq -e '
                (.operationJournal.events // [])
                | any(
                    .operation == "manager-start"
                    and .outcome == "timed-out"
                    and .reason == "timeout"
                )
            ' "${OBSERVED_STATE}" >/dev/null 2>&1 &&
            find "${STATE_DIRECTORY}/host-admission-adoptions" \
                -maxdepth 1 \
                -type f \
                -name '*.pending' |
                grep -q .; then
            return
        fi
        if ! kill -0 "${REFRESH_PID}" 2>/dev/null; then
            cat "${REFRESH_LOG}" >&2 || true
            fail "Refresh exited before publishing bounded stalled-adoption evidence."
        fi
        sleep 1
    done
    cat "${REFRESH_LOG}" >&2 || true
    fail "Replacement manager did not acknowledge and publish degraded adoption evidence."
}

wait_for_refresh_completion() {
    deadline=$((SECONDS + 75))
    while kill -0 "${REFRESH_PID}" 2>/dev/null; do
        [ "${SECONDS}" -lt "${deadline}" ] || {
            cat "${REFRESH_LOG}" >&2 || true
            fail "Refresh did not complete after the adoption stall was released."
        }
        sleep 1
    done
    set +e
    wait "${REFRESH_PID}"
    refresh_status=$?
    set -e
    REFRESH_PID=""
    if [ "${refresh_status}" -ne 0 ]; then
        cat "${REFRESH_LOG}" >&2 || true
        fail "Refresh failed after the adoption stall was released."
    fi
}

wait_for_converged_admission() {
    deadline=$((SECONDS + 60))
    while [ "${SECONDS}" -lt "${deadline}" ]; do
        if coordinator_status |
            jq -e \
                --arg profile "${PROFILE_NAME}" \
                '[(.adoptionFences // [])[] | select(.profileId == $profile)] | length == 0' \
                >/dev/null 2>&1 &&
            [ "$(jq -r '.hostAdmission.status // ""' "${OBSERVED_STATE}" 2>/dev/null || true)" = "available" ]; then
            return
        fi
        sleep 1
    done
    fail "Released adoption did not converge to available."
}

wait_for_worker_replacement() {
    previous_worker="$1"
    deadline=$((SECONDS + 60))
    while [ "${SECONDS}" -lt "${deadline}" ]; do
        replacement=$(worker_ids)
        if [ -n "${replacement}" ] &&
            [ "$(printf '%s\n' "${replacement}" | wc -l | tr -d ' ')" -eq 1 ] &&
            [ "${replacement}" != "${previous_worker}" ]; then
            return
        fi
        sleep 1
    done
    fail "Desired fixed worker was not replaced after its clean exit."
}

cleanup() {
    status=$?
    if [ -d "${STATE_DIRECTORY}" ]; then
        : > "${RELEASE_ADOPTION}"
    fi
    if [ -n "${REFRESH_PID}" ] && kill -0 "${REFRESH_PID}" 2>/dev/null; then
        kill "${REFRESH_PID}" 2>/dev/null || true
        wait "${REFRESH_PID}" 2>/dev/null || true
    fi
    if [ "${status}" -ne 0 ]; then
        cat "${REFRESH_LOG}" >&2 2>/dev/null || true
        current_manager=$(manager_id)
        [ -z "${current_manager}" ] || docker logs "${current_manager}" >&2 2>&1 || true
        current_coordinator=$(coordinator_id)
        [ -z "${current_coordinator}" ] || docker logs "${current_coordinator}" >&2 2>&1 || true
    fi
    if [ -f "${PROFILE_PATH}" ]; then
        pwsh -NoProfile -Command \
            "& '${TEST_ROOT}/Setup-Runner.ps1' -ProfilePath '${PROFILE_PATH}' -Down" \
            >/dev/null 2>&1 || true
    fi
    docker ps -aq --filter "label=${WORKER_LABEL}" |
        xargs -r docker rm -f >/dev/null 2>&1 || true
    docker ps -aq --filter "label=${MANAGER_LABEL}" |
        xargs -r docker rm -f >/dev/null 2>&1 || true
    docker ps -aq --filter "label=${ADMISSION_LABEL}" |
        xargs -r docker rm -f >/dev/null 2>&1 || true
    docker volume rm "pitcrew-host-admission-${NAMESPACE}" >/dev/null 2>&1 || true
    docker image rm -f "${FAKE_IMAGE}" >/dev/null 2>&1 || true
    docker image rm -f "ephemeral-runner-manager:profile-${PROFILE_NAME}" >/dev/null 2>&1 || true
    docker image rm -f "ephemeral-runner-manager:host-admission" >/dev/null 2>&1 || true
    rm -rf "${TEMP_DIRECTORY}"
    trap - EXIT
    exit "${status}"
}
trap cleanup EXIT

mkdir -p "${TEST_ROOT}"
git -C "${SOURCE_ROOT}" archive HEAD | tar -x -C "${TEST_ROOT}"

STALL_CLI="${TEST_ROOT}/tests/integration/pitcrew-admission-stall"
cat > "${STALL_CLI}" <<'EOF'
#!/bin/sh
set -u

if [ "${1:-}" = "adopt" ]; then
    while [ ! -f /var/lib/pitcrew/release-adoption ]; do
        sleep 1
    done
fi
exec /usr/local/bin/pitcrew-admission "$@"
EOF
chmod 0755 "${STALL_CLI}"

cat > "${TEST_ROOT}/host-admission.manager.compose.yml" <<EOF
services:
  runner-manager:
    environment:
      PITCREW_HOST_ADMISSION_NAMESPACE: \${PITCREW_HOST_ADMISSION_NAMESPACE}
      PITCREW_HOST_ADMISSION_SOCKET: \${PITCREW_HOST_ADMISSION_SOCKET}
      PITCREW_HOST_ADMISSION_HOST_FINGERPRINT: \${PITCREW_HOST_ADMISSION_HOST_FINGERPRINT}
      PITCREW_HOST_ADMISSION_PROFILE_FINGERPRINT: \${PITCREW_HOST_ADMISSION_PROFILE_FINGERPRINT}
      PITCREW_HOST_ADMISSION_CLI: /usr/local/bin/pitcrew-admission-stall
    volumes:
      - host-admission-state:/var/lib/pitcrew-admission
      - ${STALL_CLI}:/usr/local/bin/pitcrew-admission-stall:ro

volumes:
  host-admission-state:
    external: true
    name: \${PITCREW_HOST_ADMISSION_VOLUME}
EOF

cat > "${PROFILE_PATH}" <<EOF
{
  "schemaVersion": 1,
  "name": "${PROFILE_NAME}",
  "description": "Hosted fixed-manager adoption startup integration profile.",
  "image": "${FAKE_IMAGE}",
  "labels": ["integration"],
  "replicas": 1,
  "pullImage": false,
  "disableDefaultLabels": true,
  "hostAdmission": {
    "namespace": "${NAMESPACE}",
    "capacityUnits": 2,
    "safetyMarginUnits": 0,
    "workerCostUnits": 1,
    "reservationUnits": 0,
    "borrowable": true
  }
}
EOF

docker build \
    --tag "${FAKE_IMAGE}" \
    "${TEST_ROOT}/tests/integration/fake-runner"

run_setup
wait_for_initial_state

manager_before=$(manager_id)
worker_before=$(worker_ids)
instance_before=$(jq -r '.managerInstanceId' "${OBSERVED_STATE}")
[ -n "${manager_before}" ] &&
    [ "$(printf '%s\n' "${manager_before}" | wc -l | tr -d ' ')" -eq 1 ] ||
    fail "Initial manager identity is unavailable or ambiguous."
[ -n "${worker_before}" ] &&
    [ "$(printf '%s\n' "${worker_before}" | wc -l | tr -d ' ')" -eq 1 ] ||
    fail "Initial worker identity is unavailable or ambiguous."

rm -f "${RELEASE_ADOPTION}"
run_refresh > "${REFRESH_LOG}" 2>&1 &
REFRESH_PID=$!

wait_for_stalled_adoption_evidence "${manager_before}" "${instance_before}"
manager_after=$(manager_id)
[ "$(worker_ids)" = "${worker_before}" ] ||
    fail "Stalled adoption replaced or removed the active worker."
coordinator_status |
    jq -e \
        --arg profile "${PROFILE_NAME}" \
        '
            [.leases[] | select(.profileId == $profile and .status == "active")]
            | length == 1
        ' >/dev/null ||
    fail "Stalled adoption changed the exact active lease."
coordinator_status |
    jq -e \
        --arg profile "${PROFILE_NAME}" \
        '
            [.adoptionFences[] | select(
                .profileId == $profile
                and (.pendingLeaseKeys | length) == 1
            )]
            | length == 1
        ' >/dev/null ||
    fail "Stalled adoption did not preserve the exact profile fence."

: > "${RELEASE_ADOPTION}"
wait_for_refresh_completion
wait_for_converged_admission
[ "$(worker_ids)" = "${worker_before}" ] ||
    fail "Completed adoption replaced the preserved worker."

docker stop --time 2 "${worker_before}" >/dev/null
wait_for_worker_replacement "${worker_before}"
coordinator_status |
    jq -e \
        --arg profile "${PROFILE_NAME}" \
        '
            [.leases[] | select(.profileId == $profile and .status == "active")]
            | length == 1
        ' >/dev/null ||
    fail "Replacement worker did not retain exact one-worker lease parity."
[ "$(manager_id)" = "${manager_after}" ] ||
    fail "Worker replacement changed the qualified replacement manager."
[ "$(jq -r '.generation // 0' "${ACKNOWLEDGEMENT}")" -eq 1 ] ||
    fail "Adoption recovery changed the accepted desired generation."

echo "Fixed-manager adoption startup integration passed."
