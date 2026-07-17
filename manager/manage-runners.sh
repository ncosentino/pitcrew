#!/bin/sh
# Babysitter for truly-ephemeral self-hosted runners.
#
# Docker has no native "recreate a fresh container when this one exits" — its
# restart policy reuses the SAME container (state persists), and --rm deletes a
# container without relaunching it. This script is the missing piece: it keeps
# RUNNER_REPLICAS slots filled, and each slot launches the runner with --rm +
# EPHEMERAL=1, so every CI job runs in a brand-new container that is destroyed
# the moment the job ends. Nothing survives between jobs, so an interrupted apt,
# a cancelled job, an OOM, or any other mess simply vanishes with the container —
# the next job always starts from a pristine image. That is the whole point.
#
# It talks to the host Docker daemon via the mounted socket to start sibling
# containers (the runners are NOT nested inside this one).
set -u

PREFIX="${RUNNER_NAME_PREFIX:-runner}"
IMAGE="${RUNNER_IMAGE:-myoung34/github-runner:ubuntu-noble}"
REPLICAS="${RUNNER_REPLICAS:-2}"
PROFILE_ID="${RUNNER_PROFILE_ID:-default}"
# Repos to serve, comma-separated, each optionally "url=count" (default 1 slot).
# REPO_URLS preferred; REPO_URL kept for back-compat. Empty -> org/ent scope, where
# RUNNER_REPLICAS is the slot count instead.
REPOS="${REPO_URLS:-${REPO_URL:-}}"
# The profile value makes cleanup exact: one manager cannot remove another
# profile's runner containers.
MANAGED_LABEL_KEY="ephemeral-managed-runner-profile"
MANAGED_LABEL="${MANAGED_LABEL_KEY}=${PROFILE_ID}"

LABELS="${RUNNER_LABELS:-}"
append_label() {
    case ",${LABELS}," in
        *",$1,"*) ;;
        *) LABELS="${LABELS:+${LABELS},}$1" ;;
    esac
}
if [ "${RUNNER_NO_DEFAULT_LABELS:-}" = "1" ]; then
    case "$(uname -m)" in
        x86_64) architecture_label="x64" ;;
        aarch64|arm64) architecture_label="arm64" ;;
        armv7l|armv6l) architecture_label="arm" ;;
        *) architecture_label="$(uname -m | tr '[:upper:]' '[:lower:]')" ;;
    esac
    append_label "linux"
    append_label "${architecture_label}"
fi

# A runner that registers but never connects (host clock skew, an under-scoped
# token, a name clash, or a CPU-starved host) dies within seconds WITHOUT ever
# printing this line. Relaunching it immediately produces a 100%-CPU respawn
# storm. We treat "reached the listener" as the health signal: a runner that
# connected is respawned promptly, one that did not is retried with an
# escalating, jittered backoff (capped at MAX_BACKOFF) so a persistent failure
# degrades quietly instead of pegging the machine.
CONNECT_MARKER="Listening for Jobs"
MAX_BACKOFF="${RUNNER_MAX_BACKOFF:-120}"

# POSIX-portable randomness (BusyBox ash does not guarantee $RANDOM): a short hex
# token that makes every runner name unique, and a small 0-4 integer that jitters
# the backoff so slots failing together don't retry in lockstep.
rand_hex() { tr -dc 'a-f0-9' < /dev/urandom 2>/dev/null | head -c 6; }
rand_jitter() {
    b=$(od -An -N1 -tu1 /dev/urandom 2>/dev/null | tr -d ' ')
    echo $(( ${b:-0} % 5 ))
}

remove_managed() {
    # shellcheck disable=SC2046
    ids=$(docker ps -aq --filter "label=${MANAGED_LABEL}" 2>/dev/null || true)
    if [ -n "${ids}" ]; then
        echo "${ids}" | xargs -r docker rm -f >/dev/null 2>&1 || true
    fi
}

shutdown() {
    echo "[manager:${PROFILE_ID}] received stop signal — removing managed runner containers"
    STOPPING=1
    remove_managed
    exit 0
}
STOPPING=0
trap shutdown TERM INT

# A previous manager that was SIGKILLed (or a host crash) can leave orphaned
# runner containers. Clear them so we start from a known-empty pool.
echo "[manager:${PROFILE_ID}] clearing any leftover managed runners"
remove_managed

if [ "${RUNNER_PULL_IMAGE:-1}" = "1" ]; then
    echo "[manager:${PROFILE_ID}] pre-pulling runner image ${IMAGE}"
    docker pull "${IMAGE}" >/dev/null 2>&1 || echo "[manager:${PROFILE_ID}] pull failed (will rely on local image)"
else
    echo "[manager:${PROFILE_ID}] using locally prepared runner image ${IMAGE}"
fi

# One slot = one always-filled runner position. The runner is foreground here,
# so docker run blocks until the ephemeral runner finishes its single job and
# --rm removes the container; the loop then launches a pristine replacement.
run_slot() {
    slot="$1"
    repo="$2"
    tag="$3"
    fails=0
    logf="/tmp/slot-${slot}.log"
    while [ "${STOPPING}" -eq 0 ]; do
        # The per-launch hex suffix (on top of the second-granularity timestamp)
        # guarantees a unique name even if two slots — or two machines that happen
        # to share a hostname prefix — relaunch in the same second. A duplicate
        # name makes GitHub delete the older registration, which is one way runners
        # start failing to create a session.
        name="${PREFIX}-${tag}-$(date +%s)-$(rand_hex)"
        echo "[slot ${slot}] starting fresh ephemeral runner: ${name} -> ${repo:-<scope>}"
        : > "${logf}"
        # tee keeps the runner's logs streaming to the manager (docker compose
        # logs -f) while we also capture them to decide whether it actually
        # connected. The pipeline's status is tee's, so we key off the marker, not
        # docker's exit code (the entrypoint's EXIT trap can mask it anyway).
        set -- docker run --rm \
            --label "${MANAGED_LABEL}" \
            --name "${name}" \
            -e REPO_URL="${repo}" \
            -e ACCESS_TOKEN="${ACCESS_TOKEN}" \
            -e RUNNER_SCOPE="${RUNNER_SCOPE:-repo}" \
            -e ORG_NAME="${ORG_NAME:-}" \
            -e ENTERPRISE_NAME="${ENTERPRISE_NAME:-}" \
            -e RUNNER_NAME="${name}" \
            -e EPHEMERAL=1 \
            -e DISABLE_AUTO_UPDATE=1 \
            -e UNSET_CONFIG_VARS=true \
            -e LABELS="${LABELS}"
        if [ "${RUNNER_NO_DEFAULT_LABELS:-}" = "1" ]; then
            set -- "$@" -e NO_DEFAULT_LABELS=1
        fi
        if [ -n "${RUNNER_GROUP:-}" ]; then
            set -- "$@" -e RUNNER_GROUP="${RUNNER_GROUP}"
        fi
        set -- "$@" "${IMAGE}"
        "$@" 2>&1 | tee "${logf}"

        if grep -q "${CONNECT_MARKER}" "${logf}" 2>/dev/null; then
            # It reached the listener, so it was a real runner. Whatever ended it
            # (ran its one job, idle teardown, a stop signal) is normal — respawn
            # promptly and clear the failure streak.
            fails=0
            wait_s=1
        else
            # Never connected. Grow the delay so a persistent failure can't peg the
            # CPU, and surface the usual causes on the first miss.
            fails=$(( fails + 1 ))
            wait_s=$(( fails * fails * 3 ))
            [ "${wait_s}" -gt "${MAX_BACKOFF}" ] && wait_s="${MAX_BACKOFF}"
            wait_s=$(( wait_s + $(rand_jitter) ))
            echo "[slot ${slot}] runner never reached '${CONNECT_MARKER}' (connect failure #${fails}) — backing off ${wait_s}s before retry."
            if [ "${fails}" -eq 1 ]; then
                echo "[slot ${slot}] If this repeats: (1) host clock skew — on Docker Desktop/WSL2 run 'wsl --shutdown' then restart Docker Desktop; (2) too many workers for this machine — lower the per-repo count (or -Replicas 0 to auto-size); (3) token invalid or under-scoped — needs repo Administration: Read and write (org runner-admin for org scope)."
            fi
        fi
        rm -f "${logf}"

        # Interruptible sleep so a stop signal isn't held off by a long backoff.
        i=0
        while [ "${i}" -lt "${wait_s}" ] && [ "${STOPPING}" -eq 0 ]; do
            sleep 1
            i=$(( i + 1 ))
        done
    done
}

# Spawn slots: per-repo counts from "url=count" entries, or RUNNER_REPLICAS slots
# for org/ent scope (no repo list). Each repo gets its own dedicated slots.
slot=0
if [ -n "${REPOS}" ]; then
    for entry in $(echo "${REPOS}" | tr ',' ' '); do
        url="${entry%%=*}"
        count="${entry##*=}"
        [ "${count}" = "${url}" ] && count=1
        # Short repo name for the runner name so you can see which repo a worker
        # serves in the GitHub UI (e.g. builder-project-a-1).
        repo_slug=$(echo "${url}" | sed 's#/*$##; s#.*/##' | tr -cs 'A-Za-z0-9' '-' | sed 's/-$//')
        n=1
        while [ "${n}" -le "${count}" ]; do
            slot=$((slot + 1))
            run_slot "${slot}" "${url}" "${repo_slug}-${n}" &
            n=$((n + 1))
        done
    done
    echo "[manager:${PROFILE_ID}] started ${slot} slot(s) across the repo list for ${IMAGE}"
else
    while [ "${slot}" -lt "${REPLICAS}" ]; do
        slot=$((slot + 1))
        run_slot "${slot}" "" "${slot}" &
    done
    echo "[manager:${PROFILE_ID}] started ${slot} org/ent slot(s) for ${IMAGE}"
fi

# Block until a stop signal; the trap then tears the runners down.
wait
