---
description: Diagnose PitCrew registration loops, queued jobs, image failures, routing mismatches, and Docker issues.
---

# Troubleshooting

## A runner repeatedly registers but never connects

Healthy startup ends with `Listening for Jobs`. When that marker never appears,
PitCrew applies an escalating jittered backoff instead of creating a CPU-heavy
respawn loop.

Common causes:

1. **Host clock skew:** Docker Desktop and WSL2 clocks can drift after sleep.
   Run `wsl --shutdown`, restart Docker Desktop, and compare the container clock
   with the host.
2. **Insufficient resources:** reduce the worker count so simultaneous runner
   startup does not starve the host.
3. **Invalid token scope:** verify repository Administration read/write access
   or the corresponding organization/enterprise permission.

## Jobs remain queued

Confirm the profile is online and every requested workflow label exists on the
runner:

```powershell
gh api repos/OWNER/REPOSITORY/actions/runners `
    --jq '.runners[] | {name, status, labels: [.labels[].name]}'
```

GitHub does not automatically fall back to a hosted runner when local capacity
is offline.

## A specialized profile receives routine jobs

Inspect the manifest and runner labels. Named profiles should keep
`disableDefaultLabels: true` and must not add `self-hosted`.

## Image preparation fails

PitCrew prepares and verifies the new image before replacing the live profile.
Resolve the Docker pull, build, architecture, checksum, or verification-command
failure and run setup again.

## Docker-dependent workflow steps fail

PitCrew workers intentionally do not receive a Docker socket. Route container
actions, service containers, Docker builds, and Testcontainers workloads to a
different runner.

## Stop a profile cleanly

Stop only the selected manager and its workers:

```powershell
.\Setup-Runner.ps1 -Profile copilot-cli -Down
```

Omit `-Profile` to stop the default pool.
