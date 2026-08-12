#!/usr/bin/env bash
set -euo pipefail

ROOT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SUFFIX="$(date +%s)-$$"
NETWORK_NAME="pitcrew-image-builder-test-${SUFFIX}"
BUILDKIT_NAME="pitcrew-buildkit-test-${SUFFIX}"
REGISTRY_NAME="pitcrew-registry-test-${SUFFIX}"
BUILDKIT_VOLUME="pitcrew-buildkit-state-${SUFFIX}"
CLIENT_IMAGE="pitcrew-image-builder-test:${SUFFIX}"
TEMP_DIRECTORY="$(mktemp -d)"

cleanup() {
    docker container rm --force "${BUILDKIT_NAME}" "${REGISTRY_NAME}" >/dev/null 2>&1 || true
    docker volume rm "${BUILDKIT_VOLUME}" >/dev/null 2>&1 || true
    docker network rm "${NETWORK_NAME}" >/dev/null 2>&1 || true
    docker image rm "${CLIENT_IMAGE}" >/dev/null 2>&1 || true
    rm -rf "${TEMP_DIRECTORY}"
}
trap cleanup EXIT

for command in docker openssl; do
    command -v "${command}" >/dev/null || {
        echo "Required command is unavailable: ${command}" >&2
        exit 1
    }
done

CERTIFICATE_WORK_DIRECTORY="${TEMP_DIRECTORY}/certificate-work"
SERVER_CERTIFICATE_DIRECTORY="${TEMP_DIRECTORY}/server-certs"
CLIENT_CERTIFICATE_DIRECTORY="${TEMP_DIRECTORY}/client-certs"
CONTEXT_DIRECTORY="${TEMP_DIRECTORY}/context"
mkdir -p \
    "${CERTIFICATE_WORK_DIRECTORY}" \
    "${SERVER_CERTIFICATE_DIRECTORY}" \
    "${CLIENT_CERTIFICATE_DIRECTORY}" \
    "${CONTEXT_DIRECTORY}"

openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "${CERTIFICATE_WORK_DIRECTORY}/ca-key.pem" \
    -out "${CERTIFICATE_WORK_DIRECTORY}/ca.pem" \
    -subj "/CN=pitcrew-buildkit-test-ca" \
    -days 1 >/dev/null 2>&1

openssl req -newkey rsa:2048 -nodes \
    -keyout "${CERTIFICATE_WORK_DIRECTORY}/server-key.pem" \
    -out "${CERTIFICATE_WORK_DIRECTORY}/server.csr" \
    -subj "/CN=buildkitd" >/dev/null 2>&1
cat > "${CERTIFICATE_WORK_DIRECTORY}/server.ext" <<'EOF'
subjectAltName=DNS:buildkitd
extendedKeyUsage=serverAuth
EOF
openssl x509 -req \
    -in "${CERTIFICATE_WORK_DIRECTORY}/server.csr" \
    -CA "${CERTIFICATE_WORK_DIRECTORY}/ca.pem" \
    -CAkey "${CERTIFICATE_WORK_DIRECTORY}/ca-key.pem" \
    -CAcreateserial \
    -out "${CERTIFICATE_WORK_DIRECTORY}/server-cert.pem" \
    -days 1 \
    -extfile "${CERTIFICATE_WORK_DIRECTORY}/server.ext" >/dev/null 2>&1

openssl req -newkey rsa:2048 -nodes \
    -keyout "${CERTIFICATE_WORK_DIRECTORY}/key.pem" \
    -out "${CERTIFICATE_WORK_DIRECTORY}/client.csr" \
    -subj "/CN=pitcrew-image-builder-client" >/dev/null 2>&1
cat > "${CERTIFICATE_WORK_DIRECTORY}/client.ext" <<'EOF'
extendedKeyUsage=clientAuth
EOF
openssl x509 -req \
    -in "${CERTIFICATE_WORK_DIRECTORY}/client.csr" \
    -CA "${CERTIFICATE_WORK_DIRECTORY}/ca.pem" \
    -CAkey "${CERTIFICATE_WORK_DIRECTORY}/ca-key.pem" \
    -CAcreateserial \
    -out "${CERTIFICATE_WORK_DIRECTORY}/cert.pem" \
    -days 1 \
    -extfile "${CERTIFICATE_WORK_DIRECTORY}/client.ext" >/dev/null 2>&1

install -m 0644 "${CERTIFICATE_WORK_DIRECTORY}/ca.pem" "${SERVER_CERTIFICATE_DIRECTORY}/ca.pem"
install -m 0644 "${CERTIFICATE_WORK_DIRECTORY}/server-cert.pem" "${SERVER_CERTIFICATE_DIRECTORY}/server-cert.pem"
install -m 0600 "${CERTIFICATE_WORK_DIRECTORY}/server-key.pem" "${SERVER_CERTIFICATE_DIRECTORY}/server-key.pem"
install -m 0644 "${CERTIFICATE_WORK_DIRECTORY}/ca.pem" "${CLIENT_CERTIFICATE_DIRECTORY}/ca.pem"
install -m 0644 "${CERTIFICATE_WORK_DIRECTORY}/cert.pem" "${CLIENT_CERTIFICATE_DIRECTORY}/cert.pem"
install -m 0600 "${CERTIFICATE_WORK_DIRECTORY}/key.pem" "${CLIENT_CERTIFICATE_DIRECTORY}/key.pem"

cat > "${TEMP_DIRECTORY}/buildkitd.toml" <<'EOF'
root = "/var/lib/buildkit"

[grpc]
  address = [ "tcp://0.0.0.0:1234" ]
  [grpc.tls]
    cert = "/certs/server-cert.pem"
    key = "/certs/server-key.pem"
    ca = "/certs/ca.pem"

[history]
  maxAge = 60
  maxEntries = 1

[worker.oci]
  enabled = true
  gc = true
  max-parallelism = 1

[registry."registry:5000"]
  http = true
EOF

cat > "${CONTEXT_DIRECTORY}/Dockerfile" <<'EOF'
FROM scratch
COPY payload.txt /payload.txt
EOF
printf 'isolated-image-builder\n' > "${CONTEXT_DIRECTORY}/payload.txt"

docker network create "${NETWORK_NAME}" >/dev/null
docker volume create "${BUILDKIT_VOLUME}" >/dev/null

docker run --detach \
    --name "${REGISTRY_NAME}" \
    --network "${NETWORK_NAME}" \
    --network-alias registry \
    registry:3.0.0@sha256:6c5666b861f3505b116bb9aa9b25175e71210414bd010d92035ff64018f9457e \
    >/dev/null

docker run --detach \
    --privileged \
    --name "${BUILDKIT_NAME}" \
    --network "${NETWORK_NAME}" \
    --network-alias buildkitd \
    --mount "type=bind,src=${SERVER_CERTIFICATE_DIRECTORY},dst=/certs,readonly" \
    --mount "type=bind,src=${TEMP_DIRECTORY}/buildkitd.toml,dst=/etc/buildkit/buildkitd.toml,readonly" \
    --mount "type=volume,src=${BUILDKIT_VOLUME},dst=/var/lib/buildkit" \
    moby/buildkit:v0.32.2@sha256:28a898719c18a33f4e8000685287fa36fd0dd9560c6440227d3a732d79bb41d8 \
    --config /etc/buildkit/buildkitd.toml \
    >/dev/null

docker build \
    --file "${ROOT_DIRECTORY}/profiles/image-builder/Dockerfile" \
    --tag "${CLIENT_IMAGE}" \
    --build-arg BUILDKIT_VERSION=0.32.2 \
    --build-arg BUILDKIT_SHA256_X64=2975d0f651ad96ba8b80b9992ae1f9a964f4408569af5b6dc36544165c3926af \
    --build-arg BUILDKIT_SHA256_ARM64=9e8f46bf309ec0ab262967be5538a4dbe06be756a82621f98253933bac5dcf92 \
    "${ROOT_DIRECTORY}/profiles/image-builder" \
    >/dev/null

buildkit_ready=0
for _ in {1..60}; do
    if docker run --rm \
        --network "${NETWORK_NAME}" \
        --mount "type=bind,src=${CLIENT_CERTIFICATE_DIRECTORY},dst=/tls,readonly" \
        --entrypoint buildctl \
        "${CLIENT_IMAGE}" \
        --addr tcp://buildkitd:1234 \
        --tlsservername buildkitd \
        --tlsdir /tls \
        debug workers >/dev/null 2>&1; then
        buildkit_ready=1
        break
    fi
    sleep 1
done
if [[ "${buildkit_ready}" != "1" ]]; then
    echo "BuildKit did not accept the authenticated client within 60 seconds." >&2
    docker logs "${BUILDKIT_NAME}" >&2 || true
    exit 1
fi

docker run --rm \
    --network "${NETWORK_NAME}" \
    --mount "type=bind,src=${CLIENT_CERTIFICATE_DIRECTORY},dst=/tls,readonly" \
    --entrypoint /bin/bash \
    "${CLIENT_IMAGE}" \
    -lc 'test ! -e /var/run/docker.sock'

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

published_reference="$(
    docker run --rm \
        --network "${NETWORK_NAME}" \
        --mount "type=bind,src=${CLIENT_CERTIFICATE_DIRECTORY},dst=/tls,readonly" \
        --mount "type=bind,src=${CONTEXT_DIRECTORY},dst=/workspace,readonly" \
        --env BUILDKIT_HOST=tcp://buildkitd:1234 \
        --env BUILDKIT_TLS_DIR=/tls \
        --entrypoint pitcrew-build-image \
        "${CLIENT_IMAGE}" \
        registry:5000/pitcrew/image-builder-test:ci \
        /workspace \
        /workspace
)"

published_digest="${published_reference##*@}"
if [[ ! "${published_digest}" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    echo "Image-builder helper returned an invalid immutable reference: ${published_reference}" >&2
    exit 1
fi

registry_digest="$(
    docker run --rm \
        --network "${NETWORK_NAME}" \
        --entrypoint /bin/bash \
        "${CLIENT_IMAGE}" \
        -lc "curl -fsSI -H 'Accept: application/vnd.oci.image.manifest.v1+json' http://registry:5000/v2/pitcrew/image-builder-test/manifests/ci" |
        tr -d '\r' |
        awk -F': ' 'tolower($1) == "docker-content-digest" { print $2 }'
)"
if [[ "${registry_digest}" != "${published_digest}" ]]; then
    echo "Published registry digest ${registry_digest} does not match ${published_digest}." >&2
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
if [[ -n "${remaining_cache}" ]]; then
    echo "BuildKit retained cache after the job boundary: ${remaining_cache}" >&2
    exit 1
fi

echo "Isolated image-builder integration passed."
