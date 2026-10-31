#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
image="pitcrew-nested-qualification:${GITHUB_SHA:?}"
started=$SECONDS
log="$(mktemp)"
report() {
    status=$?
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
        echo '## Nested Docker controlled integration'
        echo
        echo "Revision: \`$GITHUB_SHA\`. Existing configured CI runner; no production profile activated."
        echo
        echo 'Fixture: .NET SDK 10.0.302, Docker 28.5.2, Testcontainers 4.16.0, pinned MariaDB 11.4.5 and Ryuk 0.14.0.'
        echo
        echo 'Worker-local daemon; two concurrent Linux x64 workers, each 1 CPU / 3 GiB memory / no swap / 1024 PIDs / 2 GiB bounded in-memory daemon storage.'
        echo
        echo 'This is a synthetic listener exercising the actual launch builder, not a registered GitHub worker qualification or an application provider suite.'
        echo
        echo '```text'
        grep '\[pitcrew:nested-' "$log" || echo 'No bounded execution markers available.'
        echo '```'
        echo
        echo "Controlled integration exit status: $status; elapsed: $((SECONDS - started)) seconds, including fixture preparation."
        echo 'Admission queue delay and registered-runner acquisition: unavailable in this synthetic fixture; obtain from the separately authorized registered-worker canary.'
    } >> "$GITHUB_STEP_SUMMARY"
    fi
    rm -- "$log"
}
trap report EXIT
docker build --progress=plain --tag "$image" "$root/tests/integration/nested-docker"
image_id="$(docker image inspect --format '{{.Id}}' "$image")"
echo "[pitcrew:nested-smoke] phase=fixture-image-preparation elapsed_seconds=$((SECONDS - started)) revision=$GITHUB_SHA image=$image_id" | tee -a "$log"
export PITCREW_TEST_NESTED_DOCKER_IMAGE="$image"
cd "$root/manager/autoscaler"
go test -tags=nested_docker_integration -count=1 -run '^TestNestedDockerIntegration$' -v . |
    tee -a "$log"
