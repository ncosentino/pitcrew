---
title: "ADR-0006: Expiring host-admission demand"
status: "Accepted"
date: "2026-08-14"
authors: []
tags: ["architecture", "admission", "fairness", "recovery"]
supersedes: ""
superseded_by: ""
---

# ADR-0006: Expiring Host-Admission Demand

## Context

ADR-0003 assigns host-local admission, reservations, borrowing, and fairness to
one coordinator. Profile managers publish positive pending demand before
requesting worker leases so the coordinator can protect a fair share for every
current contender.

Pending demand is process-local advisory state. It is not a worker lease and is
not durable across coordinator restart. The original implementation nevertheless
kept each positive publication indefinitely until the owning manager explicitly
published zero.

A manager that stopped, lost its listener, or otherwise ceased reconciliation
could therefore leave positive demand behind. Fairness continued protecting that
absent contender's share while an active profile was denied new leases, even when
the coordinator reported enough available units for additional workers.

Active leases cannot expire from a missing manager heartbeat because their
workers may still be running. Pending demand has no equivalent safety reason to
remain immortal.

## Decision

Positive host-admission demand is a renewable in-memory lease:

- `SetDemand` with a positive count creates or refreshes a 30-second deadline.
- `Acquire` creates or refreshes the same deadline before evaluating fairness.
- `SetDemand`, `Acquire`, and `Status` discard positive demand whose deadline
  has elapsed before using or reporting it.
- Expired demand no longer participates in the contender set or protects a fair
  share.
- Expiry removes demand freshness, so `pendingUnits` and `withheldUnits` become
  `null` until the manager republishes demand.
- Explicit zero demand remains known zero and does not participate in fairness.
- Coordinator restart and policy replacement continue clearing all in-memory
  demand immediately.

Demand expiry never releases, tombstones, or otherwise changes active or
provisional worker leases. Lease lifecycle remains governed by ADR-0003.

The wire protocol does not change. Autoscaled managers refresh demand during
their one-second reconciliation loop, and fixed managers retry pending lease
acquisition every two seconds. Both cadences remain well inside the expiry
window.

## Alternatives considered

### Keep pending demand until explicit zero

This preserves the original behavior but lets an absent manager reserve
fairness headroom indefinitely. Positive available capacity can remain unusable
without a live contender capable of consuming its protected share.

### Remove proactive demand publication

Fairness could consider only profiles currently calling `Acquire`. This avoids
stale publications but lets the fastest manager consume the shared pool before
other active contenders announce their demand.

### Persist demand timestamps

Durable timestamps would survive restart, but the coordinator cannot safely
reconstruct a prior process's monotonic liveness deadline. Pending demand is
advisory and should be republished by live managers after restart.

### Expire worker leases with demand

This would free units quickly but could oversubscribe the host while an
unobserved worker remains active. Worker leases retain their conservative,
explicit release and reconciliation rules.

## Consequences

### Positive

- A stopped manager cannot permanently starve active profiles.
- Available units become usable after a bounded stale-demand window.
- Current contenders retain rotating fairness by refreshing their demand.
- No worker, registration, or durable lease is changed by the expiry.
- Existing manager and coordinator protocol versions remain compatible.

### Negative

- A manager paused for more than 30 seconds temporarily loses its protected
  fairness share until its next demand publication.
- Demand status becomes unavailable after expiry rather than retaining a stale
  positive value.

## Confirmation

The decision is confirmed when deterministic tests prove:

- fresh simultaneous demand still protects each contender's fair share;
- refreshed demand remains current across the original deadline;
- abandoned demand expires and stops withholding otherwise available units;
- expired demand is reported as unavailable rather than zero; and
- admission, autoscaler, and manager validation remain green.

## References

- [ADR-0003](adr-0003-dedicated-host-admission-service.md) defines the
  coordinator and durable worker-lease lifecycle.
- [Host-Local Admission](../guides/host-admission.md) defines operator-visible
  accounting and troubleshooting.
