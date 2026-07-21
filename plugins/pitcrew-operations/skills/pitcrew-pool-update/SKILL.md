---
name: pitcrew-pool-update
description: Update an installed PitCrew deployment to a published release through rolling manager handoff, worker convergence, and independent dashboard updates. Use when the user asks to update or upgrade PitCrew itself.
license: MIT
---

# PitCrew Pool Update

Update the PitCrew checkout, hot-swap configured managers, and let workers
converge without interrupting active jobs.

Read these shared references before running commands:

- [operations safety](../../references/safety.md)
- [profile replay](../../references/profile-replay.md)

## Release selection

1. Resolve the PitCrew root and verify its `origin` points to
   `ncosentino/pitcrew`.
2. Require a clean worktree. Never discard local changes.
3. Use a version explicitly named by the user. Otherwise query the latest
   published, non-draft GitHub release with `gh release view --repo
   ncosentino/pitcrew`.
4. If no published release exists, stop. Do not substitute `main`, an arbitrary
   commit, or a pull-request branch.
5. Fetch tags from `origin` and verify the selected release tag resolves to a
   commit in that repository.

## Profile preflight

1. Enumerate configured profiles directly below `.pitcrew-state`.
2. Match each profile to its exact running manager label. Skip and report
   profiles with no running manager so an intentionally stopped profile remains
   stopped; the updated checkout will be used the next time its operator starts
   it.
3. Build the complete replay inputs for every running profile before changing
   the checkout.
4. Record each manager container ID, observed manager contract, desired
   generation, and worker update state. Do not use GitHub's classic runner
   `busy` field as an admission fence.

## Update

1. Record the current commit for diagnosis or an explicit later rollback.
2. Switch the clean deployment checkout to the selected release tag without
   rewriting history.
3. For each running profile, invoke its complete existing setup command with
   `-Refresh`. Omit `-Token` so `Setup-Runner.ps1` securely reuses and validates
   the profile's stored registration token.
4. When setup rejects `-Refresh` because the target release changes worker
   image or build inputs, rerun the same complete setup command without
   `-Refresh`. Setup permits only rolling-compatible changes and fails before
   stopping the manager when registration topology or routing changed.
   Use the same fallback when refresh reports that the unchanged worker image
   is unavailable.
5. Update one profile at a time. Setup builds the replacement manager first,
   stops only the exact manager container, preserves sibling workers, and starts
   the new manager against the same state directory.
6. Never wait for every worker to become idle:
   - Scale-set profiles atomically deregister stale idle JIT runners through
     GitHub's scale-set service, replace them immediately, and retain assigned
     runners until their one job finishes.
   - Fixed profiles preserve existing classic runners and apply a changed worker
     image as those ephemeral runners naturally turn over. GitHub's classic
     runner deletion API is forceful, so it is not used as an idle fence.
7. If the user requested the complete PitCrew deployment update, run the
   `pitcrew-dashboard-update` workflow independently. A pending worker rollout
   must never block the dashboard and connector update.

## Verification

For every refreshed profile, verify:

- the checkout commit matches the selected release tag
- the manager container was replaced and is running
- the replacement manager reports the current manager contract
- `observed-state.json` is fresh and reports `managerStatus: running`
- the desired generation is accepted
- `update.targetRevision` matches the stored static worker revision

For fixed profiles, verify desired capacity remains intact. `update.status:
rolling` is valid while pre-revision or old-image workers finish naturally.

For autoscaled profiles, verify `configuredSlots` and
`autoscaling.maximumSlots` match the configured maximum,
`desiredSlots == autoscaling.targetSlots <= autoscaling.maximumSlots`, and the
autoscaling status is not degraded. Zero desired, active, idle, or online
runners is valid when demand and `minimumIdleSlots` are zero.

`update.status: rolling` is successful partial convergence, not a failed
manager update. Report `currentWorkers` and `staleWorkers`; do not wait for
busy stale workers to finish.

If a profile fails, stop and report the target release, previous commit, and
which profiles completed. Do not automatically reset the checkout or claim the
update succeeded.
