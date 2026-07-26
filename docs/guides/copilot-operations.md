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
labels. It also collects `docker system df`, the Docker network count, host free
space and inodes where supported, and read-only network-adapter error and drop
counters, selecting Linux or Windows commands from the runner host platform.

Caller-approved URLs are timed from the host and from exactly one disposable
container built from the profile's exact worker image. Downloaded bodies are
discarded, and only that exact diagnostic container is removed afterwards. A
dry-run mode prints the resolved commands without changing state, and the
redacted Markdown/JSON handoff separates verified measurements from unavailable
evidence and unverified hypotheses.

## Safety boundary

Every skill stops on ambiguous installation, profile, release, ingress, or
project identity. The skills never:

- display environment or secret files
- restart Docker Desktop, the Docker service, or the host
- stop or remove unrelated containers
- discard local Git changes
- edit PitCrew's generated capacity documents directly
