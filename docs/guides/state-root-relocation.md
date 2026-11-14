---
description: Experimental guarded relocation of one profile between roots on the same Docker engine.
---

# State-root relocation

`Move-RunnerProfile.ps1` is an experimental, manager-only relocation command.
It defaults to a read-only dry run. It does not move a Docker engine, workers,
external volumes, service networks, or the connector and support services.
Do not treat its disposable fixed-worker CI evidence as qualification of
autoscaled listeners, real credentials, or Windows-to-WSL operation.

## Preconditions

Use matching relocation, shared lifecycle, Compose, and schema code at both roots.
The destination must have no state, environment, or private deployment material
for the selected profile. Linux destinations must be native ext4. Shared
host-admission configurations are not supported.

Both roots must use the same Docker engine and existing manager and worker images.
The source must have one fresh running manager supporting non-destructive handoff.
Disable obsolete tooling and connector startup that could write the retired root
without checking the new relocation guard. No worker-directed command, image build,
image pull, Docker restart, or host restart belongs to this procedure.

## Dry run and apply

Select one profile and an empty destination profile root:

```powershell
.\Move-RunnerProfile.ps1 -Profile example `
    -SourceRoot 'C:\runner-source' -DestinationRoot '/opt/runner-target' `
    -TargetDistribution 'Runner-Ubuntu'
```

After reviewing the dry run, add `-Apply`, `-ExpectedEngine`,
`-ExpectedManagerInstanceId`, `-ExpectedGeneration`, and
`-ExpectedDesiredStateHash` with current, exact source evidence. Do not print
environment files or private keys to obtain this evidence.

Apply holds the source lock, stages deployment material, fences the source,
quiesces only its manager, and copies final state after manager exit.
Authentication is transferred internally; native private directories are protected.
Stored external manifests and build contexts are materialized below
`.pitcrew-deployment`, outside git. Identical relocated build inputs retain their
existing worker revision; changed bytes or arguments do not.

Startup requires matching image identities, preserved session ownership and
desired state, a new manager instance, and a fresh acknowledgement. The committed
target admits ordinary profile operations. The retired source rejects them through
the shared profile lock.

## Failure and explicit rollback

Never start a second manager to guess whether target startup succeeded.
Startup uncertainty remains durably fenced. Inspect the exact operation receipts
and manager identity first. Raw Docker commands and obsolete scripts are not
protected by these guards.

Use `-Action rollback -Apply` with the original source and destination arguments
and the current target instance, generation, and desired-state hash. Rollback
quiesces the target and returns its latest durable state, not a stale snapshot.
A separate worker or manager image rollout must be reversed separately first.
Failure remains explicit; do not delete receipts to force admission.

Connector identity, recovery and command ledgers, support replay state, ACLs,
fleet uploads, and service persistence require their own qualified migration.
Profile relocation alone does not constitute a migrated node.
