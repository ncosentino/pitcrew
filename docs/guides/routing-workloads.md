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

Worker containers are socketless and cannot run container actions, service
containers, Testcontainers, or Docker builds. Keep those jobs on a suitable
GitHub-hosted or deliberately isolated Docker-capable runner:

```yaml
jobs:
  integration:
    runs-on: ubuntu-latest

  build:
    runs-on: [self-hosted, linux, x64, general-purpose]
```
