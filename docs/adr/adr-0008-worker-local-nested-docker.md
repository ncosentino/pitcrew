---
title: "ADR-0008: Worker-local nested Docker"
status: "Proposed"
date: "2026-10-23"
authors: []
tags: ["architecture", "containers", "security", "testcontainers"]
supersedes: ""
superseded_by: ""
---

# ADR-0008: Worker-Local Nested Docker

## Context and scope

Ordinary socketless workers cannot run local Testcontainers databases. Copying a
Docker binary or starting a daemon in an image entrypoint is insufficient:
scale-set JIT launch intentionally overrides the image entrypoint.

ADR-0005's rootless mTLS BuildKit service remains the image-building contract.
This proposal introduces a separate typed, trusted-only database capability;
it does not replace BuildKit, enable host-socket access or change ordinary
worker defaults. Acceptance awaits controlled and registered-worker evidence.

## Options

| Option | Privilege and accounting | Storage/network/lifecycle |
| --- | --- | --- |
| Shared host socket | Host-level daemon authority; cannot attribute sibling resources to one worker | Shared names/cache/network; unacceptable cross-job authority |
| Worker-owned sidecar | Additional daemon container and admission/resource ownership | Extra readiness, port/path mapping and orphan recovery complexity |
| Rootless worker-local daemon | Potentially less authority; kernel/userns/network prerequisites need proof | Not qualified here; no advertised fallback |
| Rootful worker-local daemon | Privileged trusted worker; nested processes under one limited parent | Private socket/network; one disposable lifetime; selected initial implementation |

## Decision

Provide only `runtime.docker.mode=privileged-local` with mandatory bounded
storage and explicit CPU/memory/PID/no-swap policy. Require scale-set mode,
host admission, a native Linux x64 root image without volumes, immutable digest
and a rootful cgroup-v2 host without userns remapping. Reject fixed mode,
external volumes, service networks and device combinations.

Embed the bootstrap in the manager and invoke it before the real listener.
Preserve JIT semantics, image user (reject unsupported users, never silently
override them), signals and exit propagation. Daemon exit or stalled startup
fails closed. No blanket Docker flags are accepted from manifests.

Use a worker-private Unix socket, loopback published ports, private cgroup
namespace and a worker-local rootful daemon. Delegate controllers below the
outer finite cgroup after moving initial processes to a child. All intended
daemon/database use is charged to that worker and its existing admission lease.
Outer `docker exec` is unsupported after cgroup delegation.

Bound daemon state with tmpfs and `overlay2`; the memory ceiling covers daemon data
as well as processes. No state survives the worker. This avoids unbounded
anonymous outer volumes but incurs cold pulls and RAM cost. Require kernel
OverlayFS support; there is no fallback to a copy-amplifying driver. Controlled
qualification found `vfs` exhausted a 1 GiB store during image extraction and a
2 GiB store during container creation. Copy-on-write addresses that duplication
without increasing the worker's finite memory/storage policy.
Large engine images may make it impractical; do not claim a speedup before
comparable end-to-end measurement.

Keep Ryuk enabled with the private socket mount. Test code uses reported
hostname/mapped port and resource-copy APIs. Supervisor cleanup addresses
normal exit, TERM/INT and daemon failure; outer removal destroys the job's
processes, bridge and state without pruning unrelated resources.

## Risks and assumptions

Privileged execution shares the host kernel and is not a strong sandbox.
Trusted code can deliberately defeat restrictions. Operators must approve
isolated validation and trusted repository/group routing; fork code is excluded.
Finite cgroups constrain supported cooperative workloads, not a malicious root.

Native architecture, cgroup delegation, reaper access, real SQL connectivity and
CPU/memory/PID ancestry need controlled runtime evidence. A synthetic listener
is useful engineering coverage, not real GitHub registration/dispatch proof.
No production enrollment or claim of provider qualification follows from this
decision alone.

## Consequences and qualification

Ordinary runtime contract 3 and fingerprints remain unchanged; only opted-in
workers select internal runtime contract 4. Manager observed-state contract
22 does not change. Existing compatible-worker preservation/adoption remains.

The [canonical guide](../guides/nested-docker.md) owns the exact image, profile,
endpoint, diagnostics, evidence and rollout contract. Retain Proposed/draft
status until configured CI and the separately authorized registered-worker
canary pass. Record unavailable counters and queue timings as unavailable;
publish bounded summaries, not uploaded artifacts or private infrastructure.
