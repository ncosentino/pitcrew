set -eu
umask 077

fail() {
    printf '[pitcrew:nested-docker] phase=%s status=failed reason=%s\n' "$1" "$2" >&2
    exit 1
}

daemon_pid=''
runner_pid=''
cleanup() {
    trap - EXIT TERM INT
    if [ -n "$runner_pid" ] && kill -0 "$runner_pid" 2>/dev/null; then
        kill -TERM "$runner_pid"
    fi
    if [ -n "$daemon_pid" ] && kill -0 "$daemon_pid" 2>/dev/null; then
        kill -TERM "$daemon_pid"
    fi
    # Children can already have failed; retain the primary worker exit status.
    if [ -n "$runner_pid" ]; then wait "$runner_pid" || :; fi
    if [ -n "$daemon_pid" ]; then wait "$daemon_pid" || :; fi
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

[ "$(id -u)" = 0 ] || fail preflight image-user-must-be-root
[ "$(uname -m)" = x86_64 ] || fail preflight unsupported-architecture
for command in docker dockerd containerd runc iptables ip timeout; do
    command -v "$command" >/dev/null || fail preflight missing-runtime-tool
done
[ -f /sys/fs/cgroup/cgroup.controllers ] || fail preflight cgroup-v2-required
[ "$(cat /proc/self/cgroup)" = '0::/' ] || fail preflight private-cgroup-namespace-required
for limit in memory.max pids.max; do
    value=$(cat "/sys/fs/cgroup/$limit")
    case "$value" in ''|max|*[!0-9]*) fail preflight finite-resource-limits-required ;; esac
done
[ "$(cat /sys/fs/cgroup/memory.swap.max)" = 0 ] || fail preflight swap-must-be-disabled
case "$(cat /sys/fs/cgroup/cpu.max)" in max\ *) fail preflight cpu-quota-required ;; esac

# All descendants remain below the outer worker's limited cgroup. Move the
# bootstrap/init into a child before enabling v2 domain controllers.
mkdir /sys/fs/cgroup/pitcrew-init
while read -r pid; do
    if ! printf '%s\n' "$pid" > /sys/fs/cgroup/pitcrew-init/cgroup.procs; then
        [ ! -d "/proc/$pid" ] || fail preflight cgroup-delegation-failed
    fi
done < /sys/fs/cgroup/cgroup.procs
for controller in cpu memory pids; do
    printf '+%s\n' "$controller" > /sys/fs/cgroup/cgroup.subtree_control ||
        fail preflight cgroup-controller-unavailable
done

export DOCKER_HOST=unix:///run/pitcrew-docker/docker.sock
export TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE=/run/pitcrew-docker/docker.sock
export TESTCONTAINERS_HOST_OVERRIDE=127.0.0.1
unset DOCKER_CONTEXT DOCKER_TLS_VERIFY DOCKER_CERT_PATH DOCKER_API_VERSION
unset TESTCONTAINERS_RYUK_DISABLED
mkdir -p /run/pitcrew-docker /var/lib/pitcrew-docker
printf '{}\n' > /run/pitcrew-docker/daemon.json
started=$(date +%s)
env -u ACTIONS_RUNNER_INPUT_JITCONFIG dockerd \
    --config-file /run/pitcrew-docker/daemon.json \
    --host "$DOCKER_HOST" \
    --data-root /var/lib/pitcrew-docker \
    --exec-root /run/pitcrew-docker/exec \
    --pidfile /run/pitcrew-docker/daemon.pid \
    --storage-driver overlay2 \
    --exec-opt native.cgroupdriver=cgroupfs \
    --cgroup-parent /pitcrew-containers \
    --ip 127.0.0.1 \
    --default-network-opt bridge=com.docker.network.bridge.host_binding_ipv4=127.0.0.1 \
    --log-level error \
    > /run/pitcrew-docker/daemon.log 2>&1 &
daemon_pid=$!
previous_phase=0
progress_at=$started
until timeout 5 docker info >/dev/null 2>&1; do
    kill -0 "$daemon_pid" 2>/dev/null || fail readiness daemon-exited
    now=$(date +%s)
    phase=0
    if [ -S /run/pitcrew-docker/exec/containerd/containerd.sock ]; then phase=1; fi
    if [ -S /run/pitcrew-docker/docker.sock ]; then phase=2; fi
    if [ "$phase" -gt "$previous_phase" ]; then
        previous_phase=$phase
        progress_at=$now
    fi
    [ "$((now - progress_at))" -lt 120 ] || fail readiness daemon-startup-stalled
    sleep 1
done
printf '[pitcrew:nested-docker] phase=readiness status=ready elapsed_seconds=%s\n' \
    "$(($(date +%s) - started))"

if [ "${PITCREW_NESTED_DOCKER_VERIFY_ONLY:-}" = 1 ]; then
    exit 0
fi
/actions-runner/bin/Runner.Listener "$@" &
runner_pid=$!
while kill -0 "$runner_pid" 2>/dev/null; do
    kill -0 "$daemon_pid" 2>/dev/null || fail execution daemon-exited
    sleep 1
done
status=0
wait "$runner_pid" || status=$?
printf '[pitcrew:nested-docker] phase=runner status=exited exit_code=%s\n' "$status"
exit "$status"
