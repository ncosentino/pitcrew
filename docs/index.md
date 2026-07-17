---
description: Run isolated, ephemeral GitHub Actions worker pools with profile-specific images, labels, and capacity.
---

# PitCrew

<p align="center">
  <img src="assets/pitcrew-logo.png" alt="PitCrew logo" width="300" height="300">
</p>

PitCrew orchestrates containerized GitHub Actions runners that are destroyed
after one job and immediately replaced. It is designed for teams and individual
developers who want self-hosted capacity without carrying workspace state or
partially installed tools between jobs.

## Installation

Clone the public repository onto a dedicated Docker host:

```powershell
git clone https://github.com/ncosentino/pitcrew.git
Set-Location pitcrew
```

PitCrew requires PowerShell 7 and Docker with Linux-container support.

## Quick example

Start two general-purpose workers for one repository:

```powershell
.\Setup-Runner.ps1 `
    -Repos https://github.com/you/project=2
```

Route a workflow job to that pool:

```yaml
jobs:
  build:
    runs-on: [self-hosted, linux, x64, general-purpose]
```

## Why it exists

Long-lived self-hosted workers accumulate state: interrupted package installs,
modified global tools, cached credentials, and stale workspaces can affect later
jobs. PitCrew keeps lightweight manager containers alive while replacing the
actual workers after every job.

Named profiles also let one host provide separate capacity for routine builds
and specialized workloads without allowing broad `self-hosted` jobs to consume
the specialized pool.

## About

PitCrew is built by [Nick Cosentino](https://www.devleader.ca). Follow
[Dev Leader](https://www.devleader.ca) for software engineering articles and
videos, and [BrandGhost](https://www.brandghost.ai) for social-first updates.
