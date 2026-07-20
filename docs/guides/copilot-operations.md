---
description: Install PitCrew's Copilot CLI plugin and use its skills for capacity and version updates.
---

# Copilot CLI Operations

PitCrew publishes an installable Copilot CLI marketplace plugin that teaches
Copilot the repository's supported operational procedures. The plugin does not
add a remote control plane or replace `Setup-Runner.ps1`; it makes Copilot use
the existing scripts and scoped Compose commands consistently.

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
`Setup-Runner.ps1`. It reads only non-secret generated state, preserves the
selected profile, requires `-CapacityOnly`, and verifies the manager's capacity
acknowledgement.

Example prompts:

```text
Use the pitcrew-capacity skill to set the copilot-cli profile to four workers
for https://github.com/example/project.
```

```text
Use the pitcrew-capacity skill to remove
https://github.com/example/retired-project from the default pool.
```

Capacity updates must leave the existing manager container untouched. The skill
does not use `-Down`, directly edit desired state, or attempt scale-to-zero.

## Pool update skill

`pitcrew-pool-update` updates a deployment checkout to a published PitCrew
release and invokes `Setup-Runner.ps1 -Refresh` for each configured profile.

```text
Use the pitcrew-pool-update skill to update this host to the latest published
PitCrew release.
```

The skill refuses to substitute `main` when no release exists. A profile
refresh rebuilds and replaces that profile, so the skill checks GitHub runner
state and stops when matching workers are busy. Hosts with continuous workflow
traffic require an operator-arranged maintenance window.

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

## Safety boundary

Every skill stops on ambiguous installation, profile, release, ingress, or
project identity. The skills never:

- display environment or secret files
- restart Docker Desktop, the Docker service, or the host
- stop or remove unrelated containers
- discard local Git changes
- edit PitCrew's generated capacity documents directly
