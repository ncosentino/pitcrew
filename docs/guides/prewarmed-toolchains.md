---
description: Route .NET 10 and Node.js 24 jobs to a prewarmed PitCrew profile instead of downloading toolchains for every job.
---

# Prewarmed Toolchains

The built-in `dotnet-node` profile ships one exact .NET 10 SDK and one exact
Node.js 24 release inside its worker image. Ephemeral workers therefore start
with the toolchain already present instead of downloading hundreds of megabytes
per job.

## What the image contains

- An immutable, multi-architecture runner base image referenced by digest.
- One pinned .NET 10 SDK, extracted to `/usr/share/dotnet` and exposed as
  `/usr/local/bin/dotnet`, with `DOTNET_ROOT` preset.
- One pinned Node.js 24 release, exposed as `/usr/local/bin/node` and
  `/usr/local/bin/npm`.
- The unchanged PowerShell and GitHub runner contract of the base image.

Every archive is version-pinned and checksum-verified during the build, and the
image contains no credentials, tokens, or private package feeds.

## Start the pool

```powershell
.\Setup-Runner.ps1 `
    -Profile dotnet-node `
    -Repos https://github.com/you/project=2
```

The profile is opt-in. Existing profiles, labels, and routing are unchanged
until a workflow explicitly requests the new capacity.

## Route jobs

```yaml
jobs:
  build:
    runs-on: [linux, x64, dotnet-node]
```

Request `dotnet-10` or `node-24` instead of the profile name when a workflow
only cares about one capability:

```yaml
jobs:
  test:
    runs-on: [linux, x64, dotnet-10]
```

Do not add `self-hosted`. That would let broad legacy jobs consume the
specialized capacity.

## Migrate from setup actions

Remove `actions/setup-dotnet` and `actions/setup-node` steps that request the
preinstalled versions. Those actions download a toolchain into the worker on
every job even when a matching one is already installed:

```yaml
jobs:
  build:
    runs-on: [linux, x64, dotnet-node]
    steps:
      - uses: actions/checkout@v6
      - run: dotnet build
      - run: npm ci
```

Keep the setup action when a job genuinely needs a different version than the
profile provides. Such a job downloads its own toolchain and gains nothing from
this profile.

Workflows that force `DOTNET_INSTALL_DIR` into `RUNNER_TEMP`, or that otherwise
redirect the SDK install location per job, bypass the prewarmed installation
entirely and keep downloading the SDK. Remove that override deliberately after
rolling out the profile; it is a workflow change, not something the image can
correct.

## Update the pinned versions

Bump `DOTNET_SDK_VERSION`, `NODE_VERSION`, their checksums, and the image tag in
`profiles/dotnet-node/profile.json`, then validate the new image before it
replaces live capacity:

```powershell
pwsh tests/Test-ProfileImage.ps1 -Profile dotnet-node
```

Re-run setup for the profile once verification passes. Changing the image is a
static configuration change, so it uses the full profile replacement path rather
than `-Refresh`.

## Roll back

```powershell
.\Setup-Runner.ps1 -Profile dotnet-node -Down
```

Stopping the profile affects no other pool. Workflows roll back by returning
their `runs-on` list to the pool they used before, restoring their previous
`actions/setup-dotnet` and `actions/setup-node` steps if those were removed.

## What this profile does not fix

Prewarming removes toolchain downloads only. It does not change Git checkout
behavior, host or Docker networking, CDN variability, or overlay write pressure,
and it does not introduce a writable cross-job cache. Slow jobs that remain slow
after adopting this profile need investigation elsewhere.
