#!/bin/bash
set -euo pipefail
if [ "${ACTIONS_RUNNER_INPUT_JITCONFIG:-}" = fixture-sentinel ]; then
    while :; do sleep 1; done
fi
export TESTCONTAINERS_RYUK_CONTAINER_IMAGE='testcontainers/ryuk:0.14.0@sha256:7c1a8a9a47c780ed0f983770a662f80deb115d95cce3e2daa3d12115b8cd28f0'
started=$SECONDS
if [ "$(dotnet --version)" != 10.0.302 ] ||
    [ "$(docker version --format '{{.Server.Version}}')" != 28.5.2 ]; then
    echo '[pitcrew:nested-smoke] phase=tool-verification status=failed' >&2
    exit 1
fi
echo "[pitcrew:nested-smoke] phase=tool-verification status=passed sdk=10.0.302 docker=28.5.2 elapsed_seconds=$((SECONDS - started))"
if [ -n "$(docker ps --all --quiet)" ]; then
    echo '[pitcrew:nested-smoke] phase=fresh-daemon status=failed' >&2
    exit 1
fi
echo '[pitcrew:nested-smoke] phase=fresh-daemon status=passed'
if [ "$(docker info --format '{{.Driver}}')" != overlay2 ]; then
    echo '[pitcrew:nested-smoke] phase=storage-policy status=failed' >&2
    exit 1
fi
echo '[pitcrew:nested-smoke] phase=storage-policy status=passed driver=overlay2'
echo "[pitcrew:nested-smoke] daemon_identity=$(docker info --format '{{.ID}}')"
budget="$(cat /sys/fs/cgroup/memory.max)|$(cat /sys/fs/cgroup/memory.swap.max)|$(cat /sys/fs/cgroup/pids.max)|$(cat /sys/fs/cgroup/cpu.max)"
if [ "$budget" != '3221225472|0|1024|100000 100000' ]; then
    echo '[pitcrew:nested-smoke] phase=aggregate-budget status=failed' >&2
    exit 1
fi
echo '[pitcrew:nested-smoke] phase=aggregate-budget status=passed memory=3221225472 swap=0 pids=1024 cpu=1'
report_counters() {
    local phase="$1" counter line
    for counter in memory.current memory.events cpu.stat cpu.pressure memory.pressure; do
        if [ -r "/sys/fs/cgroup/$counter" ]; then
            while IFS= read -r line; do
                echo "[pitcrew:nested-smoke] scope=worker-parent phase=$phase counter=$counter value=$line"
            done < "/sys/fs/cgroup/$counter"
        else
            echo "[pitcrew:nested-smoke] scope=worker-parent phase=$phase counter=$counter unavailable"
        fi
    done
}
report_counters baseline
dotnet /qualification/bin/NestedDockerSmoke.dll cold
dotnet /qualification/bin/NestedDockerSmoke.dll warm
set +e
dotnet /qualification/bin/NestedDockerSmoke.dll abort
status=$?
set -e
if [ "$status" != 23 ]; then
    echo '[pitcrew:nested-smoke] phase=failure-injection status=failed' >&2
    exit 1
fi
started=$SECONDS
progress_at=$SECONDS
previous_count=2147483647
while :; do
    remaining=$(docker ps --all --quiet)
    if [ -z "$remaining" ]; then break; fi
    mapfile -t owned <<< "$remaining"
    if [ "${#owned[@]}" -lt "$previous_count" ]; then
        previous_count="${#owned[@]}"
        progress_at=$SECONDS
    fi
    if [ "$((SECONDS - progress_at))" -ge 120 ]; then
        echo '[pitcrew:nested-smoke] phase=reaper-cleanup status=stalled' >&2
        exit 1
    fi
    sleep 1
done
if [ -n "$(docker volume ls --quiet)" ] ||
    [ -n "$(docker network ls --quiet --filter type=custom)" ]; then
    echo '[pitcrew:nested-smoke] phase=reaper-cleanup status=failed reason=owned-resources-remain' >&2
    exit 1
fi
echo "[pitcrew:nested-smoke] phase=reaper-cleanup status=passed elapsed_seconds=$((SECONDS - started))"
report_counters final
# The fixture uses synthetic JIT input only; this is not a registered listener.
case "${ACTIONS_RUNNER_INPUT_JITCONFIG:-}" in
    fixture-hold)
        while :; do sleep 1; done
        ;;
    fixture-daemon-failure)
        kill -TERM "$(cat /run/pitcrew-docker/daemon.pid)"
        while :; do sleep 1; done
        ;;
    fixture-normal) exit 0 ;;
    *) echo '[pitcrew:nested-smoke] phase=fixture-input status=failed' >&2; exit 1 ;;
esac
