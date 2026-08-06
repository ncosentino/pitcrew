---
description: Reference every PitCrew setup parameter, runner-profile field, generated state value, and default.
---

# Configuration

`Setup-Runner.ps1` is the operator entry point. Each invocation converges one
profile without changing other profiles on the same host.

## Setup parameters

| Parameter | Required | Description | Default |
|-----------|----------|-------------|---------|
| `-Token` | No | Fine-grained PAT used only to register runners. When omitted for an existing profile, PitCrew reuses its stored token before trying `gh auth token`. | Stored profile token, then authenticated `gh` token |
| `-Profile` | No | Built-in profile name. | `default` |
| `-ProfilePath` | No | Path to an external profile manifest. Relative image-build paths resolve from the manifest directory. | None |
| `-Scope` | No | GitHub runner scope: `repo`, `org`, or `ent`. | `repo` |
| `-Repos` | Repository scope | Repository URLs, optionally followed by `=workers`. | None |
| `-AddRepos` | No | Adds repositories to the selected profile's generated state. | None |
| `-RemoveRepos` | No | Removes repositories from the selected profile's generated state. | None |
| `-OrgName` | Organization scope | GitHub organization name. | None |
| `-EnterpriseName` | Enterprise scope | GitHub enterprise name. | None |
| `-Replicas` | No | Default workers per repository, or total workers for organization/enterprise scope. `0` auto-sizes to half the host processors with a minimum of two. | Profile value |
| `-Labels` | No | Comma-separated custom labels. The mandatory profile label remains. | Profile value |
| `-NamePrefix` | No | Prefix shown for runner registrations in GitHub. | Host name plus profile |
| `-Image` | No | Overrides the profile's worker image. | Profile value |
| `-PullImage` | No | Controls whether setup pulls a prebuilt image before verification. | Profile value |
| `-RunnerGroup` | No | Organization or enterprise runner group. | Profile value |
| `-Autoscale` | No | Enables GitHub Runner Scale Set demand-driven activation. Configured counts become maximum capacity. | Off |
| `-MinimumIdle` | No | Warm idle runners retained per autoscaled target. | `0` |
| `-ScaleDownDelaySeconds` | No | Stable low-demand period before excess idle JIT runners are removed. | `120` |
| `-MaximumActiveWorkers` | No | Contract-11 aggregate active-worker ceiling across all targets in an autoscaled profile. | None |
| `-WorkerMemory` | No | Contract-11 per-worker memory limit in bytes or a binary unit such as `512MiB` or `2g`. | Unlimited |
| `-WorkerMemorySwap` | No | Contract-11 total memory-plus-swap limit. Requires `-WorkerMemory` and cannot be lower than it. | Unlimited |
| `-WorkerCpus` | No | Contract-11 positive per-worker CPU limit with at most nine fractional digits. | Unlimited |
| `-WorkerPids` | No | Contract-11 positive per-worker process limit. | Unlimited |
| `-Down` | No | Stops only the selected profile and removes its managed workers. | Off |
| `-Refresh` | No | Builds and hot-swaps only the selected manager while preserving compatible workers and active jobs. | Off |
| `-CapacityOnly` | No | Requires an in-place capacity update and fails rather than replacing a manager when the current profile cannot reconcile capacity safely. | Off |
| `-Pause` | No | Reuses the existing desired targets, sets their effective capacity to zero, and drains busy workers naturally without stopping the manager. | Off |

## Repository worker counts

Repository scope supports a different count for every target:

```powershell
.\Setup-Runner.ps1 -Repos `
    https://github.com/you/light-project=1,`
    https://github.com/you/heavy-project=6
```

These workers are dedicated to their repositories. Use organization or
enterprise scope when several repositories should share one capacity pool.

## Profile manifest

Named profiles conform to
[`runner-profile.schema.json`](https://github.com/ncosentino/pitcrew/blob/main/runner-profile.schema.json).

| Field | Required | Description |
|-------|----------|-------------|
| `schemaVersion` | Yes | Manifest contract version. Version `1` is currently supported. |
| `name` | Yes | Lowercase profile identifier and mandatory routing label. |
| `description` | Yes | Human-readable purpose. |
| `image` | Yes | Worker image tag. |
| `labels` | Yes | Additional capability labels. |
| `replicas` | Yes | Default positive worker count. |
| `pullImage` | No | Pull a prebuilt image before verification. |
| `disableDefaultLabels` | No | Omit GitHub's broad default labels. Named profiles default to `true`. |
| `runnerGroup` | No | Organization or enterprise runner group. |
| `autoscaling` | No | Scale-set mode, minimum idle runners, scale-down stabilization delay, and optional aggregate admission ceiling. |
| `readOnlyVolumes` | No | Existing external Docker named volumes mounted at deterministic `/mnt/pitcrew-data/<name>` paths. |
| `serviceNetwork` | No | One existing local, non-internal Docker bridge network that provides stable DNS for operator-owned profile services. |
| `resources` | No | Contract-11 per-worker memory, memory-plus-swap, CPU, and PID policy. |
| `verificationCommands` | No | Shell commands executed in the prepared image before profile replacement. |
| `build` | No | Local Docker build context, Dockerfile, and non-secret build arguments. |

### Autoscaling policy

| Field | Required | Description | Default |
|-------|----------|-------------|---------|
| `mode` | Yes | GitHub demand integration. `scale-set` is supported. | None |
| `minimumIdle` | No | Warm idle JIT runners retained per target. | `0` |
| `scaleDownDelaySeconds` | No | Stable low-demand period before idle removal. | `120` |
| `maximumActiveWorkers` | No | Aggregate active-worker ceiling across all targets. Must be positive. | None |

`minimumIdle` and prewarming can reduce cold-start exposure, but they are
operational mitigations rather than proof of any host, network, or package-feed
root cause.

### Read-only external volumes

Each entry contains:

| Field | Required | Description |
|-------|----------|-------------|
| `name` | Yes | Unique logical lowercase name; the worker target becomes `/mnt/pitcrew-data/<name>`. |
| `source` | Yes | Existing external Docker named volume. PitCrew never creates or removes it. |

Setup inspects every source before manager handoff and attaches the volumes to
image-verification containers. The normalized contract contributes to worker
revision, so source changes roll safely while busy workers retain their
original mounts. Volume changes are rejected by `-Refresh` and
`-CapacityOnly`.

Only read-only named volumes are supported. Bind mounts, arbitrary targets,
devices, sockets, driver options, and credentials are outside the profile
contract. See [Read-Only External Data Volumes](guides/external-data-volumes.md).

### External service network

`serviceNetwork.source` names one existing user-defined Docker network. Setup
requires the exact network to use the local `bridge` driver with
`Internal=false`, rejects Docker's built-in `bridge`, then attaches
image-verification containers and new workers with `--network <source>`.

The network contributes to worker revision, so source changes roll while busy
workers retain their original network. Service-network changes are rejected by
`-Refresh` and `-CapacityOnly`.

PitCrew never creates, configures, removes, or attaches the service itself.
Aliases, ports, storage, credentials, and service health remain
operator-owned. Manager Compose networks are reserved and cannot be selected.
Use one service network per profile or trust boundary because containers on a
shared bridge network can reach each other's exposed ports. See
[Pool-Local Services](guides/pool-local-services.md).

### Contract-11 resource policy

The profile schema defines the following future contract:

```json
{
  "schemaVersion": 1,
  "name": "bounded-build",
  "description": "Build workers with explicit resource admission.",
  "image": "example/runner:1.0.0",
  "labels": ["build"],
  "replicas": 8,
  "autoscaling": {
    "mode": "scale-set",
    "minimumIdle": 1,
    "scaleDownDelaySeconds": 120,
    "maximumActiveWorkers": 6
  },
  "resources": {
    "memory": "8GiB",
    "memorySwap": "10GiB",
    "cpus": "2.5",
    "pids": 1024
  }
}
```

Memory units use powers of 1024 and are stored as canonical byte counts.
Memory must be at least 6 MiB. `memorySwap` is total memory plus swap, requires
`memory`, and must be greater than or equal to it. Unlimited `-1` values are not
accepted. CPU values are stored as invariant decimal strings without
insignificant zeroes. Empty generated environment values mean no configured
limit; managers must not interpret them as zero.

Resource policy and `maximumActiveWorkers` were introduced in manager contract
11 and remain supported by the active contract 17 managers. A profile that
still runs an older manager upgrades through the established manager hot-swap,
and its existing workers are preserved and converge naturally. Activation
occurs only after both manager modes implement the same contract, so a newer
contract is still refused before Docker, image, or generated state mutation.

## Worker image shutdown contract

The default worker image retains its GitHub credential only in the entry-point
shell and explicitly does not export that credential to the runner process.
PitCrew leaves the private shell value available so the image can deregister on
`SIGTERM`. Manager stop and restart signal all workers concurrently, wait a
bounded period, and force-remove only exact-label leftovers.

Custom worker images must provide the same contract: handle `SIGTERM`,
deregister the current runner, keep registration credentials out of the runner
process and workflow environment, and exit within the manager's shutdown
window. Images that discard their deregistration credential after startup can
leave offline runner registrations behind.

## Generated state

The default profile writes `.env`; named profiles write `.env.<profile>`. These
static environment files contain the runner-registration token plus image,
immutable local image ID, labels, scope, runner group, name-prefix settings,
and canonical manager policy. PitCrew generates them and Git ignores them. Do
not edit or commit them.

Mutable capacity is stored separately under
`.pitcrew-state/<profile>/desired-capacity.json`. The document contains no
registration token or workload credential. Setup validates the complete next
document, writes it through a temporary file and atomic rename, and waits for
the running manager to acknowledge its generation.

Each manager also projects credential-free operational status to
`.pitcrew-state/<profile>/observed-state.json`. The manager replaces this file
atomically after slot lifecycle changes and on a low-frequency heartbeat. It
contains the manager instance, accepted generation, desired-state health, and
per-slot lifecycle state. Every 30 seconds, the same projection samples host
capacity plus manager and worker CPU cores, memory working-set bytes, and PID
counts. A CPU value of `1.0` represents one fully utilized logical processor and
can exceed `1.0` for a multi-core workload.

Resource telemetry is marked `available`, `partial`, or `unavailable`; missing
measurements remain `null` rather than appearing as zero usage. The manager
collects these values through its existing Docker socket. Connectors and
dashboard services continue to consume only the read-only state projection and
do not receive Docker access.

Manager contract 7 introduces these additive fields. Older connectors continue
to relay lifecycle state but discard fields they do not recognize, so update the
optional connector and dashboard before expecting resource cards to appear.
Manager contract 8 adds configured-maximum and autoscaling state while retaining
the same credential-free connector boundary.
Manager contract 9 adds worker revision and rolling-convergence state. Manager
replacement preserves sibling workers; scale-set profiles safely replace stale
idle JIT runners through GitHub's service-side removal fence.
Current managers also identify the configured target image reference and its
resolved immutable local image ID in that rollout projection. Legacy contract-9
through contract-11 observations that omit those additive fields remain valid;
consumers must report the target identity as unavailable rather than infer it
from one live worker.
Manager contract 10 adds GitHub registration reconciliation. Each slot reports
whether its runner is connected, disconnected, missing from GitHub, or unknown,
and the profile reports eligible capacity separately from running containers.
Fixed managers replace only exact workers that remain missing or offline and
not busy across repeated server-side observations.

The contract-11 schema adds the configured resource policy, immutable image
identity, cumulative network and block-I/O counters, exit diagnostics, an
aggregate autoscaling ceiling, timestamped GitHub scale-set statistics, and
separate local worker counts. A representative field excerpt is:

```json
{
  "resourcePolicy": {
    "memoryBytes": 8589934592,
    "memorySwapBytes": 10737418240,
    "cpuCores": "2.5",
    "pids": 1024
  },
  "autoscaling": {
    "maximumActiveWorkers": 6,
    "targets": [
      {
        "key": "repo:example/project",
        "repository": "https://github.com/example/project",
        "maximumSlots": 8,
        "targetSlots": 2,
        "localActiveWorkers": 2,
        "localIdleWorkers": 0,
        "localBusyWorkers": 2,
        "localDrainingWorkers": 0,
        "statistics": {
          "observedAt": "2026-07-26T12:00:00Z",
          "availableJobs": 0,
          "acquiredJobs": 0,
          "assignedJobs": 2,
          "runningJobs": 2,
          "registeredRunners": 8,
          "busyRunners": 2,
          "idleRunners": 6
        }
      }
    ]
  },
  "update": {
    "status": "rolling",
    "targetImage": "ghcr.io/example/project-runner@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "targetImageId": "sha256:2222222222222222222222222222222222222222222222222222222222222222",
    "targetRevision": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    "currentWorkers": 1,
    "staleWorkers": 1,
    "lastError": null
  },
  "slots": [
    {
      "resources": {
        "cpuCores": 1.25,
        "memoryWorkingSetBytes": 2147483648,
        "pids": 48,
        "networkRxBytes": 1048576,
        "networkTxBytes": 262144,
        "blockReadBytes": 536870912,
        "blockWriteBytes": 134217728
      },
      "imageId": "sha256:1111111111111111111111111111111111111111111111111111111111111111",
      "lastExit": {
        "observedAt": "2026-07-26T11:55:00Z",
        "classification": "oom-killed",
        "exitCode": 137,
        "signal": 9,
        "dockerOomKilled": true,
        "evidence": "docker-inspect"
      }
    }
  ]
}
```

The excerpt shows the exact contract-11 field shapes but omits unchanged
top-level and slot fields. I/O counters are cumulative. `null` means a
measurement is unavailable; zero means it was measured as zero. GitHub
statistics are timestamped external evidence, while `local*Workers` describe
local containers. Neither source substitutes for the other.

Exit classification uses this precedence: Docker-confirmed OOM, `SIGKILL`,
another signal, clean zero exit, ordinary nonzero error, launch failure, then
unknown. Exit code 137 alone does not prove an OOM kill.

The fixed manager already publishes these projections. It applies the configured
memory, swap, CPU, and PID limits to every worker it launches, so a policy change
converges as busy workers finish their current job and are replaced. Exit
evidence comes from Docker: the container state when it is still readable, and
otherwise the wait status plus a bounded out-of-memory event lookup for the exact
container. When Docker offers no usable evidence the slot reports `unknown`
rather than a clean exit, and an unconfirmed out-of-memory kill stays `null`.

### Contract-12 operation evidence

The contract-12 schema adds three additive projections: a durable manager
operation journal, current Docker and GitHub subsystem summaries, and explicit
capacity-deficit evidence. Every field is nullable for contract-11 and older
observations, so contract-10 and contract-11 readers are unaffected.

```json
{
  "operationJournal": {
    "status": "current",
    "capacity": 64,
    "highestSequence": 45,
    "droppedEvents": 0,
    "events": [
      {
        "sequence": 45,
        "managerInstanceId": "manager-instance-b",
        "observedAt": "2026-07-26T12:00:00Z",
        "subsystem": "worker-launch",
        "operation": "worker-launch",
        "target": "repo-example-000001",
        "outcome": "retry-scheduled",
        "durationMilliseconds": null,
        "attempt": 2,
        "consecutiveFailures": 2,
        "retryAt": "2026-07-26T12:00:30Z",
        "reason": "retry-backoff",
        "evidence": "Worker launch is waiting for its backoff window"
      }
    ]
  },
  "subsystemHealth": {
    "docker": {
      "state": "healthy",
      "observedAt": "2026-07-26T12:00:00Z",
      "consecutiveFailures": 0,
      "retryAt": null,
      "lastSuccess": {
        "operation": "docker-ping",
        "observedAt": "2026-07-26T12:00:00Z",
        "durationMilliseconds": 0,
        "reason": "none",
        "evidence": null
      },
      "lastFailure": null
    },
    "github": {
      "state": "degraded",
      "observedAt": "2026-07-26T12:00:00Z",
      "consecutiveFailures": 1,
      "retryAt": "2026-07-26T12:00:30Z",
      "lastSuccess": null,
      "lastFailure": {
        "operation": "registration-token-request",
        "observedAt": "2026-07-26T11:59:30Z",
        "durationMilliseconds": 30000,
        "reason": "timeout",
        "evidence": "Registration token request exceeded its deadline"
      }
    }
  },
  "capacityEvidence": {
    "fixed": {
      "observedAt": "2026-07-26T12:00:00Z",
      "freshness": "current",
      "targetSlots": 2,
      "activeWorkers": 1,
      "startingWorkers": 0,
      "drainingWorkers": 0,
      "cleanupPendingWorkers": 0,
      "eligibleWorkers": 1,
      "localDeficit": 1,
      "eligibilityDeficit": 1,
      "reason": "retry-backoff",
      "evidence": "One worker is waiting for its launch backoff window"
    },
    "targets": []
  }
}
```

The journal is persisted atomically beneath the profile state directory, so it
survives ordinary manager restart and hot-swap. `sequence` is durable and
monotonic across restarts, so dashboards deduplicate on the profile plus the
sequence and treat `managerInstanceId` as the observer rather than the identity
of the event. The journal retains failures, state transitions, retries, and
recovery instead of every reconciliation pass.

Journal limits are strict and enforced: at most 64 retained events, at most 160
characters of sanitized `evidence` per event, and at most 16384 serialized
bytes. `subsystem`, `operation`, `outcome`, and `reason` are closed
vocabularies; a manager that needs a new value needs a new contract version.
`evidence` excludes `:`, `/`, `@`, `?`, `=`, and `&`, so tokens, URLs, HTTP
bodies, environment values, JIT payloads, job output, and raw Docker or GitHub
stderr cannot be relayed. `target` is limited to a slot or autoscaling target
key that already appears in non-secret state.

Journal `status` separates the intact window (`current`) from a window that
discarded older, malformed, or oversized entries (`truncated`, which requires a
nonzero `droppedEvents`) and from a journal the manager could not read or
restore (`unavailable`, which reports no events). A discarded journal never
discards otherwise valid observed state. An empty `events` array with status
`current` means no notable event has occurred.

Subsystem summaries describe operations PitCrew itself performed. They are not
a claim that the host, Docker daemon, network, or GitHub service is healthy.
`unknown` means the manager has performed no such operation yet and therefore
carries no evidence, `healthy` requires a last success and zero consecutive
failures, and `degraded` or `unavailable` requires a last failure and at least
one consecutive failure.

Capacity evidence separates the actual target from local and control-plane
counts. `targetSlots` is `desiredSlots` for a fixed profile and the activation
`targetSlots` for an autoscaling target; a configured autoscaling maximum is
not a health target and never creates a deficit by itself. `eligibleWorkers`
and `eligibilityDeficit` are `null` together when the manager has no current
control-plane evidence, while `0` means it observed none. `freshness`
distinguishes `current` and `stale` measurements from `unavailable` evidence,
which reports the `unknown` reason because the manager observed nothing to
blame. `reason` is observed manager state, never a diagnosis inferred by a
dashboard.

Manager contract 12 introduced the external service-network launch contract
while retaining its diagnostic projections.

### Contract-13 host hardware inventory

Contract 13 adds a top-level `host.hardware` projection. It describes only
sanitized capacity and runtime facts visible to the manager:

```json
{
  "host": {
    "hardware": {
      "status": "current",
      "collectedAt": "2026-08-03T12:00:00Z",
      "attemptedAt": "2026-08-03T12:05:00Z",
      "inventoryHash": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
      "processorModel": "Example Processor",
      "architecture": "amd64",
      "physicalCoreCount": 10,
      "logicalProcessorCount": 20,
      "performanceCoreCount": null,
      "efficiencyCoreCount": null,
      "memoryBytes": 34359738368,
      "operatingSystem": "Docker Desktop",
      "kernelVersion": "6.12.34",
      "dockerServerVersion": "28.3.3",
      "dockerStorageDriver": "overlayfs",
      "dockerBackingFilesystem": "extfs"
    }
  }
}
```

Every potentially unsupported field is present and nullable. PitCrew does not
infer performance- and efficiency-core counts from processor marketing names.
`current` means the latest bounded Docker probe succeeded, `stale` retains the
last valid inventory after a failed refresh, and `unavailable` contains no
retained values.

The inventory hash covers only the ordered hardware values, not timestamps or
freshness. An unchanged inventory preserves `collectedAt` across periodic
samples and manager handoff. A changed processor, topology, memory allocation,
OS/kernel, Docker version, storage driver, or backing filesystem produces a new
hash and collection timestamp.

The projection excludes usernames, absolute paths, serial numbers, machine
GUIDs, network addresses, MAC addresses, Docker root paths, credentials,
registration material, and job output.

Manager contract 17 is active in this release. Both manager modes publish the
same hardware contract while retaining contract-11 resource and contract-12
diagnostic semantics. Setup fails closed before Docker, image, or generated
state mutation if a contract ahead of both implementations is selected.

### Contract-14 runner correlation

Contract 14 adds `runnerNameHash` to every observed slot. For a live worker it
is the lowercase SHA-256 digest of the exact UTF-8 runner name registered with
GitHub. The field is `null` whenever the manager does not currently hold a
usable exact runner identity, including non-running and launch-backoff slots.

The hash is a correlation key, not an authentication value or a fuzzy host
identifier. A diagnostic client can hash the exact `runner_name` already
returned by GitHub job metadata and compare by equality. PitCrew never
publishes the raw runner name, configured prefix, container name, container ID,
registration payload, JIT configuration, token, or job output.

The stable slot `key` remains unchanged and continues to own reconciliation.
Dashboard retention of historical hash-to-node/profile assignments is a
separate downstream responsibility; PitCrew observed state reports only the
current bounded slot projection.

### Contract-15 active job context

Contract 15 adds `currentJob` to every observed slot. Fixed workers, idle
workers, recovered workers whose start event cannot be reconstructed, and
other unattributed workers report `null`. An autoscaled worker reports a
bounded object while the scale-set listener owns usable lifecycle metadata for
its current job.

The object contains only the canonical GitHub repository URL, workflow-run and
job identifiers, bounded display and event names, queue/assignment/start
timestamps, and a bounded finish result while the draining worker still
exists. Dashboard can derive an exact GitHub job link and retain the interval
after the ephemeral worker exits.

PitCrew does not publish the workflow ref, requested labels, runner ID or name,
job message payload, logs, step output, environment values, commit text,
registration material, or credentials. Invalid or oversized metadata degrades
only `currentJob`; the worker remains busy and protected. Resource activity is
never used to invent missing job identity.

### Contract-16 Docker-host pressure

Contract 16 adds `resourceTelemetry.hostPressure`. The manager reads aggregate
CPU, load, memory, swap, and optional Linux Pressure Stall Information from a
read-only `/proc` mount that belongs only to the manager container.

The source is named `docker-host` because it describes the Docker engine's
execution domain. On native Linux that is the Docker host kernel. On Docker
Desktop or WSL it is the Linux VM that runs the containers, not a claim about
the complete physical Windows or macOS machine.

The first CPU sample is `partial` because utilization requires two monotonic
counter observations. Load and memory remain available immediately. PSI
`some` and `full` ten-second averages are optional; kernels that do not expose
them report `null` without degrading otherwise complete core pressure.
Counter reset, manager restart, malformed files, or unavailable host-proc
access never become measured zero.

Only aggregate files are read. PitCrew does not enumerate or publish process
IDs, command lines, environment values, mount paths, or per-process data.
Pressure remains diagnostic evidence; it never cancels a job, stops a worker,
or changes admission automatically.

The fixed shell manager keeps the journal, the Docker summary, and the GitHub
summary under `diagnostics/` inside the profile state directory and
writes each file atomically, so an ordinary manager restart or handoff
preserves the preceding causal sequence without replaying events. The retained
window is bounded to 32 events and a bounded serialized size; older events are
dropped into `droppedEvents` and the journal reports `truncated`. A corrupt or
unreadable journal degrades only the journal, and a failed diagnostic write
never stops a worker, changes cleanup selectors, or discards desired state.
Healthy reconciliation is not journaled: the fixed manager records state
transitions, failures, retry scheduling, recovery, and unusually slow
operations rather than every loop.

The projection contains no registration token, environment values, job logs,
container identity, or Docker socket details. Resource usage does not identify
whether a runner is busy, so consumers must not infer job state from CPU or
memory activity. Consumers must use `observedAt` and the resource
`sampledAt` value to reject stale status after an ungraceful manager exit.

For repository scope, desired state records each repository URL and worker
count. Organization and enterprise scope record one shared replica count. The
manager derives stable ordinal slot keys, so changing a repository from five
workers to six starts only ordinal six. Changing it back to five drains only
ordinal six.

### Contract-17 zero-capacity pause

An existing desired target may carry zero capacity. `-Pause` writes that state
through the normal capacity-only generation and acknowledgement path while
retaining repository routing, scale-set identity, manager state, and history.
It is distinct from manifest `replicas`, which remains a positive default, and
from `-Replicas 0`, which keeps its auto-size meaning. Resume by applying a
positive capacity with `-CapacityOnly`. Pause reuses the already accepted
targets and does not require a new GitHub runner-registration access probe;
resume and every positive capacity change retain the normal token validation.

For autoscaled profiles, the same values are configured maximums. GitHub's
assigned-job statistics determine current activation between the minimum idle
floor and each maximum.

## Capacity reconciliation

When the static profile fingerprint is unchanged and the manager is running,
setup skips image pull/build and verification, leaves the manager container
untouched, and publishes only desired capacity. Reapplying identical capacity
is a no-op.

Scale-down is graceful:

- A runner already executing a job is never force-removed because capacity
  decreased.
- Once the draining runner container exits, its slot stops instead of spawning
  a replacement.
- An idle ephemeral runner can accept one final job before it exits. PitCrew
  does not query GitHub's runner `busy` state in this reconciliation path.

Changes to labels, default-label behavior, scope, organization or enterprise
identity, runner group, name prefix, registration token, build or verification
contract, or manager runtime contract continue to replace the selected
profile. Worker image content and resource-policy changes advance the worker
revision but remain rolling-compatible, so busy workers can finish before
replacement. `maximumActiveWorkers` changes manager compatibility without
changing the worker revision.

Use `-Refresh` after switching an installation checkout to a new PitCrew
release when the manager implementation changed without changing its runtime
worker configuration. Refresh builds the replacement first and hands off
existing workers without requiring them to be idle. Apply rolling-compatible
worker image or resource-policy changes with the complete setup command; stop
explicitly before routing or registration-topology changes. `-Refresh` and
`-CapacityOnly` reject a changed local image ID even when its mutable tag is
unchanged.

Setup records Docker's immutable local `sha256:<64 hex>` image ID after pull or
build and includes it in worker revision and refresh compatibility. A legacy
static profile without this identity requires one complete safe setup run; it
cannot be migrated with `-Refresh` or `-CapacityOnly`.

For a manifest-backed profile, `static-profile.json` also retains local
non-secret manifest provenance: built-in or external kind, source path, SHA-256
content hash, and the parsed manifest document. Operations tooling can replay
the approved snapshot without accepting a later source change implicitly.
These local paths and manifest documents are never copied into observed state.

Locally built profiles also fingerprint their complete build-context inventory.
Generated PitCrew state and the selected secret environment are excluded. The
fingerprint is intentionally conservative: a file Docker later excludes may
trigger an unnecessary rebuild, but a changed copied input cannot be skipped.

## Legacy and direct Compose bootstrap

When neither desired nor last-valid state exists, the manager can import
`REPO_URLS` or `REPO_URL` for repository scope, or `RUNNER_REPLICAS` for
organization and enterprise scope. This is a one-time adapter for
pre-reconciliation `.env` files and direct `docker compose up` usage.
Direct Compose requires a stable `PITCREW_SESSION_OWNER` and a 64-character
`PITCREW_WORKER_REVISION`. Contract-11 direct Compose also requires the exact
local `PITCREW_WORKER_IMAGE_ID` and canonical policy values documented in
`.env.example`.

After the adapter creates generation one, environment changes do not alter
capacity. Use `Setup-Runner.ps1` for every subsequent update so generation,
locking, atomic publication, and acknowledgement remain enforced.

Manager termination without a container-targeted shutdown request preserves
workers for handoff. Use `Setup-Runner.ps1 -Down` rather than routine
`docker compose down` when the intent is to remove the complete profile.

The mounted directory contains no credentials. If Docker creates a missing bind
source as root, the manager makes that directory host-writable so a later setup
command can replace state atomically. Pre-create the directory when stricter
host ownership is required.

On the first setup run after upgrading, `-AddRepos` and `-RemoveRepos` import
repository targets from the old profile environment when desired state has not
been created yet.
