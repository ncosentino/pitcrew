---
description: Index of PitCrew architecture decision records.
---

# Architecture Decision Records

Architecture decision records preserve significant decisions that are expensive to
reverse. Accepted records retain their original reasoning; a later decision supersedes
them with a new record.

| Record | Status | Decision |
| --- | --- | --- |
| [ADR-0001](adr-0001-docs-first-agent-guidance.md) | Accepted | Use layered, docs-first agent guidance with project-owned scoped instructions and executable structural validation. |
| [ADR-0002](adr-0002-workload-agnostic-service-classes.md) | Accepted | Keep scheduling external and express queue and host isolation through workload-agnostic profile service classes. |
| [ADR-0003](adr-0003-dedicated-host-admission-service.md) | Accepted | Coordinate atomic host-local admission through one socket-local service without Docker access. |
| [ADR-0004](adr-0004-bounded-container-capabilities.md) | Superseded | Permit only bounded service-network, KVM, and shared-memory extensions while preserving socketless disposable workers. |
| [ADR-0005](adr-0005-rootless-same-host-image-building.md) | Accepted | Run the image-builder service rootless on existing nodes and support typed push and non-push image workflows. |
| [ADR-0006](adr-0006-expiring-host-admission-demand.md) | Accepted | Expire abandoned pending demand without changing durable worker leases. |
| [ADR-0007](adr-0007-outbound-read-only-support-plane.md) | Accepted | Provide connector-independent diagnostics through an outbound-only, typed, read-only support plane. |
