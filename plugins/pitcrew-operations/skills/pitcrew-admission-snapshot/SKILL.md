---
name: pitcrew-admission-snapshot
description: Capture one noninteractive, read-only, point-in-time PitCrew host-admission capacity snapshot for trusted CI planning.
license: MIT
---

# PitCrew Admission Snapshot

Capture one exact node/profile admission observation with the supported script
in this skill.

Read [operations safety](../../references/safety.md) before running commands.

## Required inputs

Collect all of these from the caller:

- one PitCrew Dashboard base URL;
- one tenant identifier;
- one exact Dashboard node ID;
- one exact PitCrew profile ID;
- one positive requested worker count; and
- one explicit JSON output path.

Require the raw diagnostic credential in the process environment variable
`PITCREW_DIAGNOSTICS_CREDENTIAL`. Never ask the caller to place it in a URL,
script argument, repository file, report, command history, or log.

## Supported command

Resolve this skill's `scripts` directory and invoke:

```powershell
pwsh ./scripts/New-PitCrewAdmissionSnapshot.ps1 `
    -DashboardUrl https://dashboard.example `
    -TenantId example `
    -NodeId 00000000-0000-0000-0000-000000000001 `
    -Profile project-ci `
    -RequestedWorkers 4 `
    -OutputPath ./pitcrew-admission-snapshot.json
```

Before execution, print only the Dashboard origin, tenant, exact node/profile,
requested worker count, resolved output path, and whether the credential
environment variable is present. Never print its value.

The command reads only the paginated current-fleet diagnostic endpoint. It
does not query history, GitHub, logs, artifacts, environments, runner
registration material, Docker, or the host.

## Interpretation

The command consumes Dashboard's claim-level `host-admission` evidence and the
manager's contract-19-or-newer profile accounting. It does not reconstruct
capacity from raw host availability, configured profile limits, CPU, memory,
or a downstream saturation threshold.

Only evidence that Dashboard classifies as current, complete, and live can
produce:

- `admissible-now` when requested workers do not exceed current allocatable
  workers; or
- `insufficient-now` when requested workers exceed current allocatable
  workers.

Stale, partial, unavailable, last-known, unsupported, missing, malformed, and
incomplete evidence produces `unknown`. A measured zero remains zero.
`available`, `degraded`, `unavailable`, and `disabled` admission states remain
distinct.

Read [the machine-readable JSON contract](references/json-contract.md) and its
executable schema before building downstream automation.

## Non-negotiable boundaries

- This is a point-in-time observation, not a reservation or promise.
- Fair-share rotation, intervening leases, and new demand may change the next
  coordinator decision.
- Never reserve, acquire, renew, activate, release, or reconcile admission.
- Never route, dispatch, cancel, or mutate a GitHub Actions workflow or job.
- Never mutate a runner, manager, connector, Docker object, or host.
- Never include credentials, node display names, manager or connector
  identities, repositories, runner names, slots, container identifiers, host
  paths, image references, logs, or job output in the snapshot.
- Never interpret admission units as CPU, memory, priority, universal worker
  weights, queue wait, or completion-time forecasts.

Return the full absolute path to the written JSON file plus its disposition and
reason.
