---
description: Qualify trusted Linux x64 scale-set workers with a private, disposable Docker daemon and bounded aggregate resources.
---

# Opt-In Nested Docker

This capability is an explicit privileged exception for **trusted** database jobs,
not a change to ordinary workers. The implementation is awaiting controlled
qualification; do not treat an unexecuted fixture as production approval.
[ADR-0008](../adr/adr-0008-worker-local-nested-docker.md) records the decision.

## Supported contract

| Surface | Contract |
| --- | --- |
| Mode | `runtime.docker.mode: privileged-local`; scale-set only |
| Host | Native Linux x86-64, rootful Docker, cgroup v2, no userns remapping |
| Image | Operator-approved immutable digest; Linux amd64; image user root; no image-declared volumes |
| Privilege | Fixed `--privileged --cgroupns private`; no arbitrary flag injection |
| Admission | Explicit host admission, calibrated to the whole worker plus nested workload |
| Resources | Explicit CPU, memory, PIDs; memory-plus-swap equals memory; storage smaller than memory |
| Storage | Bounded disposable tmpfs, `vfs`; no persistent database or image cache |
| Endpoint | `unix:///run/pitcrew-docker/docker.sock`; worker-local authority only |
| Unsupported combinations | Fixed workers, rootless hosts/daemon, non-root images, emulation, KVM, external volumes, service networks |

Privileged code can attack the shared host kernel and may defeat namespace
restrictions. This is **not a hostile-code sandbox**. Use an authorized isolated
validation host and trusted repository/group access; never route untrusted forks.
Do not expose the shared host socket or enable a Docker TCP listener.

## Profile and routing

Start from the [external manifest example](../examples/nested-docker-profile.json).
The zero digest and host budget are placeholders, not an approved deployment.
Select a real published image digest and calibrate memory, bounded storage, CPUs,
PIDs, admission cost, concurrency and shared capacity together. Do not copy the
example's host policy onto an existing node.

```yaml
jobs:
  affected-native-database-tests:
    # The existing affected-test planner must select this job first.
    runs-on: [self-hosted, linux, x64, database-ci, nested-docker]
    steps:
      - uses: actions/checkout@v6
      - name: Verify the required local engine
        run: docker info >/dev/null
      - name: Run only the planner-selected native tests
        run: ./scripts/run-selected-native-tests
```

The last command is a workload-owned placeholder, not a PitCrew executable.
Ordinary build jobs keep their existing pool. Policy/planning stays on
`automation-control`, without Docker probes or provisioning. Update the consuming
repository's delivery metadata, routing instructions and executable label-contract
validator together; a workflow label change alone is insufficient.

## Startup, resources and cleanup

The manager invokes its embedded bootstrap with `/bin/sh -c`, overriding the
image entrypoint. The bootstrap verifies tools, native architecture and finite
cgroup limits, moves its own initial processes into a child cgroup, and enables
CPU, memory and PID delegation inside the private worker cgroup namespace.
Daemon and database descendants remain below the worker's aggregate limits.
The parent cgroup consequently cannot accept new processes: **outer `docker exec`
is not supported after delegation**. Job steps inherit the listener's child
cgroup and can execute normally.

The daemon uses `vfs` and `/var/lib/pitcrew-docker` in a size-limited tmpfs.
Daemon state, image layers, database files and logs therefore consume the
worker's memory budget. Copy amplification and cold pulls can be expensive.
This is not a bounded persistent-disk implementation; large database images may
need substantially more memory. No performance improvement is claimed.

Only successful `docker info` permits `Runner.Listener` startup with its existing
JIT input. A failed daemon never starts the listener. Startup detects daemon exit
immediately and a stalled milestone sequence after 120 seconds without forward
progress; log activity cannot indefinitely reset the stall detector. This is not
a test-execution deadline. Errors emit bounded phase/reason markers, never raw
daemon logs or JIT input.

TERM/INT forward to the listener and daemon; normal listener exit is propagated.
Daemon failure terminates the worker. Outer worker removal reaps its processes
and discards both tmpfs mounts. Existing manager registration cleanup, admission
lease lifecycle and compatible-worker adoption remain authoritative. Never prune
the host daemon, sweep other workers, or force busy-worker turnover.

## Testcontainers networking

The bootstrap exports `DOCKER_HOST` plus
`TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE=/run/pitcrew-docker/docker.sock` and
`TESTCONTAINERS_HOST_OVERRIDE=127.0.0.1`. It removes inherited Docker
context/TLS/API overrides and does not permit a disabled Resource Reaper.
The reaper mounts **this job's socket**, not the host's orchestration socket.
The daemon publishes database ports on worker loopback by default.

Use Testcontainers' `Hostname` and `GetMappedPublicPort`, not a fixed port or the
outer host address. Prefer its resource-copy APIs: file paths are interpreted
inside this worker, never as arbitrary outer-host bind mounts. Separate workers
have separate daemons, image stores, bridge networks, container names and ports.

## Repository-owned toolchain

Follow [Repository-Owned Worker Images](repository-owned-images.md) for trusted
publication, digest approval, candidate verification, activation and rollback.
The workload owns its Dockerfile; PitCrew does not publish a universal toolchain
image or install source/dependencies into immutable layers.

The controlled fixture pins:

| Component | Immutable/version contract |
| --- | --- |
| Docker engine source | `docker:28.5.2-dind@sha256:2a232a42256f70d78e3cc5d2b5d6b3276710a0de0596c145f627ecfae90282ac` |
| .NET SDK source | `mcr.microsoft.com/dotnet/sdk:10.0.302@sha256:72dd743782f2ae7e5476fd64f6a460045e3998dc862218b80e6944cba79a01b0` |
| Smoke library | `Testcontainers.MariaDb` 4.16.0; `MySqlConnector` 2.4.0 |
| Database | `mariadb:11.4.5@sha256:49117dcc565cf51aa57ac5fca59ab31213402ff0eae6ffc13c46a37b938f7e4b` |
| Resource Reaper | `testcontainers/ryuk:0.14.0@sha256:7c1a8a9a47c780ed0f983770a662f80deb115d95cce3e2daa3d12115b8cd28f0` |

Copy the engine binaries from the pinned source stage rather than inheriting its
entrypoint or `VOLUME`. Include Docker, dockerd, containerd, its runc shim, runc,
docker-init/proxy, iptables, iproute2, coreutils timeout and CA certificates.
Verify actual CLI/server versions during candidate qualification. A fixture
listener is **not** the real Actions runner; workload images need the real
verified `/actions-runner/bin/Runner.Listener` and runner native dependencies.

Pin the workload's .NET SDK, Node/npm and baseline tools from authoritative
manifests. Verify exact versions as root, writable workspace/HOME and required
libraries. Either populate setup actions' exact tool-cache format and prove
cache hits, or deliberately replace their installation steps on this capability
with exact preinstalled-version guards and separate NuGet/npm caching. Merely
adding binaries to PATH does not prove setup-action compatibility.

Keep shared toolchain layers separate from optional Desktop libraries and daemon
capabilities. Only affected native-engine jobs need this daemon. Derive Desktop
dependencies from the workload's executable package list instead of guessing a
second list. Do not bake source, restored outputs, node_modules, database data,
all provider images, tokens or registry credentials.

## Validation and release boundary

Configured contracts run `tests/Test-NestedDockerProfile.ps1`, Go tests/vet and
shell syntax checks. The existing controlled Docker integration invokes
`tests/integration/Test-NestedDocker.sh`; no new runner lane is introduced.
Its synthetic listener runs real pinned MariaDB Testcontainers SQL round trips,
cold/warm phases, an abrupt client exit with reaper cleanup, two-worker
isolation, cancellation, daemon failure and clean replacement through the actual
launch builder. It checks database cgroup ancestry and aggregate limits.
Manager recovery retains existing deterministic adoption coverage; it is not a
new registered-worker recovery drill.

Markers/job summaries retain phase timings, tested revision, selected inventory,
concurrency, budgets, parent CPU/memory/pressure counters and explicit unavailable
scope. No Actions artifacts are uploaded. Every replacement is cold; the warm
sample reuses images only inside one job. Compare total workflow critical path,
image publication/acquisition and queue delay, not just SDK installation time.
The synthetic fixture cannot measure registered-worker queue/admission delay.

Production support requires a separately authorized **registered PitCrew worker**
canary with real JIT registration and GitHub job dispatch. Passing a synthetic
listener on existing CI is not that evidence. Until that canary and required
checks pass, retain draft/unreleased status and record the operator-owned gap.

## Rollout and rollback

1. Obtain explicit authorization for a dedicated trusted canary host/profile;
   review image digest, resources, admission, labels and repository/group access.
2. Prepare and verify the image through the existing external-image lifecycle.
   Setup additionally checks host/user/architecture/volumes and exercises daemon
   readiness with the same bootstrap **before manager replacement**.
3. Start at maximum one, minimum idle zero; run the registered GitHub SQL canary,
   then two-worker isolation and failure drills when separately approved.
4. Compare like-for-like critical paths and resource pressure. Activate only the
   affected native-engine route after evidence and operator approval.
5. Retain the prior manifest and digest. Restore those through supported setup,
   allowing busy workers to finish; registration/routing topology changes require
   the existing explicit stop procedure. Never force turnover to speed rollback.
