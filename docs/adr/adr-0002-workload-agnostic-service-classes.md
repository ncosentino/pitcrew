---
title: "ADR-0002: Workload-agnostic service classes"
status: "Accepted"
date: "2026-08-08"
authors: []
tags: ["architecture", "scheduling", "profiles", "admission"]
supersedes: ""
superseded_by: ""
---

# ADR-0002: Workload-Agnostic Service Classes

## Context and scope

PitCrew profiles isolate runner registration, labels, manager state, images,
capacity, cleanup, and observed state. Explicit labels keep specialized jobs from
being consumed by broad runner requests.

Queue isolation alone does not isolate the Docker host. Independent profiles can
each admit workers as though they own the machine, so aggregate demand can exceed
the host's tested operating envelope. Workloads also have different operating
objectives: some favor immediate, bounded execution while others favor throughput
or may wait for spare capacity.

This decision defines how PitCrew represents those execution objectives. It does
not define repository automation, issue policy, prompts, schedules, or another
system's work-item semantics.

### Verified facts

- GitHub performs event triggering, queueing, and label matching. PitCrew can
  control which runner registrations exist, but it cannot reorder GitHub's queue.
- Named profiles provide distinct labels, managers, state, images, and capacity on
  one Docker host.
- Workers execute one job and are destroyed. Busy or assigned workers are preserved
  during compatible updates and capacity reduction.
- Workers do not receive the host Docker socket.
- Per-worker resource policy and per-profile active-worker ceilings do not yet
  coordinate aggregate admission across independent profiles.
- Host-local admission, including measured units, reservations, borrowing, and
  fairness, is tracked as a separate implementation and validation workstream.

### Assumptions

- Operators can classify workloads by capability, trust boundary, latency
  objective, and willingness to wait.
- A protected capacity reservation may intentionally remain unused when borrowing
  is disabled; that underutilization is the cost of a hard latency boundary.
- Exact host budgets and workload-unit values must come from controlled measurement,
  not this decision record.

## Decision drivers

- Keep PitCrew independent of repository-specific workflow semantics.
- Prevent latency-sensitive work from sharing queue eligibility with long-running
  throughput work.
- Bound aggregate host admission without stopping active jobs.
- Support both protected and opportunistic capacity.
- Preserve explicit opt-in and current behavior by default.
- Avoid introducing a remote scheduler or another credential-bearing control plane.
- Keep the public contract useful without exposing non-public systems or examples.
- Leave cross-host capacity steering as a later decision.

## Decision

PitCrew will remain workload-agnostic and will represent execution service classes
through named profiles plus generic host-local admission policy.

### Profile service classes

An operator expresses one service class per profile using existing capability
labels, image, scope, idle floor, maximum capacity, resource limits, and trust
boundaries. Profile names remain operator-owned. PitCrew will not hardcode workflow,
repository, issue-label, or scheduler concepts into the profile schema.

PitCrew may publish capability-oriented example profiles, but a profile advertises
only what its worker can safely execute. It does not define why an external workflow
requested that capability.

### Queue isolation

Workloads with materially different latency or capability requirements use distinct
profile labels. A latency-sensitive job does not share eligibility with long-running
throughput or background jobs merely because both can execute the same command.

GitHub remains the queue and event control plane. PitCrew does not poll repositories,
interpret work-item state, run cron, or prioritize individual queued jobs.

### Host isolation

When host-local admission is enabled, every profile on one Docker daemon participates
in one measured aggregate budget.

The generic policy partitions that budget by measured per-profile cost and
reservations. Each reservation declares whether unused units may be borrowed.
Non-borrowable reservations preserve protected headroom, while unreserved and
borrowable units remain subject to fair access. Budget reductions drain naturally,
and observed state distinguishes withheld demand from infrastructure failure. The
exact schema and coordination mechanism remain owned by the host-local admission
implementation.

Admission applies before a new worker is started. It never stops, deregisters, or
preempts a busy or assigned worker.

A separate profile without coordinated host admission provides queue isolation only.
Documentation and observed state must not describe it as a physical-resource or
latency guarantee.

### External integration boundary

External systems may use GitHub events, schedules, manual dispatch, or another
work-producing mechanism. They select an explicit PitCrew capability label and
remain responsible for workflow permissions, state, outputs, and idempotency.

PitCrew owns only runner lifecycle, capability routing, admission, and
credential-free execution evidence. Cross-system queue formats and automation
runtimes must depend on stable public contracts rather than PitCrew implementation
paths.

### Public contract boundary

Public examples and evidence use synthetic repositories, hosts, workflows, and
identifiers. PitCrew records generic capabilities and admission state; it does not
publish non-public integration identities or configuration.

## Alternatives considered

**Keep independent profiles without host coordination.** This preserves current
behavior and already isolates queue eligibility. It cannot guarantee host headroom
when several profiles admit work concurrently.

**Add workflow-aware scheduling to PitCrew.** PitCrew could poll repositories or
interpret work-item state before creating workers. That would duplicate GitHub's
queue, require broader credentials, couple runner infrastructure to external
semantics, and introduce a remote control plane.

**Ship hardcoded automation-specific profiles.** This would make initial examples
easy to copy, but it would encode one consumer's workflow taxonomy in the public
profile contract. Capability-oriented profiles and operator-owned manifests preserve
the same execution reuse without that coupling.

**Use dedicated physical hosts for every service class.** This provides the strongest
isolation and remains a valid operator choice. It increases hardware, maintenance,
and idle-capacity cost and is not required when a measured host can safely partition
admission.

**Prioritize or preempt jobs in one shared pool.** GitHub does not expose a PitCrew
queue-reordering contract, and preemption would violate busy-job preservation.
Separate eligibility plus admission reservations provides a deterministic boundary
before execution starts.

## Consequences

### Positive

- Repository automation and other external producers remain decoupled from PitCrew.
- Public profile and admission contracts stay generic and reusable.
- Queue isolation and physical-resource isolation have distinct, accurate meanings.
- Operators can protect latency-sensitive capacity or lend unused capacity
  deliberately.
- Future work producers can integrate through the same capability contract.
- The design extends the existing host-local admission workstream instead of
  creating a competing scheduler.

### Negative

- Operators must classify workloads and maintain more than one profile.
- Non-borrowable reservations may leave capacity idle.
- Hard latency claims remain unavailable until host-local admission is implemented,
  configured from measured evidence, and validated.
- GitHub queue behavior can still delay work when no eligible runner is registered.
- Incorrect workload-unit estimates can underuse or overload a host.

### Neutral

- This decision does not select an automation runtime or repository owner.
- It does not change GitHub Actions, AI, artifact, or external storage billing.
- It does not introduce cross-host load balancing, job migration, or preemption.
- Current independent-profile behavior remains the default until an operator opts in.

## Confirmation

The decision is structurally confirmed when:

- documentation distinguishes label eligibility from host-resource guarantees;
- the public profile and admission contracts contain no workflow-specific concepts;
- guidance validation discovers and indexes this ADR; and
- public fixtures contain only synthetic external repository identities.

The operational guarantee is confirmed only after the host-local admission
implementation provides deterministic tests for reservations, borrowing, fairness,
restart recovery, and natural drain, followed by live competing-profile validation.
This accepted boundary does not claim that protected scheduling is delivered before
that implementation and validation are complete.

## References

- [Contributor Architecture](../contributing/architecture.md) demonstrates that
  PitCrew owns profile configuration, manager lifecycle, and disposable workers while
  external manifests remain operator-owned.
- [Named Profiles](../guides/named-profiles.md) demonstrates the existing isolation
  of labels, managers, images, state, and cleanup across pools on one host.
- [Routing Workloads](../guides/routing-workloads.md) demonstrates that GitHub label
  matching determines eligibility and has no automatic self-hosted fallback.
- [Configuration](../configuration.md) defines the current idle-floor, capacity, and
  per-worker resource contracts that service classes compose.
- [Host-local admission issue](https://github.com/ncosentino/pitcrew/issues/61)
  owns atomic aggregate budgeting, reservations, borrowing, fairness, and recovery.
- [Host-local admission workstream](https://github.com/ncosentino/pitcrew/issues/74)
  establishes the ordering of measurement, implementation, and live validation.
