---
title: "ADR-0004: Bounded container capabilities"
status: "Accepted"
date: "2026-08-11"
authors: []
tags: ["architecture", "containers", "security", "buildkit", "android"]
supersedes: ""
superseded_by: ""
---

# ADR-0004: Bounded Container Capabilities

## Context and scope

PitCrew workers are disposable Linux containers. Only a profile manager receives the
Docker socket, while workers execute one GitHub Actions job without access to that
socket or the manager's host-pressure mount.

Some trusted workloads need capabilities outside the ordinary worker image. OCI image
publication needs a build daemon. Hardware-accelerated Android testing needs KVM and
more shared memory than Docker's default. Passing the orchestration socket or arbitrary
Docker arguments to workers would satisfy those workloads by weakening PitCrew's main
host boundary.

This decision defines the bounded extensions allowed inside the existing container
execution domain. It covers isolated build services, typed worker devices,
shared-memory sizing, profile verification, and Android-emulator lifecycle. It does
not introduce native operating-system runners, generic privileged containers,
arbitrary devices, remote Docker control, or a new execution backend.

### Verified facts

- Both current manager implementations launch one-job worker containers through the
  host Docker daemon and remove them after the runner exits.
- The existing `serviceNetwork` contract attaches workers to one operator-owned local
  bridge network without attaching the manager or exposing a host port.
- BuildKit separates the `buildctl` client from `buildkitd`, supports TCP with mutual
  TLS, accepts local build contexts from the client, and can return an immutable image
  digest through its metadata file.
- BuildKit warns that an unauthenticated TCP daemon is unsafe. Its daemon also owns
  reusable cache and build-history state unless that state is explicitly cleaned.
- Docker-Android 3.6.0-p0 publishes an amd64 Android 14 emulator image that requires
  Linux virtualization and `/dev/kvm`.
- Docker-Android stores emulator readiness in `device_status`, destroys emulator data
  by default with the container, and enables behavior analytics by default unless the
  environment disables it.
- A shared long-lived emulator would carry mutable device state between jobs. A
  disposable PitCrew worker already provides the required one-job destruction
  boundary.

### Assumptions

- Specialized profiles execute only trusted workflow code and omit broad
  `self-hosted` eligibility.
- The operator can provide an isolated BuildKit daemon and mTLS identities outside
  tracked profile configuration.
- Android hosts expose working KVM virtualization to the Docker daemon.
- Operators calibrate Android worker cost and reservations through host-local
  admission rather than treating profile resource defaults as host measurements.

## Decision drivers

- Preserve the manager-only orchestration socket boundary.
- Keep specialized capability selection in reviewed profile configuration, never
  workflow input.
- Reuse the current one-job worker lifecycle and both manager implementations.
- Reject generic privilege, arbitrary device paths, and raw Docker arguments.
- Fail before manager replacement when a required device is unavailable.
- Prevent build cache, build history, and emulator state from crossing job
  boundaries.
- Keep immutable versions, digests, and checksums in the reviewed profile.
- Make unsupported architecture or host capability explicit rather than silently
  falling back.

## Decision

PitCrew will extend schema-version-1 container profiles with one optional `runtime`
object. The object permits only the typed `kvm` device and a canonical shared-memory
size. No profile field accepts a host path, Linux capability, seccomp setting,
privileged mode, Docker endpoint, or arbitrary launch argument.

Setup validates the runtime policy by running every image verification command with
the exact device and shared-memory arguments before manager replacement. The fixed
manager and autoscaler render the same canonical arguments. Runtime changes update the
worker revision and roll naturally while active workers retain their original
container configuration.

The manager observed-state contract remains version 18 because no new live telemetry
field is introduced. Static profile state advances the internal worker-runtime
contract to version 3 and records the normalized runtime policy for diagnostics and
rollback.

### Isolated image building

Image-building workers use the existing service-network boundary and a pinned
`buildctl` client. They connect only to an operator-owned BuildKit daemon through
mutual TLS. The daemon is not the PitCrew orchestration daemon and exposes no generic
Docker API.

The built-in `image-builder` profile permits one active worker across its targets.
Its helper removes BuildKit cache and unpinned build history before and after every
build, so a cancelled job is cleaned when the next job begins. Registry credentials
and client certificates remain job-scoped GitHub secrets. Successful builds return
the canonical repository reference plus immutable digest.

The BuildKit daemon belongs to its own trust boundary. A deployment that requires
host-level privilege runs on a dedicated builder host or virtual machine. A same-host
deployment is acceptable only when that entire Docker host is dedicated to the
builder trust boundary.

### Android emulation

Android emulation runs inside the disposable worker rather than in a shared service.
The built-in `android-emulator` image derives from the immutable Docker-Android
3.6.0-p0 Android 14 image and adds the GitHub Actions runner.

The profile is amd64-only, requests only `/dev/kvm`, uses bounded shared memory and
resource limits, and has an aggregate active-worker maximum of one. Its startup helper
forces behavior analytics, web logs, and web VNC off, waits for the upstream
`device_status` readiness transition, and verifies Android boot completion.

No ADB, Appium, VNC, or log port is published to the host. Workflow steps interact
with the emulator inside the same worker container. When the one job completes,
Docker removes the runner, emulator processes, writable device state, and runner
credentials together.

## Alternatives considered

### Give workers the orchestration Docker socket

This would make Docker builds and Docker-Android trivial to launch. Docker socket
access is host-level control and would let workflow code inspect or remove managers,
workers, stateful services, and unrelated containers. It is rejected.

### Expose a generic remote Docker API

A separate daemon would avoid the orchestration socket but still provide an
unbounded container-control API to workflows. It would also require daemon-level
authorization, lifecycle cleanup, and network hardening. BuildKit provides the
narrower build interface, while Android needs no daemon API when it runs inside the
worker.

### Add arbitrary devices or privileged flags to profiles

Raw device paths and privilege switches would turn operator manifests into a generic
host-control interface. The selected contract permits only KVM and shared-memory
sizing. A future device requires another reviewed schema and implementation change.

### Share one long-lived Android emulator

A shared emulator would reduce startup time. It would retain installed applications,
accounts, files, settings, and process state across jobs, and concurrent jobs could
interfere. Disposable per-job emulation is selected instead.

### Add a new VM or native execution backend

A disposable VM can isolate arbitrary privileged workloads but introduces a new
provisioner, artifact model, recovery state, and host boundary. BuildKit and
KVM-enabled containers satisfy these two capabilities without changing PitCrew's
execution backend.

## Consequences

### Positive

- Ordinary workers remain socketless and unprivileged.
- Image publication uses a narrow authenticated API and immutable digest output.
- Android state and credentials are destroyed with the one-job worker.
- Both manager modes share one bounded runtime policy.
- Missing KVM fails before a live profile is replaced.
- Arbitrary devices, blanket privilege, and raw Docker arguments remain unavailable.

### Negative

- The Android image is amd64-only and several gigabytes in size.
- KVM access increases the trusted-workflow and host-kernel attack surface.
- Android startup adds latency after a job is assigned.
- BuildKit cache reuse is intentionally sacrificed to preserve cross-job isolation.
- Operators must provision and rotate BuildKit mTLS material separately.

### Neutral

- GitHub remains the queue and job-demand authority.
- Host-local admission still controls aggregate worker starts but does not measure KVM
  or BuildKit daemon usage automatically.
- Existing profiles without `runtime` retain their prior launch behavior.
- Native Windows, macOS, arbitrary privileged Linux, and Docker Compose service
  containers remain outside this decision.

## Confirmation

The decision is confirmed when:

- the profile schema rejects arbitrary devices, privilege, and raw launch arguments;
- Setup verifies KVM and shared memory before manager replacement;
- fixed and autoscaled launch tests produce identical KVM and shared-memory arguments;
- an mTLS client publishes an image through BuildKit and an unauthenticated client is
  rejected;
- image-builder tests verify immutable digest output and empty cache after the job;
- the Android profile pins Docker-Android by digest, contains the GitHub runner, and
  disables analytics by default;
- worker launch arguments contain neither `--privileged` nor the Docker socket; and
- live Android qualification verifies readiness, one test workload, and destruction
  of emulator state after job completion.

## References

- [Contributor Architecture](../contributing/architecture.md) demonstrates that both
  managers own disposable Docker workers while only managers receive Docker access.
- [Pool-Local Services](../guides/pool-local-services.md) defines the existing
  operator-owned network-service boundary reused by BuildKit.
- [Security Boundaries](../guides/security-boundaries.md) establishes the socketless
  worker invariant and trusted-trigger requirement.
- [BuildKit documentation](https://github.com/moby/buildkit/tree/v0.32.2) documents
  mTLS daemon configuration, local client contexts, metadata digests, cache pruning,
  and build-history pruning.
- [Docker-Android v3.6.0-p0](https://github.com/budtmo/docker-android/tree/v3.6.0-p0)
  documents KVM requirements, Android 14 images, readiness state, default
  destruction, and behavior analytics.
