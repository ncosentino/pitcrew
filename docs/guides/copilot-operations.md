---
description: Install PitCrew's Copilot CLI plugin and use its skills for capacity and version updates.
---

# Copilot CLI Operations

PitCrew publishes an installable Copilot CLI marketplace plugin that teaches
Copilot the repository's supported operational procedures. The plugin does not
add a remote control plane or replace `Setup-Runner.ps1`; it makes Copilot use
the existing scripts, scoped Compose commands, and read-only diagnostics
consistently.

## Install the plugin

Register the PitCrew repository as a marketplace, then install the operations
plugin:

```powershell
copilot plugin marketplace add ncosentino/pitcrew
copilot plugin install pitcrew-operations@pitcrew
```

The plugin intentionally does not pre-approve shell execution. Copilot still
requests permission before running operational commands.

Refresh the marketplace and plugin after PitCrew publishes an update:

```powershell
copilot plugin marketplace update pitcrew
copilot plugin update pitcrew-operations@pitcrew
```

## Capacity skill

`pitcrew-capacity` adds, removes, or resizes workers through
`Setup-Runner.ps1`. It also enables, disables, or tunes autoscaling without
introducing another skill. It reads only non-secret generated state and verifies
the manager's acknowledgement and observed policy.

Example prompts:

```text
Use the pitcrew-capacity skill to set the copilot-cli profile to four workers
for https://github.com/example/project.
```

```text
Use the pitcrew-capacity skill to remove
https://github.com/example/retired-project from the default pool.
```

```text
Use the pitcrew-capacity skill to enable autoscaling for the copilot-cli
profile, keep zero idle workers, wait 120 seconds before scaling down, and keep
the current configured maximums.
```

```text
Use the pitcrew-capacity skill to change the autoscaled copilot-cli profile to
two minimum idle workers without changing its configured maximum.
```

Maximum-only updates require `-CapacityOnly` and leave the manager untouched.
Scale-set tuning hot-swaps the manager without interrupting workers. Enabling
or disabling scale-set mode requires an explicit idle profile stop because it
changes registration topology.

## Pool update skill

`pitcrew-pool-update` updates a deployment checkout to a published PitCrew
release and invokes `Setup-Runner.ps1 -Refresh` for each configured profile.

```text
Use the pitcrew-pool-update skill to update this host to the latest published
PitCrew release.
```

The skill refuses to substitute `main` when no release exists. A profile
refresh builds the replacement manager first, stops only that manager, and
adopts its existing workers. Scale-set profiles replace stale idle workers
immediately and preserve assigned workers until completion. Fixed workers use
their new image on natural ephemeral turnover because GitHub's classic runner
deletion API is not an idle-only fence.

`update.status: rolling` is a successful manager update with worker convergence
still in progress. The skill reports stale workers instead of waiting for an
all-idle maintenance window. Dashboard updates run independently and are never
blocked by that rollout.

`Setup-Runner.ps1` reuses the selected profile's stored registration token when
`-Token` is omitted. Copilot never needs to display or place that token in a
command.

## Profile rollout skill

`pitcrew-profile-rollout` applies one reviewed external profile image revision
without changing routing, topology, capacity, or credentials.

```text
Use the pitcrew-profile-rollout skill to apply the reviewed project-ci profile
manifest on this host.
```

The skill always performs a read-only compatibility dry run first. It rejects
label, scope, runner-group, prefix, or manager-mode changes; replays the complete
stored capacity; lets setup prepare and verify the candidate before handoff; and
reports target image identity plus current and stale workers. A rolling state is
successful partial convergence, so the skill never waits for active jobs or
restarts Docker.

Read-only external volume additions, removals, and source changes are reported
separately and roll with the worker revision. The skill verifies each existing
named volume before mutation and never creates, populates, removes, or reveals
driver options for external storage.

External service-network additions, removals, and source changes are also
rolling worker revisions. The skill verifies the exact local, non-internal
bridge network before mutation, reports only its non-secret name, and never
creates, removes, configures, or attaches the service.

## Dashboard update skill

`pitcrew-dashboard-update` updates a hosted PitCrew Dashboard deployment using
its complete base-plus-ingress Compose model.

```text
Use the pitcrew-dashboard-update skill to update the Cloudflare-hosted
dashboard to the latest release.
```

The skill changes only `PITCREW_DASHBOARD_VERSION`, pulls only the dashboard
service, and runs scoped `up --detach --wait`. It never restarts Docker, runs
host-wide cleanup, uses `docker compose down` for a routine update, or bypasses
ingress dependency coordination. GitHub release tags such as `v0.3.1` are
normalized to GHCR image tags such as `0.3.1` before the environment file is
changed. Before updating, the skill creates and fully verifies a timestamped
SQLite backup with the dashboard's bundled database tool. The target image is
pre-pulled first, then the scoped stack is stopped so no writes occur after the
backup snapshot. The new dashboard passes its private health contract before
ingress is enabled. Failures before ingress activation restore both the previous
image and database; after ingress opens, the skill preserves new writes instead
of automatically restoring an older snapshot.

The same skill enables protocol-v3 capacity controls as one automated
operation. It downloads the release-pinned host connector and installer,
migrates the existing connector identity, installs a native systemd or Windows
Service, and restores the container if startup fails. Operators do not manually
build binaries, copy credentials, or write service files.

## Host diagnostics skill

`pitcrew-host-diagnostics` collects read-only evidence about a degraded runner
host without restarting Docker, stopping busy workers, or running cleanup.

```text
Use the pitcrew-host-diagnostics skill to explain why the copilot-cli profile is
slow, and time https://github.com from the host and a worker image.
```

The skill resolves one installation and profile, reads only generated
non-secret state, reports the exact manager and worker image references with
their resolved local image IDs and digests, and captures bounded `docker stats
--no-stream` CPU, memory, PID, `NetIO`, and `BlockIO` samples for exact PitCrew
labels. It also collects `docker system df`, the Docker network count, exact-ID
per-worker writable-layer sizes, host free space and inodes where supported, and
read-only network-adapter error and drop counters, selecting Linux or Windows
commands from the runner host platform.

Because live worker counts and registered capacity drift apart on a degraded
host, the skill compares live labelled containers per target against desired,
acknowledged, and observed capacity plus any scale-set statistics already in
observed state, including their freshness. It never issues a credentialed GitHub
query to fill that gap; missing evidence is reported as missing.

For manager contract 18, the same report projects the complete bounded
`hostAdmission` status, namespace, epoch, decision sequence, host policy,
profile cost and reservation, borrowing mode, active/provisional/held/borrowed
accounting, pending and withheld demand, and last decision. It keeps
`host-admission-withheld`, `host-admission-degraded`, and
`host-admission-unavailable` distinct from profile ceilings and provisioning
failures. `unavailable` and stale demand remain missing evidence, never zero.

Caller-approved URLs are timed from the host and from exactly one disposable
container built from the profile's exact worker image, using a caller-approved
finite probe timeout that defaults to 300 seconds so a large artifact is not
truncated into a false failure. Resource snapshots are taken immediately before
and after the probes so `NetIO`, `BlockIO`, adapter-counter, and disk-accounting
deltas can be attributed to the probe window. Downloaded bodies are discarded,
the disposable container's exact ID is proven with `--cidfile` or an explicit
create/start flow, and only that exact container is removed afterwards.

A dry-run mode prints the resolved commands without changing state. The redacted
Markdown/JSON handoff separates verified measurements from unavailable evidence
and unverified hypotheses, and it never converts a single host/container pair
into a root cause: CDN edge variability and load-sensitive host contention stay
competing hypotheses until repeated measurements resolve them.

## Remote diagnostics skill

`pitcrew-remote-diagnostics` starts with Dashboard, GitHub Actions, public
endpoint, and release evidence before it requests anything from a runner node.
It narrows the incident to connector offline, capacity mismatch, job not
assigned, host pressure, or full collection.

The public Dashboard probe accepts an origin-only HTTPS URL (or explicit
loopback HTTP for local testing) and does not follow redirects.

```text
Use the pitcrew-remote-diagnostics skill to investigate why example-node is offline
without changing the node. I do not have a remote transport, so create the
operator handoff bundle.
```

When the current session is already on the node, the skill runs the portable
collector directly. When the caller explicitly supplies a PowerShell-remoting
SSH or WinRM endpoint, it transmits the fixed collector in memory and returns
the structured result without installing an agent or storing credentials. When
no transport exists, it creates a deterministic ZIP containing the collector,
manifest, checksum, exact invocation, and exact node-agent prompt.

The portable `Collect-PitCrewDiagnostics.ps1` script reads only fixed generated
profile state, the standard bounded connector health journal, exact-label
Docker inventory, and optional caller-approved query-free URLs. It does not
read environment files, connector identity, JIT material, registration
payloads, job output, or arbitrary paths. Docker resource queries use exact
labels or IDs; the only cleanup permitted is the collector's own run-scoped
diagnostic container after its exact ID and label are verified.

URL collection accepts at most four approved destinations with a maximum
900-second timeout per probe. Redirects are not followed. The container sample
uses the recorded immutable local worker image ID with `--pull=never` and an
explicit `curl` entrypoint, so diagnostics cannot pull a mutable image or start
the worker registration entrypoint. Curl configuration files are disabled so
an ambient redirect or header rule cannot expand the approved URL boundary.

Returned artifacts are checksum-verified before import. The importer rejects
extra ZIP entries, path traversal, unsupported schemas, package or collector
mismatches, oversized files, unredacted roots, and secret-bearing property
names. It correlates preflight, connector outage, observed-state, and collection
timestamps and emits equivalent JSON and Markdown diagnoses with verified,
unavailable, and hypothesis sections.

The imported diagnosis validates and projects contract-18 host-admission and
capacity-deficit evidence. A missing pre-contract field, coordinator outage, or
unavailable capacity sample is classified explicitly; the importer does not
infer a zero balance or a cause from absent evidence.

Published PitCrew releases include `Collect-PitCrewDiagnostics.ps1` and
`Collect-PitCrewDiagnostics.ps1.sha256` so an operator can verify the same
versioned collector independently of the installed plugin. Maintainers stage
those exact assets from the reviewed plugin source before publishing:

```powershell
pwsh scripts/release/New-PitCrewReleaseAssets.ps1 `
    -OutputDirectory <release-assets>
```

## Performance report skill

`pitcrew-performance-report` joins bounded GitHub Actions job metadata with
scoped Dashboard node, profile, telemetry, hardware, and runner-assignment
history.

```text
Use the pitcrew-performance-report skill to compare jobs from
example/project across my PitCrew nodes for the last six hours.
```

The skill requires an expiring read-only Dashboard diagnostic credential in
`PITCREW_DIAGNOSTICS_CREDENTIAL` and uses the caller's existing `gh`
authentication. The credential is never placed in a command argument or
report.

Only run/job IDs and names, exact runner names, labels, timestamps, status, and
conclusion are queried. Runner names are hashed locally and omitted from the
output; mapping uses exact equality against Dashboard's retained contract-14
assignment hashes. The skill never reads logs, artifacts, environments, step
output, caches, or secrets and cannot mutate workflows, runners, capacity,
managers, Docker, or hosts.

Workflow-run searches cover GitHub's documented 35-day run lifetime and split
time partitions before the API's 1,000-result filtered-search ceiling.

The equivalent Markdown and JSON reports include per-node and per-profile
count, median, p95, range, timeout/cancellation rate, cross-profile overlap,
sanitized hardware context, explicit evidence gaps, and ranked hypotheses.
They state that correlation is not causation and one paired sample is not a
host benchmark.

Contract-18 history adds per-profile admission status counts, latest epoch and
decision sequence, maximum held/borrowed/pending/withheld units, and the
admission-related capacity-deficit reasons observed in the range. These units
are abstract policy accounting, not CPU, memory, or universal workload weights.
Withheld units show that a worker start was gated; they do not prove how long a
GitHub job waited or why a completed job ran slowly.

## Profile recovery skill

`pitcrew-profile-recover` recovers one explicitly selected degraded profile with
a single manager-only restart.

```text
Use the pitcrew-profile-recover skill to recover the degraded copilot-cli
profile on this host.
```

The skill resolves exactly one installation and one named profile, reads only
generated non-secret state, and performs a read-only dry run that prints the
selected profile, the manager contract and exact manager match count, the
current manager instance and generation fences, the local worker count and
observed eligibility evidence, the exact secret-free
`Setup-Runner.ps1 -RecoverManager` invocation, and every prohibited action that
will not occur. It then requires explicit operator confirmation; approval to
diagnose or update a host is not approval to restart a manager.

Recovery itself is a first-class PitCrew operation rather than ad-hoc Docker
commands. `Setup-Runner.ps1 -RecoverManager` takes the profile operation lock,
selects the manager only through `ephemeral-runner-manager-profile=<profile>`,
requires exactly one running contract-9-or-newer manager with no pending
shutdown request, re-verifies the caller's instance, generation, and
desired-state hash fences immediately before mutation, and then issues exactly
one restart against the exact container ID with the existing 60-second graceful
stop window.

Workers are preserved by construction: no worker-directed command is issued at
all, and a worker that exits during the window simply finished its ephemeral
job. Fixed and autoscaled profiles use the same entry point and differ only in
their convergence postcondition. The result is reported as `recovered`,
`still-degraded`, `rejected`, `failed`, or `indeterminate` with verified
evidence, and everything except `recovered` exits nonzero.

Recovery is non-idempotent, so it is never retried automatically. The skill
stops after one attempt, never escalates to a Docker daemon, Docker Desktop, or
host restart, never touches workers, capacity, images, or configuration, and
processes multiple named profiles one at a time with a fresh preflight and
confirmation each time, stopping the batch after the first ambiguous or failed
result.

## Safety boundary

Every skill stops on ambiguous installation, profile, release, ingress, or
project identity. The skills never:

- display environment or secret files
- restart Docker Desktop, the Docker service, or the host
- stop or remove unrelated containers
- discard local Git changes
- edit PitCrew's generated capacity documents directly
