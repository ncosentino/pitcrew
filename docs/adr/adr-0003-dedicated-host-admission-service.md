---
title: "ADR-0003: Dedicated host-local admission service"
status: "Accepted"
date: "2026-08-08"
authors: []
tags: ["architecture", "scheduling", "admission", "coordination", "managers"]
supersedes: ""
superseded_by: ""
---

# ADR-0003: Dedicated Host-Local Admission Service

## Context and scope

PitCrew isolates each named profile in its own Compose project, manager container,
state directory, labels, capacity, and cleanup boundary. Fixed and autoscaled managers
therefore reconcile independently even when they share one Docker daemon.

ADR-0002 requires an opt-in host budget with profile costs, reservations, borrowing,
fairness, and protected headroom. Admission must be atomic across concurrently
reconciling managers, survive manager replacement, and preserve every busy or assigned
worker.

No existing manager can safely act as the permanent owner for every profile. A profile
may be stopped, removed, refreshed, or migrated between fixed and autoscaled modes
without the other profiles sharing that lifecycle.

This decision selects the coordination owner, transport, durable lease behavior,
failure posture, and rollback boundary. It does not define measured host budgets,
profile costs, reservation values, or a cross-host scheduler.

### Verified facts

- Every profile manager has the Docker socket; workers never receive it.
- Profile managers and their state directories have intentionally independent
  lifecycles.
- Compatible manager replacement preserves sibling worker containers.
- A manager may disappear while one of its workers continues an active job.
- Setup can inspect exact PitCrew labels on the Docker daemon before mutation.
- The manager image already carries a static Go autoscaler binary and portable shell
  implementation, so a shared static client can serve both modes.
- Docker Compose project-local networks and volumes are not automatically shared
  across profile projects.
- Repository-root bind mounts may target Docker Desktop hosts where Unix socket files
  on the host filesystem are not portable.

### Assumptions

- One Docker daemon is one host-local admission boundary.
- Failing closed for new workers is safer than reclaiming uncertain active capacity.
- Temporary underutilization after ambiguous failure is acceptable; oversubscription
  or busy-job termination is not.
- Exact measured policy can be supplied later without changing the coordination
  mechanism.

## Decision drivers

- Make reservation and release atomic across independent managers.
- Keep worker and manager lifecycle guarantees unchanged.
- Preserve fixed/autoscaled semantic parity.
- Avoid coupling shared ownership to any one profile.
- Avoid network ports, remote credentials, and another externally reachable control
  plane.
- Keep the Docker socket restricted to profile managers.
- Recover conservatively from crashes, stale owners, and hot-swap.
- Make policy generation, decisions, and degraded state observable without exposing
  host identity.
- Support complete rollback to independent profiles.

## Decision

PitCrew will run one dedicated host-local admission service for the single active
admission namespace on a Docker daemon.

The service is infrastructure shared by participating profile managers. It is not a
GitHub scheduler, runner manager, repository poller, or remote fleet controller.

### Ownership and lifecycle

Setup owns creation, verification, compatible replacement, and exact-label cleanup of
the admission service.

The service has:

- a dedicated Compose project and immutable image identity;
- a dedicated internal named volume for its socket and durable state;
- no Docker socket, host pressure mount, worker volume, repository credential, or
  published host port; and
- an exact admission-namespace label independent of profile names.

Profile managers mount the internal admission volume. Workers do not.

The service lifecycle is independent of every profile. Removing or replacing one
profile cannot remove the service while another participating profile remains.

### Transport and trust boundary

Managers communicate with the service through a Unix domain socket in the internal
named volume.

The socket is not created on the repository-root bind mount and is not exposed through
a Docker network or host port. Possession of the manager-only volume is the local
transport boundary; no reusable contract contains a host address or credential.

Fixed shell managers use the same static admission client and protocol as the Go
autoscaler. The client protocol is versioned independently from manager observed-state
contracts.

### Policy and compatibility

Setup publishes one versioned desired host policy and waits for service
acknowledgement before managers enforce it.

Every participating profile supplies:

- its stable profile identity;
- configured abstract unit cost;
- optional reservation and borrowing policy; and
- current demand and exact lease ownership.

The service rejects incompatible policy generations, duplicate profile identity, or a
manager protocol it cannot interpret.

Host admission cannot be described as complete while an active PitCrew profile on the
same admission namespace is unmanaged or incompatible. Setup must either complete a
compatible staged rollout for all participating profiles or retain independent mode.

Setup rejects a second active admission namespace on the same Docker daemon. Profiles
outside the coordinated namespace remain independent and therefore prevent a complete
host guarantee.

The service and client advertise supported protocol ranges. A rolling upgrade
requires an overlapping range, and the service supports the current and immediately
previous client protocol while compatible managers are replaced. Setup keeps the
last compatible service and policy active when no overlap exists; it does not enter a
partially coordinated mode.

### Lease lifecycle

The service is the sole allocator of abstract resource units.

Before JIT generation or worker launch, a manager requests a provisional lease for
one exact profile and slot. The service owns the monotonic expiry clock. A manager may
renew the provisional lease while bounded pre-launch work continues.

The manager creates the exact worker container without starting it, activates the
lease, and starts the container only after activation succeeds. If the provisional
lease expires or renewal/activation is rejected, the manager removes the exact
not-yet-started container and aborts admission. A worker process never starts against
an expired or provisional lease.

Manager recovery includes exact containers in Docker's `created` state rather than
scanning only running workers. A created container with a valid active lease may be
started; one with an expired, missing, or rejected lease is removed exactly and never
passed to log-follow or wait operations.

An active lease is durable and is not reclaimed solely because a manager heartbeat
stops. The worker may still be running while its previous manager is unavailable.

An active lease is released only when:

- the owning manager observes the exact worker exit;
- a replacement manager reconciles the exact slot and proves the worker absent;
- an explicit profile removal completes its existing worker and registration fences;
  or
- an operator performs a separately fenced recovery against exact retained evidence.

This rule may temporarily strand capacity after ambiguous failure. It prevents the
service from granting the same units while an unobserved worker still consumes them.

### Fairness and reservations

The service owns pending demand, reservation accounting, borrowing, and the monotonic
decision sequence across profiles.

Non-borrowable reservations remain unavailable to other profiles. Borrowable
reservation units participate in fair shared admission but are never preempted from an
active worker when their owner later demands them.

Fairness applies only to currently eligible unreserved or borrowable units. It cannot
reorder GitHub jobs or migrate running work.

### Failure posture

Admission-service or client failure blocks only new worker admission.

Existing workers, registrations, accepted profile capacity, and retirement state
remain untouched. Managers publish host-admission degradation separately from GitHub,
Docker, listener, and profile-policy failures.

The service persists policy, leases, ownership epochs, and decision sequence
atomically in its internal volume. Restart restores the last valid state before
serving acquisitions.

Corrupt, missing, or unsupported state fails closed. It is never treated as an empty
budget or permission to launch.

### Rollback

Rollback first publishes independent mode to every participating profile and allows
all active leases to drain or be reconciled.

The service may stop only after no profile still requires coordinated admission and
no active or provisional lease remains. Its internal volume is retained unless an
explicit exact-namespace cleanup confirms no owner and no lease.

If a permanently removed profile leaves an unreconciled active lease, rollback uses
the separately fenced recovery path. Recovery verifies through exact Docker and
retained coordinator evidence that the worker and registration are absent, records a
durable release tombstone, and only then frees the units. Time alone never releases an
active lease.

Rolling back the feature does not stop existing workers or restart the Docker daemon.

## Alternatives considered

### Elect one profile manager as host coordinator

An elected leader avoids another long-running container and can reuse an existing
manager process. Leadership becomes coupled to a profile that may be stopped,
reconfigured, replaced, or removed independently. Every manager needs election,
handoff, and shared-state logic, and a leader hot-swap becomes a host-wide admission
event. The reduced container count does not justify the lifecycle coupling.

### Let managers arbitrate through shared durable files

Managers could lock and rewrite one shared JSON or SQLite state store. This removes a
service process and keeps all logic peer-to-peer.

Correctness would depend on portable cross-container file locking, filesystem
semantics, distributed stale-owner recovery, and every shell/Go manager implementing
the same transaction and fairness algorithm. Repository-root bind mounts also span
Docker Desktop environments where host-filesystem lock and socket behavior is not a
safe public contract.

### Use Docker objects as resource-unit leases

Managers already have Docker access and could create uniquely named containers,
volumes, or labels as atomic tokens. Unit granularity would create operational Docker
objects unrelated to workloads, fairness would remain distributed, and cleanup or
daemon failure could conflate admission state with worker lifecycle. Docker remains
the worker execution owner, not the admission database.

### Coordinate through a network service

A local HTTP service on a shared Docker network provides one atomic owner and simple
clients. It adds network identity, attachment policy, port or DNS ownership, and
spoofing considerations that a manager-only Unix socket avoids. A network transport
may be added later only through a superseding decision.

## Consequences

### Positive

- Atomic allocation and fairness have one owner.
- Coordination survives individual profile manager replacement.
- Neither workers nor the coordinator receive the Docker socket.
- Fixed and autoscaled managers share one protocol and client.
- Ambiguous failure strands capacity rather than oversubscribing the host.
- No host port, remote credential, or private address enters the public contract.
- Host policy and coordinator rollout can be versioned independently from profiles.

### Negative

- PitCrew gains another long-running container, image identity, named volume, and
  lifecycle to operate.
- The admission service is a single host-local availability dependency for new
  workers.
- Conservative active leases may require explicit reconciliation after abnormal
  profile loss.
- Setup must coordinate a host-wide policy while preserving profile-specific locks
  and rollback.
- The manager image must include a versioned client usable from shell and Go paths.

### Neutral

- Exact budgets, costs, reservations, and safety margins remain operator inputs.
- GitHub remains the demand and queue authority.
- This does not implement cross-host steering, preemption, or job migration.
- Independent profiles remain the default when no host admission namespace is
  configured.

## Confirmation

The decision is confirmed when:

- setup and contract tests prove one exact service/volume and no competing active
  namespace per Docker daemon;
- the coordinator starts without Docker access or a published network port;
- fixed and autoscaled clients pass the same protocol conformance fixtures;
- concurrent acquisition never exceeds a synthetic host budget;
- provisional expiry, active-lease persistence, manager handoff, stale-owner
  reconciliation, created-container recovery, and exact release are deterministic;
- coordinator restart restores the last valid policy, leases, epochs, and decision
  sequence;
- unavailable or corrupt state blocks admission without stopping workers;
- mixed incompatible managers cannot claim a complete coordinated guarantee; and
- rollback drains leases before exact service cleanup.

Acceptance records the coordination choice; it does not claim that these confirmation
criteria or the host-resource guarantee are delivered before the implementation stack
is complete.

## References

- [ADR-0002](adr-0002-workload-agnostic-service-classes.md) defines the
  workload-agnostic service-class and reservation boundary.
- [Contributor Architecture](../contributing/architecture.md) defines independent
  profile managers, manager-only Docker access, and busy-worker preservation.
- [Named Profiles](../guides/named-profiles.md) defines profile-specific Compose,
  state, image, and cleanup ownership.
- [Rolling Updates](../guides/rolling-updates.md) defines compatible manager handoff
  and active-worker convergence.
- [Security Boundaries](../guides/security-boundaries.md) defines manager, worker,
  credential, and external-data trust boundaries.
- [Issue #61](https://github.com/ncosentino/pitcrew/issues/61) owns the complete
  host-local admission implementation.
- [Issue #80](https://github.com/ncosentino/pitcrew/issues/80) tracks this coordination
  decision.
