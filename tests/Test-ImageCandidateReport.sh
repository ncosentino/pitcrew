#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="${ROOT}/profiles/image-builder/pitcrew-build-image"
TEMP_DIRECTORY="$(mktemp -d)"
trap 'rm -rf "${TEMP_DIRECTORY}"' EXIT
ASSERTIONS=0
DIGEST="sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

fail() {
    echo "ERROR: $1" >&2
    exit 1
}

assert_true() {
    local message="$1"
    shift
    ASSERTIONS=$((ASSERTIONS + 1))
    "$@" || fail "${message}"
}

assert_json() {
    local path="$1"
    local expression="$2"
    local message="$3"
    ASSERTIONS=$((ASSERTIONS + 1))
    jq -e "${expression}" "${path}" >/dev/null || fail "${message}"
}

BIN_DIRECTORY="${TEMP_DIRECTORY}/bin"
TLS_DIRECTORY="${TEMP_DIRECTORY}/tls"
CONTEXT_DIRECTORY="${TEMP_DIRECTORY}/context"
OUTPUT_DIRECTORY="${TEMP_DIRECTORY}/output"
mkdir -p \
    "${BIN_DIRECTORY}" \
    "${TLS_DIRECTORY}" \
    "${CONTEXT_DIRECTORY}" \
    "${OUTPUT_DIRECTORY}"
for certificate in ca.pem cert.pem key.pem; do
    printf 'fixture\n' > "${TLS_DIRECTORY}/${certificate}"
done
printf 'FROM scratch\n' > "${CONTEXT_DIRECTORY}/Dockerfile"

cat > "${BIN_DIRECTORY}/buildctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

arguments=" $* "
case "${arguments}" in
    *" prune-histories "*|*" prune --all "*)
        if [[ "${PITCREW_TEST_CLEANUP_RESULT:-success}" == "failure" ]]; then
            exit 1
        fi
        exit 0
        ;;
    *" du "*)
        printf 'null\n'
        exit 0
        ;;
    *" debug histories "*)
        exit 0
        ;;
esac

if [[ "${arguments}" != *" build "* ]]; then
    echo "Unexpected buildctl invocation: $*" >&2
    exit 1
fi
if [[ "${PITCREW_TEST_BUILD_RESULT:-success}" == "failure" ]]; then
    exit 1
fi

metadata_path=""
output_value=""
while (($# > 0)); do
    case "$1" in
        --metadata-file)
            metadata_path="$2"
            shift 2
            ;;
        --output)
            output_value="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done
test -n "${metadata_path}"
mkdir -p "$(dirname "${metadata_path}")"
printf '{"containerimage.digest":"%s"}\n' "${PITCREW_TEST_DIGEST}" \
    > "${metadata_path}"

case "${output_value}" in
    type=oci,dest=*)
        destination="${output_value#type=oci,dest=}"
        oci_root="$(mktemp -d)"
        mkdir -p \
            "${oci_root}/blobs/sha256"
        printf '{}\n' > "${oci_root}/blobs/sha256/${PITCREW_TEST_DIGEST#sha256:}"
        jq -n \
            --arg digest "${PITCREW_TEST_DIGEST}" \
            '{schemaVersion:2,manifests:[{digest:$digest}]}' \
            > "${oci_root}/index.json"
        mkdir -p "$(dirname "${destination}")"
        tar -cf "${destination}" -C "${oci_root}" index.json blobs
        rm -rf "${oci_root}"
        ;;
esac
EOF
chmod +x "${BIN_DIRECTORY}/buildctl"

cat > "${BIN_DIRECTORY}/crane" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${PITCREW_TEST_REGISTRY_RESULT:-success}" == "failure" ]]; then
    exit 1
fi
printf '%s\n' "${PITCREW_TEST_REGISTRY_DIGEST:-${PITCREW_TEST_DIGEST}}"
EOF
chmod +x "${BIN_DIRECTORY}/crane"

export PATH="${BIN_DIRECTORY}:${PATH}"
export BUILDKIT_TLS_DIR="${TLS_DIRECTORY}"
export RUNNER_TEMP="${TEMP_DIRECTORY}/runner-temp"
export PITCREW_TEST_DIGEST="${DIGEST}"

export PITCREW_TEST_CLEANUP_RESULT=failure
export PITCREW_BUILDER_CLEANUP_TIMEOUT_SECONDS=1
if "${HELPER}" \
    --image-ref registry.example/example/application-ci:dirty \
    --context "${CONTEXT_DIRECTORY}" \
    --dockerfile "${CONTEXT_DIRECTORY}" \
    --platform linux/amd64 \
    --output-oci "${OUTPUT_DIRECTORY}/dirty.tar" \
    --candidate-output "${OUTPUT_DIRECTORY}/dirty-candidate.json" \
    --recipe-id application-ci \
    >/dev/null 2>&1; then
    fail "Dirty BuildKit preflight returned success."
fi
unset PITCREW_TEST_CLEANUP_RESULT
unset PITCREW_BUILDER_CLEANUP_TIMEOUT_SECONDS
assert_json \
    "${OUTPUT_DIRECTORY}/dirty-candidate.json" \
    '.status == "failed"
     and .failureCategory == "builder-cleanup-failed"
     and .failureDetail == "BuildKit cleanup did not reach an empty state."
     and (
        [.qualifications[] | select(.name == "builder-cleanup")][0].status ==
        "failed"
     )' \
    "Preflight-cleanup candidate report is invalid."

"${HELPER}" \
    --image-ref registry.example/example/application-ci:verify \
    --context "${CONTEXT_DIRECTORY}" \
    --dockerfile "${CONTEXT_DIRECTORY}" \
    --platform linux/amd64 \
    --output-oci "${OUTPUT_DIRECTORY}/verification.tar" \
    --candidate-output "${OUTPUT_DIRECTORY}/oci-candidate.json" \
    --recipe-id application-ci \
    --source-repository example-org/example-app \
    --source-commit aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    --workflow-run-id 123 \
    >/dev/null
assert_json \
    "${OUTPUT_DIRECTORY}/oci-candidate.json" \
    '.status == "ready"
     and .source.workflowRunId == 123
     and .image.outputMode == "oci"
     and .image.digest == "'"${DIGEST}"'"
     and .image.immutableReference == null
     and ([.qualifications[].status] | all(. == "passed"))' \
    "OCI candidate report is invalid."
assert_true \
    "OCI candidate report is not owner-only." \
    test "$(stat -c '%a' "${OUTPUT_DIRECTORY}/oci-candidate.json")" = "600"

"${HELPER}" \
    --image-ref registry.example/example/application-ci:publish \
    --context "${CONTEXT_DIRECTORY}" \
    --dockerfile "${CONTEXT_DIRECTORY}" \
    --platform linux/arm64 \
    --push \
    --verify-registry \
    --candidate-output "${OUTPUT_DIRECTORY}/registry-candidate.json" \
    --recipe-id application-ci \
    >/dev/null
assert_json \
    "${OUTPUT_DIRECTORY}/registry-candidate.json" \
    '.status == "ready"
     and .image.outputMode == "registry"
     and .image.immutableReference ==
        "registry.example/example/application-ci@'"${DIGEST}"'"
     and .failureCategory == null' \
    "Registry candidate report is invalid."

export PITCREW_TEST_REGISTRY_DIGEST="sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
if "${HELPER}" \
    --image-ref registry.example/example/application-ci:mismatch \
    --context "${CONTEXT_DIRECTORY}" \
    --dockerfile "${CONTEXT_DIRECTORY}" \
    --platform linux/amd64 \
    --push \
    --verify-registry \
    --candidate-output "${OUTPUT_DIRECTORY}/mismatch-candidate.json" \
    --recipe-id application-ci \
    >/dev/null 2>&1; then
    fail "Registry digest mismatch returned success."
fi
unset PITCREW_TEST_REGISTRY_DIGEST
assert_json \
    "${OUTPUT_DIRECTORY}/mismatch-candidate.json" \
    '.status == "failed"
     and .image.digest == "'"${DIGEST}"'"
     and .failureCategory == "registry-digest-mismatch"
     and .failureDetail == "Registry digest did not match BuildKit digest."
     and (
        [.qualifications[] | select(.name == "registry-digest")][0].status ==
        "unavailable"
     )' \
    "Registry mismatch candidate report is invalid."

export PITCREW_TEST_BUILD_RESULT=failure
if "${HELPER}" \
    --image-ref registry.example/example/application-ci:failed \
    --context "${CONTEXT_DIRECTORY}" \
    --dockerfile "${CONTEXT_DIRECTORY}" \
    --platform linux/amd64 \
    --output-oci "${OUTPUT_DIRECTORY}/failed.tar" \
    --candidate-output "${OUTPUT_DIRECTORY}/failed-candidate.json" \
    --recipe-id application-ci \
    >/dev/null 2>&1; then
    fail "Deliberately failed build returned success."
fi
unset PITCREW_TEST_BUILD_RESULT
assert_json \
    "${OUTPUT_DIRECTORY}/failed-candidate.json" \
    '.status == "failed"
     and .image.digest == null
     and .failureCategory == "build-failed"
     and .failureDetail == "Image build did not complete."
     and ([.qualifications[] | select(.name == "image-build")][0].status ==
        "failed")' \
    "Failed candidate report is invalid."

if "${HELPER}" \
    --image-ref registry.example/example/application-ci:invalid \
    --context "${CONTEXT_DIRECTORY}" \
    --dockerfile "${CONTEXT_DIRECTORY}" \
    --platform linux/amd64 \
    --output-oci "${OUTPUT_DIRECTORY}/invalid.tar" \
    --candidate-output "${CONTEXT_DIRECTORY}/candidate.json" \
    --recipe-id application-ci \
    >/dev/null 2>&1; then
    fail "Candidate output inside the reviewed context was accepted."
fi
assert_true \
    "Rejected candidate output was written inside the build context." \
    test ! -e "${CONTEXT_DIRECTORY}/candidate.json"

if "${HELPER}" \
    --image-ref registry.example/example/application-ci:collision \
    --context "${CONTEXT_DIRECTORY}" \
    --dockerfile "${CONTEXT_DIRECTORY}" \
    --platform linux/amd64 \
    --output-oci "${OUTPUT_DIRECTORY}/collision.tar" \
    --candidate-output "${OUTPUT_DIRECTORY}/collision.tar" \
    --recipe-id application-ci \
    >/dev/null 2>&1; then
    fail "Candidate report was allowed to overwrite OCI output."
fi
assert_true \
    "Rejected output collision created a candidate or OCI artifact." \
    test ! -e "${OUTPUT_DIRECTORY}/collision.tar"

if "${HELPER}" \
    --image-ref registry.example/example/application-ci:unverified \
    --context "${CONTEXT_DIRECTORY}" \
    --dockerfile "${CONTEXT_DIRECTORY}" \
    --platform linux/amd64 \
    --push \
    --candidate-output "${OUTPUT_DIRECTORY}/unverified.json" \
    --recipe-id application-ci \
    >/dev/null 2>&1; then
    fail "Unverified registry candidate was accepted."
fi

echo "Image candidate report tests passed: ${ASSERTIONS} assertions."
