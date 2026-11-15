---
description: Experimental guarded relocation of one profile between roots on the same Docker engine.
---

# State-root relocation

`Move-RunnerProfile.ps1` is an experimental, manager-only relocation command.
It defaults to a read-only dry run. It does not move a Docker engine, workers,
external volumes, service networks, or the connector and support services.
The disposable CI fixture qualifies the product command, failure fencing and
latest-state rollback. A same-engine Windows-to-WSL deployment has additionally
qualified protected credential transport, existing built-image provenance,
fresh autoscaled listener evidence and fixed-worker preservation. These checks
do not qualify a different Docker engine or a host restart.

## Preconditions

Use matching relocation, shared lifecycle, Compose, and schema code at both roots.
The destination must have no state, environment, or private deployment material
for the selected profile. Linux destinations must be native ext4. Shared
host-admission configurations are not supported.
Native apply and recovery require root authority because managers own protected
state. Windows-to-WSL target actions run as the explicitly selected distro's root.

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
Ordinary setup reuses stored keys in the exact relocation-owned private directory
only after a committed relocation. Keys must remain unlinked, untracked and
gitignored, with private file and profile-directory permissions on Linux.
Explicit authentication parameters still require a key outside the checkout.
Stored external manifests and build contexts are materialized below
`.pitcrew-deployment`, outside git. Identical relocated build inputs retain their
existing worker revision. Mode-independent source bytes and the native mode
baseline are qualified separately; later changes to bytes, arguments, or native
permissions do not masquerade as unchanged provenance.

Startup requires matching image identities, preserved session ownership and
desired state, a new manager instance, and a fresh acknowledgement. The committed
target admits ordinary profile operations. The retired source rejects them through
the shared profile lock.
Windows sources also make that lock read-only, blocking obsolete setup versions
that require the same read/write lock. Explicit recovery retains an exclusive
read-only lease; normal write access returns only after the source is active again.

After acceptance, require another fresh target publication and verify that the
source has stopped publishing. For active autoscaled targets, successful
`session-create`, `session-refresh` or `message-poll` evidence belongs to
`subsystemHealth.github.lastSuccess`, not necessarily the bounded event journal.
The success must postdate the replacement manager's startup, and each active
target must have fresh GitHub statistics. Preserve any explicitly reviewed
pre-existing degraded condition without reporting it as healthy; stop on a new
or unexplained failure.

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
