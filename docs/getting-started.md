---
description: Install PitCrew, start an ephemeral GitHub Actions runner profile, and route a workflow to it.
---

# Getting Started

This guide starts a general-purpose repository runner pool and routes a GitHub
Actions job to it.

## Install the prerequisites

Install PowerShell 7 and Docker with Linux-container support on a dedicated
machine. Confirm Docker can start a container:

```powershell
docker run --rm hello-world
```

## Authenticate to GitHub

Authenticate the GitHub CLI with an account that can administer Actions runners
for the target repository:

```powershell
gh auth login
```

PitCrew can also accept a fine-grained personal access token through `-Token`.
The token must have repository Administration read/write access, or the
corresponding organization or enterprise runner-administration permission.

## Clone PitCrew

Clone the repository onto the worker host and enter the repository directory:

```powershell
git clone https://github.com/ncosentino/pitcrew.git
Set-Location pitcrew
```

## Start the first profile

Provision two general-purpose workers for a repository:

```powershell
.\Setup-Runner.ps1 `
    -Repos https://github.com/you/project=2
```

PitCrew builds or pulls the required image, verifies the profile contract,
writes gitignored local state, replaces only the selected profile, and starts
its manager.

## Route a workflow

Require the default profile's explicit labels in the workflow:

```yaml
jobs:
  build:
    runs-on: [self-hosted, linux, x64, general-purpose]
    steps:
      - uses: actions/checkout@v6
      - run: echo "Running on a fresh PitCrew worker"
```

Each worker accepts one job, exits, and is replaced with a clean container.

## Next steps

- Configure [named profiles](guides/named-profiles.md) for specialized tools.
- Review every [setup option](configuration.md).
- Apply the [security boundaries](guides/security-boundaries.md).
- Use [routing guidance](guides/routing-workloads.md) across multiple pools.
