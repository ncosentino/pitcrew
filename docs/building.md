---
description: Validate PitCrew's PowerShell, shell, Docker Compose, profile contracts, and MkDocs site from source.
---

# Building from Source

PitCrew is composed of PowerShell, POSIX shell, Dockerfiles, JSON, and MkDocs
content. It does not produce a compiled package.

## Requirements

Install PowerShell 7, Docker with Compose, Python 3, and `pip`.

## Validate runner contracts

Run the hermetic profile and lifecycle contract suite:

```powershell
pwsh tests/Test-RunnerProfiles.ps1
```

The suite records Docker commands instead of contacting a daemon or GitHub.

## Validate shell and Compose

Check the manager script and Compose model:

```bash
sh -n manager/manage-runners.sh
docker compose --file docker-compose.yml config --quiet
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
