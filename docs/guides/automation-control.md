---
description: Run repository policy and orchestration jobs on a minimal, non-root, scale-set-only PitCrew worker image.
---

# Automation Control Runners

The built-in `automation-control` profile is an opt-in capability lane for short
GitHub API and repository metadata operations. It is not a general-purpose build
image.

## Supported workload

The image includes:

- the pinned GitHub Actions runner and the glibc Node 20 and Node 24
  executables required by JavaScript actions;
- Bash, POSIX shell, coreutils, curl, and CA certificates;
- checksum-pinned Git, GitHub CLI, `jq`, and PowerShell 7;
- a non-root runner account with writable home and Actions work directories.

Git is built without Perl, Python, Tcl/Tk, gettext, or DAV support. HTTPS clone,
push, sparse checkout, ref validation, and branch cleanup remain supported.

The image intentionally omits:

- Docker CLI, Buildx, and Docker socket access;
- Kubernetes hooks, `kubectl`, and Helm;
- Alpine Node runtimes, npm, Node headers, and bundled package-manager payloads;
- Python, pip, Perl, GPG repository tooling, and build SDKs;
- `sudo` and privileged runtime package installation.

Jobs that build, test, publish artifacts, install SDKs, run containers, or use
service containers belong on a capability-specific profile.

## Why it is scale-set-only

The official runner archive exposes
`/actions-runner/bin/Runner.Listener`, which PitCrew's scale-set manager starts
with a one-time JIT configuration. It does not provide the registration
entrypoint used by PitCrew's fixed general-purpose image.

The profile therefore declares `autoscaling.mode` as `scale-set`. Do not disable
autoscaling for this image or reuse it under a fixed profile.

## Build and start

The manifest pins every downloaded archive by SHA-256 and pins the minimal
runtime base by OCI digest. PitCrew builds and verifies the image before manager
handoff:

```powershell
.\Setup-Runner.ps1 `
    -Profile automation-control `
    -Repos https://github.com/example/project=1
```

The profile name is its only routing label:

```yaml
jobs:
  policy:
    runs-on: [automation-control]
```

The built-in default is one profile-wide active worker with scale-to-zero.
Override the maximum only after reviewing host admission and repository demand.

## Qualification and rollout

CI enforces an 850 MiB unpacked image budget and exercises the runner listener,
both retained Node runtimes, Git sparse checkout and push, GitHub CLI command
surfaces, `jq`, PowerShell, non-root writes, and omitted-tool boundaries.

Before moving an existing control lane:

1. canary the profile against representative REST, GraphQL, checkout, Git, and
   PowerShell guidance jobs;
2. verify no routed job expects an omitted tool or runtime installation;
3. preserve the existing general-purpose image as the profile-level rollback;
4. roll the image through the normal profile update path so assigned workers
   finish before replacement.

Missing capability is a routing error, not a reason to add broad tooling back to
this image.
