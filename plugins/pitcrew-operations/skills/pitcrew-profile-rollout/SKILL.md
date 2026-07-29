---
name: pitcrew-profile-rollout
description: Safely apply one operator-approved external PitCrew profile image revision after a read-only dry run, preserving credentials, capacity, routing, topology, and active jobs while reporting rolling worker convergence and an exact rollback contract.
license: MIT
---

# PitCrew Profile Rollout

Apply one reviewed external profile manifest to one configured PitCrew profile.
The repository that owns the image publishes it; this skill only performs the
operator-approved host rollout.

Read these shared references before running commands:

- [operations safety](../../references/safety.md)
- [profile replay](../../references/profile-replay.md)

## Non-negotiable boundaries

- Never restart Docker, Docker Desktop, the Docker daemon, or the host.
- Never stop, restart, kill, pause, remove, or enter a worker container.
- Never run `Setup-Runner.ps1 -Down`, Compose teardown, prune, or name-pattern
  cleanup as part of a rolling image update.
- Never read or print environment files, registration tokens, registry
  credentials, connector identities, JIT payloads, or job output.
- Never accept an image reference or manifest path from an untrusted workflow
  event. The operator must explicitly identify the reviewed local manifest.
- Never combine an image rollout with registration topology, routing, capacity,
  or credential changes.
- Never use `-Refresh` or `-CapacityOnly` for a worker-image change.

## Resolve the rollout

1. Resolve exactly one PitCrew root and verify its `origin` points to
   `ncosentino/pitcrew`.
2. Require a clean PitCrew checkout. Do not discard local changes.
3. Resolve one configured profile below `.pitcrew-state`.
4. Require the candidate external manifest path from the operator. Resolve it
   to an existing file and validate it against `runner-profile.schema.json`.
5. Read only:
   - `static-profile.json`
   - `desired-capacity.json`
   - `acknowledged-capacity.json`
   - `observed-state.json`
6. Resolve the candidate with `Resolve-RunnerProfile`, preserving the stored
   scope, targets, capacity, organization or enterprise identity, and any
   command-line overrides that differ from the manifest.

## Compatibility gate

Build the current and candidate static configurations without pulling or
building the candidate image. Compare
`Get-RunnerRollingCompatibilityConfiguration` for both.

Stop before mutation if the candidate changes registration topology or routing,
including:

- profile name
- labels or default-label policy
- repository, organization, or enterprise scope
- organization or enterprise identity
- runner group
- runner name prefix
- fixed versus scale-set mode

Report image reference, verification, build-input, resource-policy, and
scale-set tuning differences separately. List read-only external volume
additions, removals, and source changes by logical name; they are
rolling-compatible worker changes, not routing changes. Capacity must remain
exactly equal to the accepted desired-capacity document.

## Dry-run mode

Always dry run first. Display:

1. installation and profile
2. current approved manifest source and SHA-256 when available
3. candidate manifest path and SHA-256
4. current and candidate image references
5. current resolved image ID and worker revision
6. preserved scope, targets, capacity, labels, runner group, prefix, and mode
7. every rolling-compatible difference
   - for read-only volumes, show only logical name, external Docker volume name,
     and derived `/mnt/pitcrew-data/<name>` target
8. the complete setup command that would run, with secret-free arguments and
   the candidate `-ProfilePath`
9. the prior stored manifest snapshot that defines explicit rollback
10. all prohibited actions that will not occur

Change nothing during the dry run.

## Apply

After explicit operator confirmation of the dry-run plan:

1. Record the exact manager container ID, manager contract, target image
   reference/ID, worker revision, desired generation, and update projection.
2. Invoke the complete setup command with the candidate `-ProfilePath`.
3. Preserve every stored target and capacity value.
4. Omit `-Token` so setup securely reuses and validates the selected profile's
   stored registration credential.
5. Let setup pull or build and verify the candidate before manager handoff.
   Setup must also inspect every declared external volume and attach it
   read-only to candidate verification.
6. Stop on the first failure. Do not retry with a weaker command or route.

## Verification

Verify:

- exactly one replacement manager is running
- observed state is fresh and reports `managerStatus: running`
- the desired generation and capacity remain unchanged
- `update.targetImage` matches the candidate reference
- `update.targetImageId` matches the resolved candidate image identity
- `update.targetRevision` matches static-profile state
- `update.currentWorkers` and `update.staleWorkers` are nonnegative
- `update.lastError` is null

`update.status: rolling` is successful partial convergence. Report current and
stale workers and stop; do not wait for busy stale workers to finish.

## Rollback

The rollback input is the previous stored manifest document and source
directory recorded before mutation. Rehydrate that exact non-secret snapshot
beside its original source when necessary, replay the same complete setup
command, and delete only the exact temporary manifest afterwards.

Never roll back automatically after the new manager has accepted work. Report
the prior image reference, image ID, worker revision, and the exact rollback
command so the operator can choose deliberately.

PitCrew never creates, populates, removes, or inspects driver options for an
external data volume. Missing volumes reject the rollout before manager
handoff.
