---
description: Configure demand-driven PitCrew runner scale sets that shrink to an idle floor and return to a configured maximum.
---

# Demand-Driven Autoscaling

PitCrew can use GitHub's Runner Scale Set service to keep only the runners that
current workflow demand requires. This mode is opt-in; profiles without an
autoscaling policy retain fixed-capacity behavior.

Runner Scale Set support is a GitHub public-preview API. PitCrew pins the
versioned `github.com/actions/scaleset` client and keeps the integration behind
the profile mode so fixed pools do not depend on preview behavior.

## Enable autoscaling

Configured worker counts become maximum capacity:

```powershell
.\Setup-Runner.ps1 `
    -Profile copilot-cli `
    -Autoscale `
    -MinimumIdle 0 `
    -ScaleDownDelaySeconds 120 `
    -Repos https://github.com/you/agentic-project=30
```

This profile may run from zero through thirty workers. GitHub's outbound
long-poll demand stream wakes the pool when matching jobs are assigned.

Autoscaling mode changes registration topology. Enabling or disabling it
requires an explicit profile stop after confirming no jobs are active. Tuning
minimum idle or scale-down delay within scale-set mode uses manager handoff and
does not interrupt active workers.

For a manifest, add:

```json
{
  "autoscaling": {
    "mode": "scale-set",
    "minimumIdle": 0,
    "scaleDownDelaySeconds": 120
  }
}
```

## Scaling behavior

- Repository scope creates one isolated runner scale set per repository target.
- Organization and enterprise scope create one scale set for the shared pool.
- Existing profile labels and runner-group routing remain in effect.
- Configured counts are hard maximums, not always-running container counts.
- `minimumIdle` keeps an optional warm baseline. Zero minimizes idle memory;
  a positive value trades memory for lower first-job latency.
- Scale-up follows GitHub's authoritative assigned-job count immediately.
- Scale-down waits for demand to remain below active capacity for the configured
  delay. Rising demand cancels the pending scale-down.
- Busy runners are never selected for idle removal. PitCrew removes the GitHub
  runner registration before stopping an idle container.
- Worker image revisions roll in place: idle stale runners are fenced and
  replaced immediately, while assigned stale runners finish their one job.
- Every JIT worker still executes one job and is destroyed.

The configured maximum remains the operator's host resource ceiling. PitCrew
does not infer a new maximum from transient CPU or memory readings.

## Profile-wide worker ceiling

Contract-11 profiles may also declare `autoscaling.maximumActiveWorkers`, an
aggregate ceiling across every target in the profile. Each target keeps its own
configured maximum, and admission is reserved centrally before a JIT runner is
generated, so simultaneous scale-up across targets cannot overshoot the ceiling.
Locally live, starting, recovered, draining, and cleanup-pending workers all
consume the ceiling.

- Each target is guaranteed a rotating fair share of the ceiling, so no target
  starves under sustained contention.
- Capacity a target does not need is released to targets that do, so an idle
  target never strands the ceiling.
- The ceiling only withholds admission. It never removes an existing worker, so
  busy or assigned runners are never destroyed to satisfy a lower ceiling.
- Scale-up within the ceiling remains immediate, and scale-down keeps the
  configured delay.

Declared worker limits (`resources.memory`, `resources.memorySwap`,
`resources.cpus`, and `resources.pids`) are applied to every new worker as
canonical Docker arguments. Invalid limits are rejected before any container
starts. Unset values mean no configured limit and are never treated as zero.

Resource policy and the aggregate ceiling were introduced in manager contract
11 and remain supported by the active contract 14 autoscaler.

## Operation evidence

Autoscaled profiles publish additional, credential-free diagnostics in the
observed state so operators can tell an idle pool apart from a stuck one:

- `operationJournal` is a bounded, durable record of failures, timeouts,
  retries, recoveries, and meaningful transitions. Successful routine polls and
  reconciliation ticks are not recorded. Events carry a stable sequence and
  observer identity so connectors can deduplicate them, and the journal survives
  a manager restart, so a Docker or listener failure that preceded recovery is
  still visible.
- `subsystemHealth` summarizes Docker and GitHub operations as `healthy`,
  `degraded`, `unavailable`, or `unknown`, with the last success, last failure,
  and consecutive failure count. A subsystem that has not been observed stays
  `unknown` rather than reporting a fabricated success.
- `capacityEvidence` reports per-target deficits against the target's current
  activation target, never the configured maximum, so a healthy pool below its
  ceiling is never presented as an unmet health target. Local Docker worker
  counts and timestamped GitHub registered, busy, and idle counts stay separate
  sources, so `2 local / 8 registered` is reported as stale GitHub registrations
  rather than eight local workers.

When a target cannot reach its activation target, the manager publishes the
actual blocking reason: the profile-wide admission ceiling, an unavailable
listener or scale-set session, pending or failed JIT configuration, a Docker
launch failure, pending registration cleanup, draining, retry backoff, or
`unknown`.

Diagnostics never retain access tokens, JIT payloads, HTTP bodies, raw API or
Docker error output, job output, or environment values; evidence is reduced to a
short, sanitized summary. Diagnostics are best-effort: a corrupt or unwritable
journal is reported through the journal status and never stops scaling, removes
workers, or discards retirement, cleanup, or accepted capacity state.

## Compatibility

Autoscaling uses the same multi-label workflow routing as fixed profiles. The
default profile includes `self-hosted`, `linux`, the current architecture, and
`general-purpose`. Isolated named profiles continue to omit `self-hosted` and
include their explicit profile and capability labels.

Worker images must contain:

```text
/actions-runner/bin/Runner.Listener
```

PitCrew preserves the image's declared Docker user. The default image declares a
root-capable workflow contract, matching fixed-capacity workers and allowing
standard setup actions to install SDKs in system locations. A custom image may
declare a non-root `USER`, but that user must be able to execute the listener
and satisfy every workflow capability advertised by the profile labels. Setup
verifies the listener before replacing a live profile.

JIT mode launches `Runner.Listener` directly under Docker's init process rather
than running the image's normal registration entrypoint. Custom runtime setup
must therefore be baked into the image instead of depending on entrypoint side
effects. PitCrew sets `RUNNER_ALLOW_RUNASROOT=1` for compatibility with images
whose declared user is root; it does not force a root or non-root user.

## Capacity changes

Reapply setup with `-CapacityOnly` to change a configured maximum without
restarting the autoscaling manager:

```powershell
.\Setup-Runner.ps1 `
    -Profile copilot-cli `
    -Autoscale `
    -CapacityOnly `
    -AddRepos https://github.com/you/agentic-project=40
```

The acknowledgement confirms that the new maximum was accepted; it does not
start forty workers without matching demand.

## Security

The manager retains the administration credential. JIT workers receive only
their one-time encoded configuration and never receive `ACCESS_TOKEN`. Only the
manager mounts the Docker socket.
