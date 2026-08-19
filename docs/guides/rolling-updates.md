---
description: Replace PitCrew managers and converge worker images without interrupting active GitHub Actions jobs.
---

# Rolling Updates

PitCrew manager contract 9 separates manager replacement from worker
replacement. Updating a manager no longer requires every runner in its profile
to be idle.

## Manager handoff

`Setup-Runner.ps1 -Refresh`:

1. builds the replacement manager while the current manager is running;
2. stops only the exact manager container for the selected profile;
3. leaves sibling worker containers and GitHub registrations untouched;
4. starts the replacement manager against the same durable state directory;
5. waits for the new manager contract to acknowledge the desired generation.

The replacement manager discovers workers by exact profile and slot labels,
adopts them, and resumes reconciliation. Busy jobs and idle registrations remain
connected throughout the handoff.

Plain refresh never starts a profile with no running manager, because that
profile may be intentionally stopped. After bounded diagnosis confirms an
unexpected missing manager, replay the exact existing setup command with
`-Refresh -RecoverMissingManager`. This explicit opt-in is rejected when a
manager is already running, preserves every worker, and requires the recovered
manager to acknowledge the desired generation before setup succeeds.

Fixed managers receive 60 seconds to acknowledge the generation; autoscaled
managers receive 180 seconds so scale-set recovery and listener establishment
can complete without a false handoff failure. If verification times out while
the replacement manager is still running, setup leaves it running and reports
the incomplete verification without attempting rollback. If the replacement
failed to start or exited, setup restores the previous environment and state,
retags the previous images, restarts the prior manager, and requires that
manager to republish the previous acknowledgement before rollback succeeds.
Worker containers are untouched in every path.

The first upgrade from a pre-contract-9 manager removes that exact legacy
manager without sending its destructive shutdown signal. A stable scale-set
session owner is persisted so the replacement listener can reconnect to the
existing scale set.

If that first replacement fails after the legacy manager is removed, PitCrew
leaves workers running and reports the failure. It does not restart the legacy
manager because its startup cleanup would destroy those preserved workers.
The previous worker image tag is restored before setup returns. Correct the
manager startup problem and rerun the same setup command.

Manager termination defaults to preservation. Use `Setup-Runner.ps1 -Down` for
an intentional full profile shutdown; setup publishes a container-targeted
shutdown request before Compose removes the manager and workers.

## Worker convergence

Every new worker carries a SHA-256 worker revision label. After handoff,
`observed-state.json` reports:

- `update.status`: `current`, `rolling`, or `degraded`
- `update.targetRevision`
- `update.currentWorkers`
- `update.staleWorkers`
- `update.lastError`

Scale-set profiles replace stale idle JIT workers immediately. GitHub's
scale-set service atomically refuses removal when a job is assigned, so PitCrew
keeps that busy worker until its one job finishes. Unknown API failures preserve
the worker and surface a degraded rollout instead of stopping it.

Fixed profiles also hot-swap their manager, but classic GitHub runner deletion
is a force-removal API rather than an idle-only fence. PitCrew therefore leaves
existing fixed workers alone and applies a changed image as those ephemeral
workers naturally complete jobs and turn over. Use scale-set mode when immediate
idle-worker replacement is required.

## Compatible changes

Manager implementation, worker image/build inputs, and scale-set tuning can roll
without an all-idle maintenance window.

Registration topology and routing changes still require an explicit stop:

- fixed mode to or from scale-set mode
- repository, organization, or enterprise scope
- runner group
- runner name prefix
- labels or default-label policy

Setup rejects these changes before stopping the current manager. Run the
profile's exact `-Down` command, then replay its complete setup command.

## Copilot updates

The `pitcrew-pool-update` skill treats a fresh manager with
`update.status: rolling` as a successful update. It reports remaining stale
workers instead of waiting for active jobs.

Dashboard and connector updates are independent. A pending worker rollout must
not block `pitcrew-dashboard-update`.
