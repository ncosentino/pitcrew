---
title: "ADR-0005: Rootless same-host image building"
status: "Accepted"
date: "2026-08-12"
authors: []
tags: ["architecture", "containers", "security", "buildkit", "android"]
supersedes: "ADR-0004"
superseded_by: ""
---

# ADR-0005: Rootless Same-Host Image Building

## Context and scope

PitCrew workers are disposable Linux containers. Only profile managers receive the
orchestration Docker socket. ADR-0004 added typed KVM access for Android workers and
an image-builder client profile, but required a dedicated Docker host whenever the
BuildKit service needed elevated daemon-host capabilities.

That dedicated-host requirement made the image-builder profile unusable on an
existing multi-purpose PitCrew node even when BuildKit could run rootless without
blanket privilege. The first helper also supported only push builds and could not
replace workflows that require typed build arguments, OCI labels, non-publishing
verification, or registry-side digest confirmation.

This decision corrects those boundaries while preserving Android behavior. It covers
the rootless BuildKit service, worker/helper contract, same-host isolation, service
lifecycle, and workflow outputs. It does not add a generic Docker API, Docker Compose
inside workers, arbitrary devices, native runners, or untrusted fork execution.

### Verified facts

- Both managers launch one-job workers without the Docker socket and can attach them
  to one exact operator-owned service network.
- BuildKit 0.32.2 publishes a rootless image whose Docker deployment uses
  `seccomp=unconfined`, `apparmor=unconfined`, and
  `systempaths=unconfined` instead of `--privileged`.
- Upstream documents `systempaths=unconfined` as safe for rootless BuildKit because
  the daemon runs as a mapped non-root user. It preserves per-build process
  namespaces and avoids the discouraged `--oci-worker-no-process-sandbox` mode.
- Rootless BuildKit build executors run inside the BuildKit service container. They
  receive only contexts explicitly streamed by `buildctl`; they cannot read the
  Actions worker filesystem, runner registration state, or JIT configuration.
- BuildKit supports typed Dockerfile build arguments, labels, platform selection,
  registry image output, OCI-layout output, and metadata digests.
- `crane` can resolve a registry digest or an OCI tarball digest without a Docker
  daemon.
- Docker-Android still requires the typed KVM and shared-memory policy selected by
  ADR-0004; that portion of the decision remains valid.

### Assumptions

- Specialized image-builder workflows are trusted and do not execute unreviewed fork
  code.
- The host supports unprivileged user namespaces and the documented rootless
  BuildKit security options.
- AppArmor may require
  `kernel.apparmor_restrict_unprivileged_userns=0` on Ubuntu 24.04 or later.
- Operators include the persistent rootless BuildKit service in host-capacity
  planning because host admission accounts for Actions workers, not external
  services.

## Decision drivers

- Run on an existing PitCrew Docker host without a VM or dedicated physical host.
- Keep Actions workers and BuildKit build executors away from the orchestration
  Docker socket.
- Avoid `--privileged` and generic device/capability configuration.
- Keep server credentials out of workers and client credentials out of profile state.
- Preserve one active image-builder worker and deterministic cleanup between jobs.
- Support both non-publishing pull-request verification and protected publication.
- Pass build arguments and labels without shell evaluation.
- Verify published and local OCI digests without Docker.
- Make service provisioning and certificate generation executable rather than
  relying on prose assembled by each operator.

## Decision

### Bounded worker runtime

The schema-version-1 `runtime` contract remains unchanged. It permits only typed KVM
access and canonical shared-memory sizing. Android continues to run inside the
disposable worker, and no worker receives arbitrary host devices, privilege, or the
Docker socket.

### Rootless image-builder service

PitCrew will ship one rootless BuildKit Compose service for the `image-builder`
profile. The service:

- uses the immutable `moby/buildkit:v0.32.2-rootless` image;
- runs as the image's UID/GID 1000 rootless user;
- uses exactly `seccomp=unconfined`, `apparmor=unconfined`, and
  `systempaths=unconfined`;
- does not use `--privileged`, host ports, the Docker socket, host bind mounts for
  state, or `--oci-worker-no-process-sandbox`;
- joins only the `pitcrew-image-builder` bridge network under alias `buildkitd`;
- stores state and server certificates in exact named Docker volumes;
- requires mutual TLS on its worker-facing TCP listener; and
- retains a manager-local Unix listener for its health check.

This rootless service may share a Docker host with ordinary PitCrew profiles. The
rootless user namespace and lack of orchestration-socket access are the isolation
boundary. A host that cannot satisfy the rootless prerequisites fails qualification;
it does not fall back to privileged BuildKit.

PitCrew ships certificate-generation and service-setup scripts. Certificate
generation produces separate authority, server, and client directories without
printing private material. Service setup imports only server material into the
service's certificate volume, creates or validates exact network/volume identities,
starts scoped Compose, and verifies non-privileged health and security options.

The BuildKit service remains running while Actions capacity scales to zero. It is a
PitCrew-shipped profile dependency, not a GitHub runner and not a generic remote
Docker daemon.

### Image-builder worker and helper

The worker contains checksum-pinned `buildctl` 0.32.2 and `crane` 0.21.9. Its
aggregate active-worker maximum remains one because pre/post-job cleanup applies to
the whole BuildKit daemon.

The helper accepts:

- one validated tagged image reference;
- an existing context and Dockerfile directory;
- `linux/amd64` or `linux/arm64`;
- at most 32 typed, non-secret build arguments;
- at most 32 lowercase OCI labels;
- either registry push or local OCI-tar output; and
- optional registry-side digest verification for push mode.

Arguments are assembled as arrays and passed directly to `buildctl`; the helper never
uses `eval`. Secret-shaped build-argument names, control characters, unsupported
platforms, mixed output modes, and unbounded values fail before contacting BuildKit.

Pull-request verification writes an OCI tarball and verifies its digest with
`crane --tarball`. It creates no registry tag. Protected publication pushes the
tagged image, reads the BuildKit metadata digest, and can require `crane digest` to
return the same registry digest.

The helper removes cache and unpinned build history before and after every build. A
hard-cancelled worker may skip its exit trap, so the next job's preflight cleanup is
the authoritative reuse fence.

### Routing and credentials

Named profiles continue to receive `linux` and host architecture labels at manager
runtime even when default GitHub labels are disabled. Workflows may request
`[linux, x64, image-builder]`, or an operator may add a repository-specific alias
through the existing `-Labels` override.

The profile injects no TLS or registry credentials. Jobs materialize only the client
CA certificate, client certificate, and client key under `RUNNER_TEMP`. Registry
authentication uses job-scoped `$DOCKER_CONFIG`. Both directories are removed by an
`always()` cleanup step.

## Alternatives considered

### Keep the dedicated-host requirement

This preserves the most conservative physical boundary but makes the service
unavailable on existing nodes despite upstream rootless support. It also adds
hardware without improving the worker's credential isolation. Rejected.

### Use privileged BuildKit on the shared host

This is operationally simple and was sufficient for the initial CI proof. Build
instructions execute beneath a host-privileged service and expand compromise impact
to unrelated profiles. Rejected.

### Run BuildKit inside the Actions worker

The worker would need security-option or FUSE extensions, and build executor
processes could share a container boundary with runner credentials and the listener.
Keeping the daemon in a separate rootless service preserves a stronger credential and
mount namespace boundary. Rejected.

### Create one BuildKit sidecar per job

Per-job sidecars provide stronger state destruction but require manager-owned network,
service, recovery, and cleanup lifecycle beyond the current worker contract.
Sequential rootless service use plus preflight cleanup satisfies the immediate
requirements with substantially less control-plane complexity. Deferred unless
operating evidence disproves the cleanup boundary.

### Continue using Docker Actions

Buildx, Docker login, and post-build `docker run` require a Docker daemon in the
worker. Exposing either the orchestration socket or a generic remote Docker API
violates the selected boundary. Rejected.

## Consequences

### Positive

- Existing PitCrew nodes can host image-builder capacity without a VM or dedicated
  physical host.
- Workers and Dockerfile build executors remain isolated from runner credentials and
  the orchestration socket.
- Pull requests can prove image construction without publishing a registry artifact.
- Protected publication verifies the registry digest without Docker.
- Build arguments and labels support real repository image contracts.
- Operators receive deterministic service and certificate tooling.

### Negative

- The host must support rootless user namespaces and three unconfined security
  options.
- The persistent service consumes host resources outside worker admission accounting.
- Profile concurrency remains one.
- Cache reuse remains intentionally disabled.
- Operators must rotate client secrets and update protected repository secrets.

### Neutral

- Manager contract remains 18 and worker-runtime contract remains 3.
- Android behavior and KVM policy are unchanged.
- GitHub remains the queue and demand authority.
- BuildKit service state remains separate from PitCrew manager state.

## Confirmation

The decision is confirmed when:

- static contracts reject `--privileged`, Docker socket mounts, host ports, and
  no-process-sandbox mode;
- the rootless service runs as UID 1000 with the exact security options;
- an authenticated client connects and a CA-only client is rejected;
- an unrelated profile cannot resolve `buildkitd`;
- literal build-argument and label values survive without shell expansion;
- pull-request mode produces a verified OCI tarball and no registry tag;
- push mode produces a registry digest matching BuildKit metadata;
- cache/history are empty after each helper invocation;
- the next job removes state left by an interrupted prior build; and
- the worker cannot read the service's server private key or Docker socket.

## References

- [Contributor Architecture](../contributing/architecture.md) establishes manager
  Docker ownership and one-job worker lifecycle.
- [Pool-Local Services](../guides/pool-local-services.md) establishes profile-scoped
  service-network routing.
- [Security Boundaries](../guides/security-boundaries.md) establishes socketless
  workers and trusted-trigger requirements.
- [BuildKit rootless documentation](https://github.com/moby/buildkit/blob/v0.32.2/docs/rootless.md)
  documents the exact non-privileged Docker security options and process-sandbox
  tradeoffs.
- [Crane digest documentation](https://github.com/google/go-containerregistry/blob/v0.21.9/cmd/crane/doc/crane_digest.md)
  documents registry and OCI-tarball digest resolution.
- [Docker-Android v3.6.0-p0](https://github.com/budtmo/docker-android/tree/v3.6.0-p0)
  remains the pinned Android-emulator source.
