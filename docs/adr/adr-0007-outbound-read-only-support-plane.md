---
title: "ADR-0007: Outbound read-only support plane"
status: "Accepted"
date: "2026-08-15"
authors: []
tags: ["architecture", "diagnostics", "security", "support"]
supersedes: ""
superseded_by: ""
---

# ADR-0007: Outbound Read-Only Support Plane

## Context

PitCrew deliberately exposes no inbound node-management port. That boundary
prevents a central service, compromised credential, or operator workstation
from turning every runner host into a remotely accessible shell.

The existing connector publishes routine projections and supports a small set
of typed capacity and recovery operations. It is unsuitable as the only
incident channel: the connector itself may be offline, and expanding it into a
general diagnostics tunnel would combine standing telemetry, Docker-adjacent
operations, and incident access in one trust domain.

Manual SSH, WinRM, and agent handoff can collect evidence, but they require
separate node access or repeated human coordination. A support path must work
when the connector is unavailable without weakening the no-inbound boundary.

## Decision

PitCrew support-plane v1 is an asynchronous, node-initiated, strictly read-only
diagnostics channel.

- A dedicated low-privilege transport agent polls an opaque relay over outbound
  HTTPS.
- Dashboard authorization signs a typed request and encrypts it to the enrolled
  node. The relay cannot authorize, inspect, or rewrite that request.
- The node independently verifies request signature, tenant, node, capability,
  expiry, request digest, and replay state before execution.
- The transport agent reaches a separate diagnostics broker through
  peer-restricted local IPC. It cannot read PitCrew profile state itself.
- The broker has no network or Docker access. It invokes only the versioned
  collector with `-FileOnly -PassThruOnly` against the locally configured
  PitCrew root.
- File-only collection reads fixed generated profile state and the bounded
  connector health journal. Excluded live Docker, host-resource, URL, and
  source-control evidence remains explicitly unavailable and is never reported
  as zero.
- The node signs the complete result and encrypts it to Dashboard. Clients bind
  the signature to the enrolled node key before importing the existing
  diagnostics package.
- Relay credentials and traffic cannot request arbitrary commands, scripts,
  paths, URLs, ports, tunnels, Docker access, or mutations.
- Security identity, replay tombstones, and cached signed results live outside
  `.pitcrew-state`. Duplicate request digests return the cached result rather
  than rerunning collection.

The support agent and broker are independently deployable from the existing
connector. Connector capacity and recovery operations remain unchanged in v1.

Repository ownership is explicit:

| Repository | Owned v1 surfaces |
| --- | --- |
| PitCrew | File-only collector, report/import contracts, operations skill, support-boundary guidance, and PitCrew release assets |
| PitCrew Dashboard | Protocol types and canonicalization, authorization and identity services, opaque relay, agent and broker applications, persistence, APIs, Dashboard UX, installers, and node packages |

Capabilities use stable typed identifiers with an explicit major version.
Enrollment advertises the exact capabilities and envelope versions installed on
the node. Dashboard may authorize only the intersection it understands, and the
node independently rejects anything it did not advertise. Minor additive fields
remain ignorable; breaking request, result, or cryptographic changes require a
new major capability identifier and coexist during mixed-fleet rollout.

The migration path remains additive:

- v1 adds asynchronous file-only diagnostics beside the connector.
- v1.1 and v1.2 may add interactive read-only exchange and automatic evidence
  correlation over the same typed transport.
- v1.5 may add locally approved deep diagnostics through a separate ephemeral
  helper; it does not enlarge the standing broker.
- v2 may migrate existing typed connector operations only after dual approval,
  exact capability versioning, and transactional safety are proven. The legacy
  connector path remains available during mixed-fleet migration.

## Alternatives considered

### Generic reverse SSH or TCP tunnel

A tunnel is operationally familiar and can expose arbitrary tools. That same
generality creates an inbound-equivalent shell or port-forwarding surface after
the node dials out, makes authorization difficult to constrain, and expands one
transport defect into host-level access.

### Expand the existing connector

Reusing one process reduces packaging work. It also makes connector failure a
support-plane failure, combines routine synchronization with incident
authorization and decryption, and places more privileged code in the standing
connector trust boundary.

### Execute the collector directly in the transport agent

This removes local IPC. It also gives the network-facing process access to
PitCrew state and makes a transport compromise sufficient to enumerate node
configuration.

### Permit Docker-backed read-only diagnostics

Exact-label Docker reads provide richer evidence. Docker socket access is
effectively host control, not a read-only capability, and cannot be present in
the standing v1 broker. A later deep-diagnostics workflow may require explicit
local approval and a separately bounded helper.

### Keep manual operator handoff only

Manual handoff preserves current boundaries and remains a fallback. It does not
provide prompt, repeatable evidence when the connector is unavailable and does
not scale to fleet incident response.

## Consequences

### Positive

- Nodes retain a zero-inbound-port posture.
- Relay compromise cannot authorize diagnostics or decrypt evidence.
- Connector failure does not remove the support path.
- Network-facing code cannot read PitCrew state or reach Docker.
- The existing report, redaction, import, and diagnosis contracts remain the
  single evidence format.
- Later versions can add interactive read-only sessions and separately approved
  typed operations without migrating from an arbitrary shell protocol.

### Negative

- v1 cannot inspect live Docker inventory, resource pressure, or arbitrary
  network paths.
- Deployment requires separate agent, broker, identity, relay, and Dashboard
  lifecycle management.
- Local IPC authorization and key storage need OS-specific hardening beyond the
  portable development defaults.
- Cross-process and cross-language envelope canonicalization requires shared
  cryptographic test vectors.

## Confirmation

The decision is confirmed when coded tests prove:

- requests and results fail closed on signature, identity, tenant, node,
  capability, expiry, digest, and replay mismatch;
- duplicate requests return one cached signed result;
- the relay cannot decrypt payloads or create an authorized request;
- the transport process cannot read PitCrew state;
- the broker cannot access the network or Docker;
- file-only collection launches no external command and preserves omitted live
  measurements as unavailable;
- connector-offline end-to-end collection completes through the relay; and
- existing connector operations and direct diagnostics remain compatible.

## References

- [Security Boundaries](../guides/security-boundaries.md)
- [Copilot CLI Operations](../guides/copilot-operations.md)
- [Dashboard ADR-0008](https://github.com/ncosentino/pitcrew-dashboard/blob/main/docs/adr/adr-0008-support-plane-v1-read-only-diagnostics.md)
  defines the paired authorization, relay, support-agent, broker, storage, and
  user-experience boundaries.
