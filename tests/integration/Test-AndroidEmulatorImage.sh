#!/usr/bin/env bash
set -euo pipefail

ROOT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROFILE_DIRECTORY="${ROOT_DIRECTORY}/profiles/android-emulator"
PROFILE_PATH="${PROFILE_DIRECTORY}/profile.json"
IMAGE_TAG="pitcrew-android-emulator-test:local"

cleanup() {
    docker image rm "${IMAGE_TAG}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker_android_image="$(jq -r '.build.args.DOCKER_ANDROID_IMAGE' "${PROFILE_PATH}")"
runner_image="$(jq -r '.build.args.RUNNER_IMAGE' "${PROFILE_PATH}")"
if [[ ! "${docker_android_image}" =~ @sha256:[0-9a-f]{64}$ ]] ||
    [[ ! "${runner_image}" =~ @sha256:[0-9a-f]{64}$ ]]; then
    echo "Android profile build inputs must use immutable image digests." >&2
    exit 1
fi

docker build \
    --file "${PROFILE_DIRECTORY}/Dockerfile" \
    --tag "${IMAGE_TAG}" \
    --build-arg "DOCKER_ANDROID_IMAGE=${docker_android_image}" \
    --build-arg "RUNNER_IMAGE=${runner_image}" \
    "${PROFILE_DIRECTORY}"

docker run --rm \
    --entrypoint /bin/bash \
    "${IMAGE_TAG}" \
    -lc '
        set -euo pipefail
        /actions-runner/bin/Runner.Listener --version
        test -x /usr/local/bin/start-android-emulator
        test "${USER_BEHAVIOR_ANALYTICS}" = "false"
        test "${WEB_LOG}" = "false"
        test "${WEB_VNC}" = "false"
        test ! -e /var/run/docker.sock
        bash -n /usr/local/bin/start-android-emulator
        adb version
        emulator -version
    '

image_user="$(docker image inspect --format '{{.Config.User}}' "${IMAGE_TAG}")"
image_entrypoint="$(docker image inspect --format '{{json .Config.Entrypoint}}' "${IMAGE_TAG}")"
if [[ -n "${image_user}" && "${image_user}" != "root" && "${image_user}" != "0" ]]; then
    echo "Android runner image must declare a root-capable runner user, got '${image_user}'." >&2
    exit 1
fi
if [[ "${image_entrypoint}" != '["/entrypoint.sh"]' ]]; then
    echo "Android runner image has an unexpected entrypoint: ${image_entrypoint}" >&2
    exit 1
fi

echo "Android emulator runner image qualification passed."
