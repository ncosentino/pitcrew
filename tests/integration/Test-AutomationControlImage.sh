#!/usr/bin/env bash
set -euo pipefail

ROOT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROFILE_DIRECTORY="${ROOT_DIRECTORY}/profiles/automation-control"
PROFILE_PATH="${PROFILE_DIRECTORY}/profile.json"
IMAGE_TAG="pitcrew-automation-control-test:local"
MAX_IMAGE_SIZE_BYTES=943718400

cleanup() {
    docker image rm "${IMAGE_TAG}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

mapfile -t build_arguments < <(
    jq -r '.build.args | to_entries[] | "--build-arg", (.key + "=" + .value)' \
        "${PROFILE_PATH}"
)

if [[ "$(jq -r '.autoscaling.mode' "${PROFILE_PATH}")" != "scale-set" ]]; then
    echo "Automation-control must remain scale-set-only." >&2
    exit 1
fi

for pinned_input in \
    RUNTIME_IMAGE \
    GIT_SHA256 \
    RUNNER_SHA256_X64 \
    RUNNER_SHA256_ARM64 \
    GH_SHA256_X64 \
    GH_SHA256_ARM64 \
    POWERSHELL_SHA256_X64 \
    POWERSHELL_SHA256_ARM64; do
    value="$(jq -r --arg key "${pinned_input}" '.build.args[$key]' "${PROFILE_PATH}")"
    if [[ "${pinned_input}" == "RUNTIME_IMAGE" ]]; then
        [[ "${value}" =~ @sha256:[0-9a-f]{64}$ ]] || {
            echo "Automation-control runtime base is not digest pinned." >&2
            exit 1
        }
    elif [[ ! "${value}" =~ ^[0-9a-f]{64}$ ]]; then
        echo "Automation-control input '${pinned_input}' is not checksum pinned." >&2
        exit 1
    fi
done

docker build \
    --file "${PROFILE_DIRECTORY}/Dockerfile" \
    --tag "${IMAGE_TAG}" \
    "${build_arguments[@]}" \
    "${PROFILE_DIRECTORY}"

docker run --rm \
    --entrypoint /bin/bash \
    "${IMAGE_TAG}" \
    -lc '
        set -euo pipefail
        test "$(id -u)" = "1001"
        test -w "${HOME}"
        test ! -e /var/run/docker.sock
        /actions-runner/bin/Runner.Listener --version
        /actions-runner/externals/node20/bin/node -e "process.stdout.write(process.version)"
        /actions-runner/externals/node24/bin/node -e "process.stdout.write(process.version)"
        test ! -e /actions-runner/externals/node20_alpine
        test ! -e /actions-runner/externals/node24_alpine
        git --version | grep -F "2.55.0"
        gh --version | grep -F "2.98.0"
        gh api --help >/dev/null
        gh api graphql --help >/dev/null
        jq -e ".ready == true" <<< "{\"ready\":true}" >/dev/null
        pwsh -NoLogo -NoProfile -Command \
            "\$value = [pscustomobject]@{ Ready = \$true }; if (-not \$value.Ready) { exit 1 }; & gh --version | Out-Null"

        fixture="$(mktemp -d)"
        git -C "${fixture}" init source >/dev/null
        git -C "${fixture}/source" config user.name Automation
        git -C "${fixture}/source" config user.email automation@example.com
        mkdir -p "${fixture}/source/selected" "${fixture}/source/omitted"
        printf "selected\n" > "${fixture}/source/selected/value.txt"
        printf "omitted\n" > "${fixture}/source/omitted/value.txt"
        git -C "${fixture}/source" add .
        git -C "${fixture}/source" commit -m fixture >/dev/null
        git -C "${fixture}" init --bare origin.git >/dev/null
        git -C "${fixture}/source" remote add origin "${fixture}/origin.git"
        git -C "${fixture}/source" push origin HEAD:main >/dev/null
        git -C "${fixture}" clone --no-checkout --sparse "file://${fixture}/origin.git" checkout >/dev/null
        git -C "${fixture}/checkout" sparse-checkout set selected
        git -C "${fixture}/checkout" checkout main >/dev/null
        test -f "${fixture}/checkout/selected/value.txt"
        test ! -e "${fixture}/checkout/omitted/value.txt"
        git -C "${fixture}/checkout" ls-remote origin refs/heads/main >/dev/null
        git check-ref-format --branch automation-control >/dev/null
        rm -rf "${fixture}"

        for omitted in \
            docker \
            kubectl \
            helm \
            python3 \
            pip \
            perl \
            sudo \
            gpg \
            add-apt-repository \
            dotnet \
            java \
            go \
            gcc \
            make; do
            if command -v "${omitted}" >/dev/null; then
                echo "Unexpected automation-control tool: ${omitted}" >&2
                exit 1
            fi
        done
    '

docker run --rm \
    --mount "type=bind,src=${ROOT_DIRECTORY},dst=/workspace,readonly" \
    --entrypoint pwsh \
    "${IMAGE_TAG}" \
    -NoLogo \
    -NoProfile \
    -File /workspace/scripts/guidance/Get-ValidationInventory.ps1 \
    >/dev/null

image_user="$(docker image inspect --format '{{.Config.User}}' "${IMAGE_TAG}")"
image_entrypoint="$(docker image inspect --format '{{json .Config.Entrypoint}}' "${IMAGE_TAG}")"
image_size="$(docker image inspect --format '{{.Size}}' "${IMAGE_TAG}")"
if [[ "${image_user}" != "runner" ]]; then
    echo "Automation-control must run as the dedicated runner user, got '${image_user}'." >&2
    exit 1
fi
if [[ "${image_entrypoint}" != "null" ]]; then
    echo "Automation-control must rely on the scale-set Runner.Listener override." >&2
    exit 1
fi
if ((image_size > MAX_IMAGE_SIZE_BYTES)); then
    echo "Automation-control image size ${image_size} exceeds ${MAX_IMAGE_SIZE_BYTES} bytes." >&2
    exit 1
fi

echo "Automation-control image qualification passed at ${image_size} bytes."
