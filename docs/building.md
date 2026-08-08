---
description: Validate PitCrew's PowerShell, shell, Docker Compose, profile contracts, and MkDocs site from source.
---

# Building from Source

PitCrew is composed of PowerShell, POSIX shell, a Go scale-set autoscaler,
Dockerfiles, JSON, and MkDocs content.

## Requirements

Install PowerShell 7, Go 1.25 or later, Docker with Compose, Python 3, and
`pip`.

## Discover validation

The CI workflows and executable repository surfaces own the complete command set.
Inventory them before selecting a local check:

```powershell
pwsh scripts/guidance/Get-ValidationInventory.ps1
```

Run the smallest command that covers the changed behavior. Complete Docker
integration remains owned by pull-request CI.

## Validate guidance

```powershell
pwsh tests/Test-Guidance.ps1
```

This checks root budgets, documentation and ADR reachability, scoped instructions,
review wiring, and matched-context limits.

## Validate PowerShell contracts

Run the hermetic profile and lifecycle contract suite:

```powershell
pwsh tests/Test-RunnerProfiles.ps1
```

Use the focused plugin and diagnostic suites when those surfaces change:

```powershell
pwsh tests/Test-CopilotPlugin.ps1
pwsh tests/Test-RemoteDiagnostics.ps1
pwsh tests/Test-PerformanceReport.ps1
```

The suite records Docker commands instead of contacting a daemon or GitHub.

## Validate shell and Compose

Check the manager script and Compose model:

```bash
sh -n manager/manage-runners.sh
sh -n manager/entrypoint.sh
docker compose --file docker-compose.yml config --quiet
```

Run the hermetic manager reconciliation contracts with:

```bash
sh tests/Test-ManagerReconciliation.sh
```

## Validate the autoscaler

```bash
go -C manager/autoscaler test ./...
go -C manager/autoscaler vet ./...
```

## Build the default asserted image

The root `Dockerfile` adds build-time assertions for the tools PitCrew expects
from the upstream runner image:

```bash
docker build --tag pitcrew-runner:local .
```

## Build the documentation

Install the pinned documentation dependency and run a strict build:

```bash
python -m pip install -r requirements-docs.txt
python -m mkdocs build --strict
```

The generated site is written to `site/`.

The exact required pull-request checks and draft/full validation behavior are
declared in `.github/genesis-delivery.json` and the workflows under
`.github/workflows/`.
