---
description: Route general-purpose and specialized GitHub Actions jobs to the correct PitCrew profile.
---

# Routing Workloads

Use explicit label sets so routine CI and specialized workloads consume the
intended capacity. GitHub requires every requested label to match, but extra
runner labels do not exclude a runner.

## Route general-purpose jobs

The default profile keeps GitHub's `self-hosted`, operating-system, and
architecture labels and adds `general-purpose`:

```yaml
jobs:
  build:
    runs-on: [self-hosted, linux, x64, general-purpose]
```

Legacy `runs-on: self-hosted` jobs remain compatible, but the explicit label
makes the capacity requirement clear.

## Keep a manual cloud fallback

GitHub has no automatic fallback when a matching self-hosted runner is offline.
A repository variable can provide a manual switch:

```yaml
jobs:
  build:
    runs-on: ${{ vars.CI_RUNNER || fromJSON('["self-hosted","linux","x64","general-purpose"]') }}
```

Leave `CI_RUNNER` unset for PitCrew, or set it to `ubuntu-latest` to use
GitHub-hosted Linux.

## Route specialized jobs

Named profiles omit `self-hosted` by default and receive explicit `linux`,
architecture, and profile-name labels:

```yaml
jobs:
  evaluate:
    runs-on: [linux, x64, copilot-cli]
```

Do not add `self-hosted` to an isolated profile. That would make broad legacy
jobs eligible for the specialized capacity.

### Queue isolation is not host isolation

Separate labels isolate GitHub queue eligibility, not aggregate Docker-host
resources. Fixed and autoscaled profiles on one host can still compete for CPU,
memory, process, network, and storage capacity unless every relevant profile
participates in a validated host-local admission namespace.

Host-local admission controls new worker starts after GitHub routing has
identified demand. It does not reorder the queue, force GitHub to choose this
host, preempt a running job, or constrain an uncoordinated profile or process.
See [Host-Local Admission Operations](host-admission.md). Do not claim protected
headroom until coordinated admission is enabled and reports `available` for
every participating profile.

Autoscaled profiles publish the same effective label set through their GitHub
runner scale sets. Enabling autoscaling therefore does not require changing a
correctly labeled `runs-on` declaration.

## Route native operating systems

PitCrew's container workers are Linux runners. Keep Windows and macOS jobs on
native hosts:

```yaml
jobs:
  windows:
    runs-on: windows-latest
```

## Route Docker-dependent jobs

Ordinary worker containers are socketless and cannot run container actions,
service containers, Testcontainers, or Docker builds. Keep integration workloads on
a suitable GitHub-hosted or deliberately isolated Docker-capable runner:

```yaml
jobs:
  integration:
    runs-on: ubuntu-latest

  build:
    runs-on: [self-hosted, linux, x64, general-purpose]
```

Dockerfile publication can use the bounded
[Isolated Image Builder](isolated-image-builder.md) profile. It exposes BuildKit,
not Docker control. Hardware-accelerated Android tests can use
[Android Emulator Runners](android-emulator.md), which receive KVM but no Docker
socket or blanket privilege.
