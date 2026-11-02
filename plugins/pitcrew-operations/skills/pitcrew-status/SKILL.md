---
name: pitcrew-status
description: Determine whether one PitCrew profile is configured and classify its current fixed or autoscaled runtime without treating zero runners as missing configuration.
license: MIT
---

# PitCrew Status

Return one canonical, read-only configuration and runtime classification for
an exact PitCrew profile.

Read these shared references before running commands:

- [operations safety](../../references/safety.md)
- [profile status](../../references/profile-status.md)

## Source selection

Use Dashboard mode when the caller supplies a Dashboard origin, tenant, exact
node ID, and a diagnostic credential through
`PITCREW_DIAGNOSTICS_CREDENTIAL`. Dashboard `v0.12.44` or newer returns the
canonical exact profile projection:

```powershell
pwsh ./scripts/Get-PitCrewProfileStatus.ps1 `
    -DashboardUrl https://dashboard.example `
    -TenantId example `
    -NodeId 00000000-0000-0000-0000-000000000001 `
    -Profile project-ci `
    -PassThru
```

Use local mode when operating on a PitCrew checkout:

```powershell
pwsh ./scripts/Get-PitCrewProfileStatus.ps1 `
    -PitCrewRoot <pitcrew-root> `
    -Profile project-ci `
    -PassThru
```

Resolve the PitCrew root and profile through the profile-replay rules when the
caller did not provide an exact local profile. Never read an environment or
token file.

## Interpretation

Always report `configurationState` separately from `runtimeState`.

- `configured` means authoritative PitCrew state contains the profile.
- `not-configured` is valid only when complete current inventory
  authoritatively omits the profile.
- `unknown` means inventory is unavailable, partial, stale, filtered, or
  otherwise unable to prove absence.

Runtime states are closed:

- `idle-scale-to-zero`
- `active`
- `idle`
- `scaling-up`
- `scaling-down`
- `paused`
- `manager-stopped`
- `degraded`
- `stale`

The healthy scale-to-zero banner is:

```text
CONFIGURED · AUTOSCALED · IDLE (SCALE-TO-ZERO)
```

Zero current GitHub runners, zero local workers, zero target slots, and zero
active slots do not mean the profile is missing. GitHub's runner list is
runtime evidence, never configuration authority.

## Boundaries

- Read only generated PitCrew state or the exact Dashboard diagnostic status
  endpoint.
- Never query GitHub to decide whether a profile is configured.
- Never start, stop, recover, resize, pause, or update a profile.
- Never display the diagnostic credential or any environment-file content.
- Stop on duplicate local profile or manager identity.
- Preserve null as unavailable and zero as measured zero.

Return the summary banner, configuration state, runtime state, reason code,
configured maximum, target slots, active slots, and the selected evidence
source.
