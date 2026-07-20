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

Autoscaling mode is static profile configuration. Enabling or disabling it
replaces the selected manager and its current workers, so make the transition
during an idle maintenance window.

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
- Every JIT worker still executes one job and is destroyed.

The configured maximum remains the operator's host resource ceiling. PitCrew
does not infer a new maximum from transient CPU or memory readings.

## Compatibility

Autoscaling uses the same multi-label workflow routing as fixed profiles. The
default profile includes `self-hosted`, `linux`, the current architecture, and
`general-purpose`. Isolated named profiles continue to omit `self-hosted` and
include their explicit profile and capability labels.

Worker images must contain:

```text
/actions-runner/bin/Runner.Listener
```

and a `runner` user. Built-in and default PitCrew images satisfy this contract.
Setup verifies it before replacing a live profile.

JIT mode launches `Runner.Listener` directly under Docker's init process rather
than running the image's normal registration entrypoint. Custom runtime setup
must therefore be baked into the image instead of depending on entrypoint side
effects.

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
