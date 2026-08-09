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

For a contract-18 profile, inspect host admission and per-target capacity
evidence separately:

```powershell
$state = Get-Content .pitcrew-state\PROFILE\observed-state.json |
    ConvertFrom-Json
$state.hostAdmission | ConvertTo-Json -Depth 8
$state.capacityEvidence | ConvertTo-Json -Depth 8
```

`host-admission-withheld`, `host-admission-degraded`, and
`host-admission-unavailable` describe the host start gate. They are not GitHub
queue, profile `admission-ceiling`, Docker, JIT, listener, or cleanup failures.
See [Host-Local Admission Operations](guides/host-admission.md) for the complete
field contract and supported policy lifecycle.

## Host-admission demand is withheld

When `status` is `available`, positive `pendingUnits` and `withheldUnits` plus
`host-admission-withheld` prove that current worker demand reached the host
gate and was not admitted.

- `availableUnits < unitCost` means aggregate free budget cannot fit one whole
  worker for this profile.
- With enough aggregate units visible, an unused non-borrowable reservation or
  rotating shared-pool fairness may still protect another contender.

The published accounting is profile-scoped, so it does not identify another
profile's exact lease. Wait for capacity to release, reduce demand, or apply a
reviewed policy update. Never convert abstract units into CPU or memory without
separate measurement.

## Host-admission coordination stays degraded

After a coordinator restart or policy replacement, `pendingUnits` and
`withheldUnits` remain `null` until the manager republishes demand. Null is
unavailable evidence, not zero.

Take a second fresh sample. If `degraded` persists, compare namespace and policy
fingerprints with the reviewed manifests, verify the profile is present in the
coordinator policy, and confirm observed state is current. Reapply the complete
profile command through `Setup-Runner.ps1`; do not edit generated fingerprints
or coordinator state.

## Host-admission budget is exhausted

Positive withheld units, fewer available units than one worker cost, and a
bounded `lastDecision.failureCategory` of `budget-exceeded` identify a denied
lease attempt. Running workers are never removed to make room. Allow a lease to
release or perform a reviewed policy change; a higher GitHub queue depth does
not override the budget.

## A host-admission policy is rejected

Setup rejects invalid arithmetic, inconsistent capacity or safety margin across
participating profiles, live namespace replacement, and policy removal while a
profile still owns leases. Correct the external manifest and replay its complete
setup command. Do not start containers manually or change generated state.

For a host-wide capacity or safety-margin change, pause and drain all
participants, remove all but one, update the remaining profile, then re-enroll
the others with matching values. A full remove-and-reapply sequence is simpler
but creates a complete outage. A namespace change requires that full sequence;
the final `-Down` removes the empty coordinator.

## The host-admission coordinator is unavailable

`hostAdmission.status: unavailable` and
`host-admission-unavailable` mean configured identity is known but current
coordinator measurements are not. Measured fields are `null`. Existing workers
survive; only new admission stops.

Collect read-only diagnostics first. Then replay one participating profile's
complete current setup command with `-Refresh` so setup restores the
coordinator from durable state before handing off that manager. `-RecoverManager`
does not repair the coordinator. If durable state is unreadable, preserve it
for diagnosis and stop; never delete or rewrite it to force admission.

## Rollback is blocked by host-admission leases

Pause the selected profile and wait for `activeUnits`, `provisionalUnits`, and
`heldUnits` to reach zero before `-Down`. If setup still reports retained
leases, reapply the current reviewed profile with `-Refresh` so the replacement
manager can perform exact lease reconciliation, then pause and retry.

Never remove coordinator state before leases reconcile. For a full rollback,
pause and drain every participant, run `-Down` for every participant, and only
then reapply manifests without `hostAdmission`.

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

## A manager is degraded while its workers keep running

When a profile's manager reports repeated Docker or listener failures, restart
only that manager. Manager contract 9 and newer treat an ordinary termination
signal without an explicit shutdown request as a handoff, so labelled workers
stay alive and the replacement manager adopts them.

Read the current fences first, then pass them back so a stale command cannot
restart a manager that already changed:

```powershell
Get-Content .pitcrew-state\copilot-cli\observed-state.json
.\Setup-Runner.ps1 -Profile copilot-cli -RecoverManager -ExpectedManagerInstanceId <managerInstanceId> -ExpectedGeneration <generation> -ExpectedDesiredStateHash <desiredStateHash>
```

The operation takes the profile operation lock, requires exactly one running
manager on contract 9 or newer, refuses while a shutdown request is pending, and
issues exactly one restart against the exact container ID with the established
60-second graceful stop window. It never changes capacity or configuration,
never touches a worker, never runs Compose or cleanup, and never needs the
stored registration token.

It reports `recovered`, `still-degraded`, `rejected`, `failed`, or
`indeterminate`, and exits nonzero for everything except `recovered`. Recovery is
never retried automatically: re-read observed state and reassess before any
second attempt. A profile with no running manager is intentionally stopped or
separately broken, and recovery will not start it.

An adopted worker keeps reporting `starting` for the rest of its life. A
worker's own log output only reports that its process is listening, and output
produced before the handoff is replayable, so the replacement manager never
treats it as evidence about a runner it did not launch. Use `registrationStatus`
and `eligibleSlots` for GitHub-authoritative capacity; those stay `unknown` and
`0` whenever the manager cannot reach GitHub.

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
