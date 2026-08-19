#!/usr/bin/env bash
set -euo pipefail

ROOT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SERVICE_SETUP="${ROOT_DIRECTORY}/services/image-builder/Setup-PitCrewImageBuilderService.ps1"
CERTIFICATE_SETUP="${ROOT_DIRECTORY}/services/image-builder/New-PitCrewBuildKitCertificates.ps1"
NETWORK_NAME="pitcrew-image-builder"
STATE_VOLUME="pitcrew-image-builder-state"
PROJECT_NAME="pitcrew-image-builder-service"
SERVICE_STATE_PATH="${ROOT_DIRECTORY}/.pitcrew-state/image-builder-service/service.json"
REGISTRY_NAME="pitcrew-registry-test-$$"
CLIENT_IMAGE="pitcrew-image-builder-test:$$"
INTERRUPT_CLIENT_ID=""
TEMP_DIRECTORY="$(mktemp -d)"
APPARMOR_RESTRICTION=""

cleanup() {
    certificate_volume=""
    if [[ -r "${SERVICE_STATE_PATH}" ]]; then
        certificate_volume="$(jq -r '.certificateVolume // empty' "${SERVICE_STATE_PATH}")"
    fi
    pwsh -NoProfile -File "${SERVICE_SETUP}" -Down >/dev/null 2>&1 || true
    docker container rm --force "${REGISTRY_NAME}" >/dev/null 2>&1 || true
    if [[ -n "${INTERRUPT_CLIENT_ID}" ]]; then
        docker container rm --force "${INTERRUPT_CLIENT_ID}" >/dev/null 2>&1 || true
    fi
    docker volume rm "${STATE_VOLUME}" >/dev/null 2>&1 || true
    if [[ -n "${certificate_volume}" ]]; then
        docker volume rm "${certificate_volume}" >/dev/null 2>&1 || true
    fi
    docker network rm "${NETWORK_NAME}" >/dev/null 2>&1 || true
    docker image rm "${CLIENT_IMAGE}" >/dev/null 2>&1 || true
    if [[ -n "${APPARMOR_RESTRICTION}" ]]; then
        sudo sysctl -w \
            "kernel.apparmor_restrict_unprivileged_userns=${APPARMOR_RESTRICTION}" \
            >/dev/null 2>&1 || true
    fi
    rm -rf "${ROOT_DIRECTORY}/.pitcrew-state/image-builder-service"
    rm -rf "${TEMP_DIRECTORY}"
}
trap cleanup EXIT

for command in docker pwsh; do
    command -v "${command}" >/dev/null || {
        echo "Required command is unavailable: ${command}" >&2
        exit 1
    }
done

if [[ -r /proc/sys/kernel/apparmor_restrict_unprivileged_userns ]]; then
    APPARMOR_RESTRICTION="$(
        cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns
    )"
    sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0 >/dev/null
fi

pwsh -NoProfile -File "${CERTIFICATE_SETUP}" \
    -OutputDirectory "${TEMP_DIRECTORY}/certificates" \
    -ValidDays 1 >/dev/null
SERVER_CERTIFICATE_DIRECTORY="${TEMP_DIRECTORY}/certificates/server"
CLIENT_CERTIFICATE_DIRECTORY="${TEMP_DIRECTORY}/certificates/client"
CONTEXT_DIRECTORY="${TEMP_DIRECTORY}/context"
INTERRUPT_DIRECTORY="${TEMP_DIRECTORY}/interrupt"
OUTPUT_DIRECTORY="${TEMP_DIRECTORY}/output"
mkdir -p "${CONTEXT_DIRECTORY}" "${INTERRUPT_DIRECTORY}" "${OUTPUT_DIRECTORY}"

cat > "${CONTEXT_DIRECTORY}/Dockerfile" <<'EOF'
# syntax=docker/dockerfile:1.7
FROM scratch
ARG PAYLOAD
LABEL org.opencontainers.image.test-payload="${PAYLOAD}"
COPY payload.txt /payload.txt
EOF
printf 'isolated-image-builder\n' > "${CONTEXT_DIRECTORY}/payload.txt"
cat > "${INTERRUPT_DIRECTORY}/Dockerfile" <<'EOF'
FROM alpine:3.22
# BuildKit may finish server-side work after an abrupt client disconnect.
# Keep the solve observable but shorter than the inactive-state wait below.
RUN sleep 30
EOF

pwsh -NoProfile -File "${SERVICE_SETUP}" \
    -ServerCertificateDirectory "${SERVER_CERTIFICATE_DIRECTORY}"
if [[ ! -r "${SERVICE_STATE_PATH}" ]]; then
    echo "Image-builder setup did not persist its exact certificate volume." >&2
    exit 1
fi
CERTIFICATE_VOLUME="$(jq -r '.certificateVolume' "${SERVICE_STATE_PATH}")"
if [[ ! "${CERTIFICATE_VOLUME}" =~ ^pitcrew-image-builder-certs-[0-9a-f]{16}$ ]]; then
    echo "Image-builder setup persisted an invalid certificate volume." >&2
    exit 1
fi

mapfile -t buildkit_ids < <(
    docker ps -q \
        --filter "label=com.docker.compose.project=${PROJECT_NAME}" \
        --filter 'label=com.docker.compose.service=buildkitd'
)
if ((${#buildkit_ids[@]} != 1)); then
    echo "Expected one rootless BuildKit service container." >&2
    exit 1
fi
BUILDKIT_ID="${buildkit_ids[0]}"
if [[ "$(docker inspect --format '{{.HostConfig.Privileged}}' "${BUILDKIT_ID}")" != "false" ]]; then
    echo "Rootless BuildKit service unexpectedly runs privileged." >&2
    exit 1
fi
if [[ "$(docker exec "${BUILDKIT_ID}" id -u)" != "1000" ]]; then
    echo "BuildKit service is not running as its rootless user." >&2
    exit 1
fi

docker run --detach \
    --name "${REGISTRY_NAME}" \
    --network "${NETWORK_NAME}" \
    --network-alias registry \
    registry:3.0.0@sha256:6c5666b861f3505b116bb9aa9b25175e71210414bd010d92035ff64018f9457e \
    >/dev/null

docker build \
    --file "${ROOT_DIRECTORY}/profiles/image-builder/Dockerfile" \
    --tag "${CLIENT_IMAGE}" \
    --build-arg BUILDKIT_VERSION=0.32.2 \
    --build-arg BUILDKIT_SHA256_X64=2975d0f651ad96ba8b80b9992ae1f9a964f4408569af5b6dc36544165c3926af \
    --build-arg BUILDKIT_SHA256_ARM64=9e8f46bf309ec0ab262967be5538a4dbe06be756a82621f98253933bac5dcf92 \
    --build-arg CRANE_VERSION=0.21.9 \
    --build-arg CRANE_SHA256_X64=5c16d8ddb971cb1d5e6ed8b1e743da8224414eeba2c2762d8f1a61b2f095699e \
    --build-arg CRANE_SHA256_ARM64=1f4c647b7bb260ab5435661df5b526cf59950ebf95201790db7183ac189cbcbd \
    "${ROOT_DIRECTORY}/profiles/image-builder" \
    >/dev/null

docker run --rm \
    --network "${NETWORK_NAME}" \
    --mount "type=bind,src=${CLIENT_CERTIFICATE_DIRECTORY},dst=/tls,readonly" \
    --entrypoint /bin/bash \
    "${CLIENT_IMAGE}" \
    -lc 'test ! -e /var/run/docker.sock && test ! -e /certs/server-key.pem'

if docker run --rm \
    --network "${NETWORK_NAME}" \
    --mount "type=bind,src=${CLIENT_CERTIFICATE_DIRECTORY},dst=/tls,readonly" \
    --entrypoint buildctl \
    "${CLIENT_IMAGE}" \
    --addr tcp://buildkitd:1234 \
    --tlsservername buildkitd \
    --tlscacert /tls/ca.pem \
    debug workers >/dev/null 2>&1; then
    echo "BuildKit accepted a client without an mTLS identity." >&2
    exit 1
fi

run_buildctl_client() {
    docker run --rm \
        --network "${NETWORK_NAME}" \
        --mount "type=bind,src=${CLIENT_CERTIFICATE_DIRECTORY},dst=/tls,readonly" \
        --entrypoint buildctl \
        "${CLIENT_IMAGE}" \
        --addr tcp://buildkitd:1234 \
        --tlsservername buildkitd \
        --tlsdir /tls \
        "$@"
}

INTERRUPT_CLIENT_ID="$(
    docker run --detach \
        --network "${NETWORK_NAME}" \
        --mount "type=bind,src=${CLIENT_CERTIFICATE_DIRECTORY},dst=/tls,readonly" \
        --mount "type=bind,src=${INTERRUPT_DIRECTORY},dst=/workspace,readonly" \
        --entrypoint buildctl \
        "${CLIENT_IMAGE}" \
        --addr tcp://buildkitd:1234 \
        --tlsservername buildkitd \
        --tlsdir /tls \
        build \
        --frontend dockerfile.v0 \
        --local context=/workspace \
        --local dockerfile=/workspace \
        --opt platform=linux/amd64 \
        --output type=oci,dest=/tmp/interrupted.tar \
        --progress plain
)"
recorded=false
for _ in $(seq 1 120); do
    histories="$(run_buildctl_client debug histories --format '{{json .}}')"
    usage="$(run_buildctl_client du --format '{{json .}}')"
    if [[ -n "${histories}" ]] &&
        [[ -n "${usage}" && "${usage}" != "null" ]]; then
        recorded=true
        break
    fi
    sleep 1
done
if [[ "${recorded}" != "true" ]]; then
    echo "Interrupted client did not publish BuildKit state." >&2
    exit 1
fi

docker kill --signal KILL "${INTERRUPT_CLIENT_ID}" >/dev/null
build_status="$(docker wait "${INTERRUPT_CLIENT_ID}")"
docker container rm "${INTERRUPT_CLIENT_ID}" >/dev/null
INTERRUPT_CLIENT_ID=""
if [[ "${build_status}" -eq 0 ]]; then
    echo "Interrupted client completed before its hard cancellation." >&2
    exit 1
fi

settled=false
for _ in $(seq 1 60); do
    usage="$(run_buildctl_client du --format '{{json .}}')"
    if jq -e \
        'type == "array" and
         length > 0 and
         all(.[]; .inUse == false)' \
        <<<"${usage}" \
        >/dev/null; then
        settled=true
        break
    fi
    sleep 1
done
if [[ "${settled}" != "true" ]]; then
    echo "BuildKit state did not settle after the client container was hard-cancelled." >&2
    exit 1
fi
seeded_cache="$(
    docker run --rm \
        --network "${NETWORK_NAME}" \
        --mount "type=bind,src=${CLIENT_CERTIFICATE_DIRECTORY},dst=/tls,readonly" \
        --entrypoint buildctl \
        "${CLIENT_IMAGE}" \
        --addr tcp://buildkitd:1234 \
        --tlsservername buildkitd \
        --tlsdir /tls \
        du --format '{{json .}}'
)"
if [[ -z "${seeded_cache}" || "${seeded_cache}" == "null" ]]; then
    echo "Interrupted-job fixture did not leave BuildKit state for preflight cleanup." >&2
    exit 1
fi
seeded_histories="$(
    docker run --rm \
        --network "${NETWORK_NAME}" \
        --mount "type=bind,src=${CLIENT_CERTIFICATE_DIRECTORY},dst=/tls,readonly" \
        --entrypoint buildctl \
        "${CLIENT_IMAGE}" \
        --addr tcp://buildkitd:1234 \
        --tlsservername buildkitd \
        --tlsdir /tls \
        debug histories \
        --format '{{json .}}'
)"
if [[ -z "${seeded_histories}" ]]; then
    echo "Interrupted-job fixture did not leave BuildKit history." >&2
    exit 1
fi

literal_payload='literal-$(touch /tmp/pitcrew-injection)'
published_reference="$(
    docker run --rm \
        --network "${NETWORK_NAME}" \
        --mount "type=bind,src=${CLIENT_CERTIFICATE_DIRECTORY},dst=/tls,readonly" \
        --mount "type=bind,src=${CONTEXT_DIRECTORY},dst=/workspace,readonly" \
        --env BUILDKIT_HOST=tcp://buildkitd:1234 \
        --env BUILDKIT_TLS_DIR=/tls \
        --entrypoint pitcrew-build-image \
        "${CLIENT_IMAGE}" \
        --image-ref registry:5000/pitcrew/image-builder-test:ci \
        --context /workspace \
        --dockerfile /workspace \
        --platform linux/amd64 \
        --build-arg "PAYLOAD=${literal_payload}" \
        --label org.opencontainers.image.revision=test-revision \
        --push \
        --verify-registry \
        --registry-insecure
)"
published_digest="${published_reference##*@}"
if [[ ! "${published_digest}" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    echo "Image-builder helper returned an invalid immutable reference: ${published_reference}" >&2
    exit 1
fi

published_config="$(
    docker run --rm \
        --network "${NETWORK_NAME}" \
        --entrypoint crane \
        "${CLIENT_IMAGE}" \
        config --insecure registry:5000/pitcrew/image-builder-test:ci
)"
if [[ "$(jq -r '.config.Labels["org.opencontainers.image.revision"]' <<<"${published_config}")" != "test-revision" ]] ||
    [[ "$(jq -r '.config.Labels["org.opencontainers.image.test-payload"]' <<<"${published_config}")" != "${literal_payload}" ]]; then
    echo "Build arguments or OCI labels did not survive literally." >&2
    exit 1
fi

oci_reference="$(
    docker run --rm \
        --network "${NETWORK_NAME}" \
        --mount "type=bind,src=${CLIENT_CERTIFICATE_DIRECTORY},dst=/tls,readonly" \
        --mount "type=bind,src=${CONTEXT_DIRECTORY},dst=/workspace,readonly" \
        --mount "type=bind,src=${OUTPUT_DIRECTORY},dst=/output" \
        --env BUILDKIT_HOST=tcp://buildkitd:1234 \
        --env BUILDKIT_TLS_DIR=/tls \
        --entrypoint pitcrew-build-image \
        "${CLIENT_IMAGE}" \
        --image-ref registry:5000/pitcrew/image-builder-test:verify \
        --context /workspace \
        --dockerfile /workspace \
        --platform linux/amd64 \
        --build-arg PAYLOAD=verification \
        --output-oci /output/verification.tar
)"
if [[ ! "${oci_reference}" =~ ^oci:///output/verification\.tar@sha256:[0-9a-f]{64}$ ]] ||
    [[ ! -s "${OUTPUT_DIRECTORY}/verification.tar" ]]; then
    echo "Non-push OCI verification output is invalid: ${oci_reference}" >&2
    exit 1
fi
if docker run --rm \
    --network "${NETWORK_NAME}" \
    --entrypoint crane \
    "${CLIENT_IMAGE}" \
    digest --insecure registry:5000/pitcrew/image-builder-test:verify >/dev/null 2>&1; then
    echo "Non-push verification unexpectedly created a registry tag." >&2
    exit 1
fi

remaining_cache="$(
    docker run --rm \
        --network "${NETWORK_NAME}" \
        --mount "type=bind,src=${CLIENT_CERTIFICATE_DIRECTORY},dst=/tls,readonly" \
        --entrypoint buildctl \
        "${CLIENT_IMAGE}" \
        --addr tcp://buildkitd:1234 \
        --tlsservername buildkitd \
        --tlsdir /tls \
        du --format '{{json .}}'
)"
if [[ -n "${remaining_cache}" && "${remaining_cache}" != "null" ]]; then
    echo "BuildKit retained cache after the job boundary: ${remaining_cache}" >&2
    exit 1
fi
remaining_histories="$(
    docker run --rm \
        --network "${NETWORK_NAME}" \
        --mount "type=bind,src=${CLIENT_CERTIFICATE_DIRECTORY},dst=/tls,readonly" \
        --entrypoint buildctl \
        "${CLIENT_IMAGE}" \
        --addr tcp://buildkitd:1234 \
        --tlsservername buildkitd \
        --tlsdir /tls \
        debug histories \
        --format '{{json .}}'
)"
if [[ -n "${remaining_histories}" ]]; then
    echo "BuildKit retained history after the job boundary." >&2
    exit 1
fi

if docker run --rm \
    --entrypoint getent \
    "${CLIENT_IMAGE}" \
    hosts buildkitd >/dev/null 2>&1; then
    echo "An unrelated container resolved the isolated BuildKit service." >&2
    exit 1
fi

echo "Isolated rootless image-builder integration passed."
