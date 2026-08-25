#!/bin/sh
# container-monitor-group-leader.sh <window_seconds> <kill_after_seconds> \
#   <drain_timeout_seconds> <command...>
#
# Runs as the sole, stable process-group leader for one docker logs/wait
# monitor invocation (launched via `setsid sh container-monitor-group-leader.sh
# ...` so this script's own pid becomes both its process id and its process
# group id). Independent reconciliation can only trust a recorded process
# group belongs to this exact monitor cycle by re-checking THIS pid's own
# /proc/<pid>/stat starttime immediately before it ever signals it; that proof
# is only sound while this exact pid stays alive, so this leader deliberately
# outlives its own direct child until its whole process group is empty,
# rather than exiting the moment that child exits. It ignores TERM for itself
# so a group-wide TERM used to reach a stubborn descendant does not also
# collapse the leader before a bounded KILL escalation can still reach it;
# only KILL (uncatchable) ever actually ends it early.
#
# The bounded window/escalation is implemented here directly, rather than by
# wrapping the command in `timeout`: `timeout` only waits for its own direct
# child and, without --foreground, gives that child its own new process group
# distinct from a parent that only setsid'd `timeout` itself into a leader
# role, silently detaching the very descendants this leader exists to keep
# tracked. Running the command as this script's direct child instead keeps
# everything it forks in this one setsid-created group for the process's
# entire life.
set -u

leader_window_seconds="$1"
shift
leader_kill_after_seconds="$1"
shift
leader_drain_timeout_seconds="$1"
shift

trap ':' TERM

leader_pid=$$

# Escalation and the final drain both need "is anything besides me still in
# my group" rather than just "is my direct child still alive": a stubborn
# descendant that outlives its own parent (e.g. a forked helper the monitored
# command spawns and exits without reaping) would otherwise never trigger
# TERM/KILL at all, because only the direct child's liveness was ever polled.
container_monitor_group_has_other_member() {
    leader_group_has_other_member=0
    for leader_stat_path in /proc/[0-9]*/stat; do
        [ -e "${leader_stat_path}" ] || continue
        leader_candidate_pid=${leader_stat_path#/proc/}
        leader_candidate_pid=${leader_candidate_pid%/stat}
        [ "${leader_candidate_pid}" != "${leader_pid}" ] || continue
        leader_candidate_line=$(cat "${leader_stat_path}" 2>/dev/null) || continue
        leader_candidate_remainder=${leader_candidate_line##*') '}
        [ -n "${leader_candidate_remainder}" ] || continue
        # This enumeration only ever answers "should I keep waiting"; it never
        # selects a kill target. Actual signals are always sent to this
        # leader's own recorded, identity-validated pid/pgid by the caller.
        set -- ${leader_candidate_remainder}
        [ "$#" -ge 3 ] || continue
        if [ "$3" = "${leader_pid}" ]; then
            leader_group_has_other_member=1
            break
        fi
    done
    [ "${leader_group_has_other_member}" -eq 1 ]
}

"$@" &
leader_child_pid=$!

leader_window_deadline_epoch=$(($(date +%s) + leader_window_seconds))
while container_monitor_group_has_other_member; do
    [ "$(date +%s)" -lt "${leader_window_deadline_epoch}" ] || break
    sleep 1
done
if container_monitor_group_has_other_member; then
    kill -TERM -"${leader_pid}" 2>/dev/null || true
    leader_kill_deadline_epoch=$(($(date +%s) + leader_kill_after_seconds))
    while container_monitor_group_has_other_member; do
        [ "$(date +%s)" -lt "${leader_kill_deadline_epoch}" ] || break
        sleep 1
    done
    if container_monitor_group_has_other_member; then
        kill -KILL -"${leader_pid}" 2>/dev/null || true
    fi
fi

# wait can return before the child truly exits when a trapped signal (our own
# no-op TERM trap) is delivered while blocked; kill -0 distinguishes that from
# genuine exit so this loop always settles on the child's real termination.
while kill -0 "${leader_child_pid}" 2>/dev/null; do
    wait "${leader_child_pid}" 2>/dev/null || true
done
wait "${leader_child_pid}" 2>/dev/null || true

leader_deadline_epoch=$(($(date +%s) + leader_drain_timeout_seconds))
while container_monitor_group_has_other_member; do
    [ "$(date +%s)" -lt "${leader_deadline_epoch}" ] || break
    sleep 1
done
exit 0
