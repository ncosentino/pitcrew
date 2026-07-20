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

For an autoscaled profile, inspect its demand state:

```powershell
Get-Content .pitcrew-state\PROFILE\observed-state.json |
    ConvertFrom-Json |
    Select-Object -ExpandProperty autoscaling
```

`maximumSlots` is the configured ceiling, `targetSlots` is current GitHub
demand plus the warm idle floor, and `activeSlots` is the live container count.
A `degraded` status or non-empty `lastError` identifies scale-set, JIT
configuration, or Docker provisioning failures.

## A specialized profile receives routine jobs

Inspect the manifest and runner labels. Named profiles should keep
`disableDefaultLabels: true` and must not add `self-hosted`.

## Image preparation fails

PitCrew prepares and verifies the new image before replacing the live profile.
Resolve the Docker pull, build, architecture, checksum, or verification-command
failure and run setup again.

## A capacity update is not acknowledged

Setup waits for the selected manager to acknowledge the new desired-capacity
generation. Inspect profile logs and the generated state directory:

```powershell
docker compose --project-name self-hosted-runner logs runner-manager
Get-Content .pitcrew-state\default\desired-capacity.json
Get-Content .pitcrew-state\default\acknowledged-capacity.json
Get-Content .pitcrew-state\default\observed-state.json
```

Malformed or lower-generation desired state is rejected without changing the
last valid pool. Correct the setup input and reapply the complete command.
Missing or older acknowledgements are repaired by the manager; setup publishes
a higher recovery generation when necessary.

## Scale-down still shows the removed runner

Removed slots drain gracefully. A runner already executing a job finishes
normally, and an idle ephemeral runner may accept one final job before its
container exits. The slot disappears after that container exits and is not
respawned.

Autoscaled profiles intentionally retain excess idle JIT runners until
`scaleDownDelaySeconds` elapses. Any renewed demand cancels that pending
scale-down.

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

PitCrew gives compatible worker images time to deregister before exact-label
force removal. If a custom image leaves offline registrations behind, verify
that its entry point handles `SIGTERM`, retains a private removal credential,
and does not export that credential to the runner process.
