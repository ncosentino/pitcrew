# Canonical PitCrew Profile Status

Use this contract before concluding that a PitCrew profile is missing,
unconfigured, or unavailable.

## Configuration is not runner presence

GitHub's current runner list, local worker containers, active slots, and target
slots describe runtime capacity. None is configuration authority.

Configuration states are closed:

- `configured`: authoritative PitCrew state contains the exact profile;
- `not-configured`: complete current authoritative inventory omits it; and
- `unknown`: inventory is partial, unavailable, stale, filtered, or otherwise
  unable to prove absence.

Positive profile evidence proves `configured` even when runtime evidence is
stale or degraded. Absence proves `not-configured` only from exhaustive
inventory. Never turn a scoped or failed lookup into absence.

## Runtime states

Configured profiles use one closed runtime state:

- `idle-scale-to-zero`
- `active`
- `idle`
- `scaling-up`
- `scaling-down`
- `paused`
- `manager-stopped`
- `degraded`
- `stale`

A healthy autoscaled profile is `idle-scale-to-zero` when:

- its configured maximum is positive;
- minimum idle is zero;
- target slots are zero;
- active slots are zero;
- manager and autoscaling evidence are current and not degraded; and
- no explicit Dashboard pause is acknowledged.

Report it exactly as:

```text
CONFIGURED · AUTOSCALED · IDLE (SCALE-TO-ZERO)
```

An acknowledged zero-capacity pause is `paused`, not scale-to-zero. A zero
configured maximum without that acknowledgement is degraded.

## Evidence sources

Dashboard mode uses:

```text
GET /api/diagnostics/v1/tenants/{tenantId}/fleet/nodes/{nodeId}/profiles/{profileId}/status
```

Dashboard owns inventory authority, manager freshness, and pause projection.
Use Dashboard `v0.12.44` or newer for this endpoint.

Local mode enumerates every directory immediately below
`.pitcrew-state`. Successful complete enumeration can prove local absence.
An existing exact profile directory proves configuration. Runtime comes from
non-secret `observed-state.json` plus the exact running manager label when
Docker evidence is available. Local manager evidence older than 120 seconds is
stale.

Use the shared
`plugins/pitcrew-operations/scripts/ProfileStatus.Projection.ps1` projection
instead of recreating these rules in another skill.

## Skill integration

Before a skill reports "not configured," "no runner configured," or an
equivalent conclusion:

1. obtain the canonical profile status;
2. report configuration and runtime separately;
3. preserve unavailable values as null rather than zero; and
4. treat zero workers as healthy when the state is
   `idle-scale-to-zero`.
