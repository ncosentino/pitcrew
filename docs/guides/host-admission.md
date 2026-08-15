---
description: Configure, validate, troubleshoot, update, and roll back PitCrew host-local admission without editing coordinator state.
---

# Host-Local Admission Operations

Host-local admission is an opt-in manager contract that limits new PitCrew
worker starts across participating profiles on one Docker host. It coordinates
an abstract, measurement-derived unit budget; it does not discover CPU or
memory capacity and does not reserve operating-system resources.

## Routing eligibility is not host admission

GitHub labels, runner groups, and scale sets decide which runners are eligible
for a queued job. They do not reserve capacity on the Docker host.

PitCrew host admission acts later, when a participating manager is ready to
start a worker. It can grant or withhold that start according to the shared
host policy. It does not:

- reorder the GitHub queue or make GitHub assign a job to this host;
- preempt, migrate, or cancel a running job;
- constrain profiles that do not participate in the namespace;
- constrain non-PitCrew containers or other host processes; or
- turn policy units into CPU cores, memory bytes, worker counts, or latency
  guarantees.

Do not claim protected headroom merely because a manifest contains
`reservationUnits`. Treat protection as established only after every relevant
profile participates, each publishes `hostAdmission.status: available`, and a
controlled validation demonstrates the expected admission behavior.

## Calibrate service classes

Create separate profiles for workloads that need different routing and host
admission treatment. Workflow labels select the profile; host-admission fields
control new-worker admission for that profile:

| Field | Scope | Meaning |
| --- | --- | --- |
| `namespace` | Host | Coordinator identity shared by every participating profile. |
| `capacityUnits` | Host | Abstract calibrated capacity before the safety margin. |
| `safetyMarginUnits` | Host | Units kept outside the admission budget. |
| `workerCostUnits` | Profile | Whole units consumed by each newly admitted worker. |
| `reservationUnits` | Profile | Units available to this profile before it uses shared capacity. |
| `borrowable` | Profile | Whether other profiles may use this profile's unused reservation. |

The effective budget is `capacityUnits - safetyMarginUnits`. The sum of all
profile reservations must fit inside that budget. A reservation can contain a
remainder smaller than one worker cost; grants still occur only in whole
`workerCostUnits` increments.

The following fragments are fully synthetic. Their values illustrate policy
shape only and were not measured on a real host:

```json
{
  "name": "interactive-ci",
  "hostAdmission": {
    "namespace": "shared-ci",
    "capacityUnits": 20,
    "safetyMarginUnits": 4,
    "workerCostUnits": 4,
    "reservationUnits": 8,
    "borrowable": false
  }
}
```

```json
{
  "name": "batch-ci",
  "hostAdmission": {
    "namespace": "shared-ci",
    "capacityUnits": 20,
    "safetyMarginUnits": 4,
    "workerCostUnits": 2,
    "reservationUnits": 4,
    "borrowable": true
  }
}
```

In this example, the effective budget is 16 units. The interactive profile's
unused reservation remains unavailable to the batch profile. The batch
profile's unused reservation may enter the shared pool. Neither rule says how
many CPU cores or bytes a worker needs; derive costs and margins from repeated,
controlled measurements of the actual worker classes and host.

### Fairness limits

Admission uses a profile's own reservation first. It then protects unused
non-borrowable reservations and divides the currently available shared pool
into rotating unit shares among profiles with registered pending demand.
Integer remainders rotate so one profile is not permanently favored.

This is unit fairness between profiles, not weighted workload scheduling:

- GitHub queue depth does not create a larger fairness weight.
- A higher worker cost does not create higher priority.
- Equal unit opportunity can produce different worker counts when costs differ.
- Whole-worker grants can leave a unit fragment temporarily unused.
- A grant never revokes another profile's active or provisional lease.

## Enable admission

Add `hostAdmission` to each reviewed external profile manifest. Every profile
in one namespace must use the same `capacityUnits` and
`safetyMarginUnits`. Apply each manifest through the normal complete setup
path, preserving its routing and desired capacity:

```powershell
.\Setup-Runner.ps1 `
    -ProfilePath .\profiles.local\interactive-ci.json `
    -Repos https://github.com/example/interactive-project=2

.\Setup-Runner.ps1 `
    -ProfilePath .\profiles.local\batch-ci.json `
    -Repos https://github.com/example/batch-project=4
```

Setup validates the manifest, starts the dedicated coordinator when needed,
publishes the combined policy, and hands the selected manager its generated
policy identity. Do not start a coordinator container manually, edit generated
host state, or use broad Docker cleanup.

Already-running fixed and autoscaled workers are adopted into durable active
accounting during manager recovery. Adoption never stops, recreates, or denies
those workers, including when their retained usage exceeds the effective
budget. In that case `availableUnits` clamps to zero and new acquisitions remain
withheld until natural worker exit releases enough usage. A transient
coordinator outage delays accounting but does not mutate the worker; recovery
retries the same deterministic lease identity. Both manager modes withhold new
launches host-wide while any participating profile manager still has an
incomplete adoption pass. Setup establishes that durable fence before manager
handoff; multiple profile fences compose, survive coordinator restart, and
clear independently only after the corresponding manager finishes recovery.
Withheld attempts during that fence carry the bounded `adoption-pending`
failure category rather than being reported as ordinary budget exhaustion.
Protocol 1 remains available for ordinary commands during a coordinator-first
rolling replacement, but adoption and fence operations require protocol 2. A
new manager connected to a protocol 1 service therefore fails closed before
starting new workers.

There is an unavoidable partial-enrollment interval while multiple live
profiles are applied one at a time. During that interval, do not describe the
host as protected. Validate every participating profile before relying on the
policy.

## Validate the active policy

Read the credential-free observed state for every participating profile:

```powershell
$state = Get-Content .pitcrew-state\interactive-ci\observed-state.json |
    ConvertFrom-Json
$state.hostAdmission | ConvertTo-Json -Depth 8
$state.capacityEvidence | ConvertTo-Json -Depth 8
```

An operational profile should report:

- `status: available`;
- the expected namespace, non-null epoch, and decision sequence;
- the configured capacity and safety margin plus their effective total;
- current available units and non-null host/profile policy fingerprints;
- unit cost, reservation, borrowing policy, active, provisional, held, and
  borrowed units;
- non-null pending and withheld units after demand has been republished; and
- a bounded last decision when a lease operation has occurred.

Take at least two fresh samples. `epoch` is the durable coordinator epoch and
advances when policy is applied, while `decisionSequence` advances for
successful durable lease mutations. A denied decision may update
`lastDecision` without advancing that sequence.

Run a controlled synthetic workload before making an operational guarantee.
Confirm that non-borrowable headroom is withheld from another profile, unused
borrowable reservation can be consumed, and demand recovers after capacity is
released. Keep GitHub assignment evidence separate from the host-admission
evidence.

## Interpret status and accounting

| Status | Interpretation |
| --- | --- |
| `disabled` | This profile has no host-admission policy. Every other admission field is `null`. |
| `available` | Namespace, policy identity, coordinator accounting, and current demand are compatible. |
| `degraded` | The coordinator responded, but policy identity, profile identity, or demand freshness is incomplete or incompatible. |
| `unavailable` | The configured namespace is known, but coordinator measurements could not be read. Measured fields are `null`, not zero. |

Accounting is profile-scoped:

- `activeUnits` are held by active worker leases.
- Existing workers adopted when policy is enabled contribute to `activeUnits`
  exactly like newly activated workers.
- `provisionalUnits` are held while a worker is being prepared.
- `heldUnits` is active plus provisional units.
- `borrowedUnits` is held capacity beyond this profile's reservation.
- `pendingUnits` is the latest outstanding worker demand converted to units.
- `withheldUnits` is that outstanding demand not yet admitted.

The coordinator's full multi-profile lease ledger is not published. A profile
view can prove its own held, pending, and withheld units, but it may not identify
which other profile holds shared capacity.

Capacity-deficit reasons remain distinct:

| Reason | Meaning |
| --- | --- |
| `host-admission-withheld` | Current demand was denied by host budget, protected reservation, or shared-pool fairness. |
| `host-admission-degraded` | New admission is blocked by incompatible or stale coordination evidence. |
| `host-admission-unavailable` | New admission is blocked because the coordinator cannot be used. |
| `admission-ceiling` | The profile's separate `maximumActiveWorkers` ceiling blocked admission. |

GitHub demand, Docker, JIT, listener, cleanup, and missing-evidence reasons are
separate signals. Do not relabel them as host-admission failures.

## Update policy

### Profile-local fields

To change `workerCostUnits`, `reservationUnits`, or `borrowable`, replay the
complete setup command with a reviewed candidate manifest. Existing leases are
not preempted. Pause and drain first when a clean policy boundary is required.
Run `-Pause` with the currently applied manifest before changing that source
file, then apply the candidate:

```powershell
.\Setup-Runner.ps1 `
    -ProfilePath .\profiles.local\interactive-ci.json `
    -Pause

# After the profile drains, replace the file with the reviewed candidate.
.\Setup-Runner.ps1 `
    -ProfilePath .\profiles.local\interactive-ci.json `
    -Repos https://github.com/example/interactive-project=2
```

The second command uses the updated manifest and resumes the requested
capacity. Validate a new epoch, the expected profile policy fingerprint, and
fresh demand accounting.

### Host-wide fields or namespace

`capacityUnits`, `safetyMarginUnits`, and `namespace` must remain coherent
across the host. Setup rejects an in-place host-wide change while another
profile retains the old common values. There is no atomic multi-profile policy
update.

For a capacity or safety-margin change in the same namespace, choose one
supported path after saving reviewed rollback manifests and complete commands:

- **Staged replacement:** pause and drain all participants, run `-Down` for
  every profile except one, apply the new host-wide values to the remaining
  profile, then re-enroll the other profiles with matching values. This can
  resume one profile earlier, but the host has no complete cross-profile
  guarantee during the partial rollout.
- **Full replacement:** pause and drain all participants, run `-Down` for every
  profile, update every manifest, and reapply every complete command. The last
  removal stops the empty coordinator. This creates a simpler rollback boundary
  at the cost of a complete pool outage.

A namespace change always uses full replacement because a live coordinator
namespace cannot change in place.

For either path, wait for active and provisional units to reach zero before
each removal. Validate every profile as `available` under the new policy and
epoch before claiming protection.

## Disable or roll back

To remove one profile from coordination:

```powershell
.\Setup-Runner.ps1 -ProfilePath .\profiles.local\batch-ci.json -Pause
.\Setup-Runner.ps1 -ProfilePath .\profiles.local\batch-ci.json -Down

.\Setup-Runner.ps1 `
    -ProfilePath .\profiles.local\batch-ci-without-admission.json `
    -Repos https://github.com/example/batch-project=4
```

Wait for `activeUnits`, `provisionalUnits`, and `heldUnits` to reach zero before
`-Down`. The re-enabled profile is now outside host coordination and can
compete with participating profiles, so the host no longer has a complete
cross-profile guarantee.

For a full rollback, pause and drain every participant, run `-Down` for every
participant, then reapply the saved manifests without `hostAdmission`. The
coordinator is removed only after the namespace has no policy entries and no
leases. Never delete its volume or edit lease state to force rollback.

If `-Down` reports retained leases, do not bypass the fence. Reapply the
current reviewed manifest with the complete setup command and `-Refresh` so a
replacement manager can perform exact lease reconciliation, then pause, verify
zero held units, and retry `-Down`.

## Troubleshoot admission

### Withheld demand

Signal: `status` is `available`, `pendingUnits` and `withheldUnits` are
positive, and a target reports `host-admission-withheld`.

If `availableUnits` is smaller than one `unitCost`, the aggregate free budget
cannot admit that worker. If enough aggregate units appear free, protected
non-borrowable reservation or rotating shared-pool fairness may be controlling
the grant. Positive contender demand expires after 30 seconds without a
`SetDemand` or lease-acquisition refresh, so an absent manager cannot protect
that share indefinitely. The profile-scoped projection cannot prove which other
profile owns the remaining units.

### Stale coordination

Signal: `status` is `degraded`, or pending and withheld units are `null` after
an epoch change, coordinator restart, policy replacement, or demand expiry.

Take a fresh sample after the manager has had time to republish demand. If the
state remains degraded, compare the namespace and policy fingerprints with the
reviewed manifests and verify that the manager's observed state is current.
Null demand is unavailable evidence, not zero demand.

### Exhausted budget

Signal: positive withheld units, `availableUnits < unitCost`, and the bounded
last decision may carry `failureCategory: budget-exceeded`.

Reduce demand, wait for an existing worker lease to release, or apply a
reviewed policy update. Do not translate the unit shortfall into CPU or memory
without a separate measurement.

Retained workers adopted during policy enablement may make `heldUnits` exceed
`effectiveTotalUnits`. This is truthful overcommit accounting, not coordinator
corruption: `availableUnits` remains zero and new acquisition stays blocked
until the adopted leases drain naturally.

### Invalid or incompatible policy

Setup rejects invalid arithmetic, inconsistent host-wide values, namespace
replacement over a live policy, and removal while the profile still owns
leases. Correct the external manifest and replay the complete command.

An already-running profile may report `degraded` when it is unknown to the
coordinator or its policy identity differs. Reapply the reviewed manifest;
never edit generated policy, fingerprints, or coordinator state.

### Coordinator failure

Signal: `status` is `unavailable`,
`host-admission-unavailable` appears in capacity evidence, and measured
admission fields are `null`. Existing workers continue; only new admission
stops.

Collect read-only diagnostics first. To restore the coordinator through the
supported path, replay one participating profile's complete current setup
command with `-Refresh`. This starts the coordinator from durable state before
the manager handoff and preserves compatible workers:

```powershell
.\Setup-Runner.ps1 `
    -ProfilePath .\profiles.local\interactive-ci.json `
    -Refresh `
    -Repos https://github.com/example/interactive-project=2
```

`-RecoverManager` is a manager-only operation and is not a coordinator repair.
If durable coordinator state is unreadable, preserve the evidence and stop;
do not delete or rewrite state to make admission resume.
