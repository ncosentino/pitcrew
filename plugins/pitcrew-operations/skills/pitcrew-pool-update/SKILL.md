---
name: pitcrew-pool-update
description: Update an installed PitCrew runner pool to a published PitCrew release, then refresh each configured profile through Setup-Runner.ps1. Use when the user asks to update or upgrade PitCrew itself.
license: MIT
---

# PitCrew Pool Update

Update the PitCrew checkout and deliberately refresh its configured managers.

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
4. Query GitHub's self-hosted runner API at each stored repository,
   organization, or enterprise scope. Match PitCrew runners by the stored name
   prefix and profile label.
5. Check again immediately before refreshing each profile. If any matching
   runner is busy, stop without updating that profile. Continuous workflow
   traffic requires an operator-arranged maintenance window because GitHub can
   assign a job after an idle check.

## Update

1. Record the current commit for diagnosis or an explicit later rollback.
2. Switch the clean deployment checkout to the selected release tag without
   rewriting history.
3. For each idle profile, invoke its complete existing setup command with
   `-Refresh`. Omit `-Token` so `Setup-Runner.ps1` securely reuses and validates
   the profile's stored registration token.
4. When setup rejects `-Refresh` because the target release changes worker
   image, build, labels, scope, or another worker-profile setting, verify again
   that matching runners are idle and rerun the same complete setup command
   without `-Refresh`. That path prepares and verifies the changed worker image
   before replacing the selected profile.
   Use the same fallback when refresh reports that the unchanged worker image
   is unavailable.
5. Update one profile at a time. Both refresh and static-profile replacement
   intentionally stop that profile; neither may restart Docker or affect
   another profile.

## Verification

For every refreshed profile, verify:

- the checkout commit matches the selected release tag
- the manager container was replaced and is running
- `observed-state.json` is fresh and reports `managerStatus: running`
- desired and active slots return to the configured counts
- matching GitHub runners return online

If a profile fails, stop and report the target release, previous commit, and
which profiles completed. Do not automatically reset the checkout or claim the
update succeeded.
