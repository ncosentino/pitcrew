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

Manager contract 11 is active in this release. Both the fixed and autoscaled
managers implement it, so setup accepts a resource policy and
`maximumActiveWorkers` and pins the contract in generated state. A profile that
still runs a contract-10 manager upgrades through the established manager
hot-swap, and its existing workers are preserved and converge naturally.
Activation occurs only after both manager modes implement the same contract, so
a newer contract is still refused before Docker, image, or generated state
mutation.

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

Manager contract 12 is defined but not active in this release. Both manager
modes implement contract 11, so setup fails closed before Docker, image, or
generated state mutation if a contract ahead of both implementations is
selected. Contract-11 resource, image, exit, and worker-revision semantics are
unchanged.

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
