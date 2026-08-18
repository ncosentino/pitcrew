---
description: Understand PitCrew's contributor-facing architecture, source boundaries, and executable contracts.
---

# Contributor Architecture

PitCrew is a profile-driven control plane for isolated, ephemeral GitHub Actions
runners. PowerShell prepares and reconciles profile configuration, one manager
container owns Docker access for that profile, and disposable worker containers
execute one job each.

## Control-plane boundaries

`Setup-Runner.ps1` is the operator entry point. It resolves one profile, prepares
and verifies images, publishes static and mutable state, and performs compatible
manager handoff. `RunnerProfiles.Functions.ps1` owns manifest resolution,
normalization, fingerprints, generated environment values, and rolling
compatibility. `runner-profile.schema.json` is the public manifest contract.

`docker-compose.yml` defines the profile manager. Only that manager mounts the
host Docker socket and host pressure source. Workers are sibling containers
launched by the manager and receive neither mount.

The manager has two implementations:

- `manager/manage-runners.sh` owns fixed-capacity reconciliation.
- `manager/autoscaler/` owns opt-in GitHub Runner Scale Set demand handling.

Both implementations consume the same generated state and publish the same
credential-free observed-state contract. `manager/reconciliation.sh` provides
shared desired-capacity validation and stable slot-key derivation.

Built-in worker profiles live under `profiles/`. External manifests remain
operator-owned and are validated against the public schema before they can affect
a live profile.

## Lifecycle invariants

Every worker accepts one job and is destroyed with `--rm`. Fixed profiles replace
workers to maintain desired capacity. Autoscaled profiles use GitHub's assigned-job
signal to choose activation between their idle floor and configured maximum.

Profile identity is exact. Compose projects, state directories, labels, worker
revisions, and cleanup selectors are isolated by profile. Cleanup and adoption use
exact labels or exact container IDs rather than container-name matching.

Compatible capacity, manager, image, and resource-policy updates preserve active
workers. Removed capacity drains after the current worker exits. Registration
topology and routing changes require an explicit profile stop rather than an
implicit destructive replacement.

See:

- [Configuration](../configuration.md) for public contracts and generated state.
- [Rolling Updates](../guides/rolling-updates.md) for manager handoff and worker
  convergence.
- [Demand-Driven Autoscaling](../guides/autoscaling.md) for scale-set behavior.
- [Security Boundaries](../guides/security-boundaries.md) for Docker, credential,
  and workflow trust boundaries.

## Observability boundary

Managers collect lifecycle, registration, resource, operation, capacity, hardware,
and bounded job-context evidence. Unsupported or stale measurements remain explicit;
they are not inferred from resource activity or converted to zero.

The projection contains no registration token, JIT configuration, environment
values, raw runner identity, job output, or host-private identifiers. Connectors and
dashboards are read-only consumers and never receive the Docker socket.

`observed-state.schema.json`, the two manager implementations, and their contract
tests must advance together.

## Support-plane boundary

Support-plane v1 is additive to the manager and normal connector. A dedicated
node transport polls outward through an opaque relay, while a separate
networkless broker reads only the fixed diagnostic files through
`Collect-PitCrewDiagnostics.ps1 -FileOnly`.

PitCrew owns the collector, report/import contract, operations skill, and
support guidance. PitCrew Dashboard owns protocol canonicalization,
authorization and identity, relay, agent and broker applications, persistence,
API, UX, installers, and node packages. The trust and mixed-version rules are
recorded in
[ADR-0007](../adr/adr-0007-outbound-read-only-support-plane.md).
The versioned broker read and dedicated-directory inheritance contract is
documented in
[Support Broker Access](../guides/support-broker-access.md).

## Operations plugin

`plugins/pitcrew-operations/` is a published product surface, not contributor
guidance. Its skills describe bounded operator procedures for capacity, rollout,
updates, diagnostics, performance correlation, and manager recovery. Shared safety
contracts live under the plugin's `references/` directory.

Plugin manifest, marketplace metadata, documentation, scripts, and tests must remain
consistent because users install the repository as a Copilot CLI marketplace.

## Executable contracts

The complete validation and delivery definitions live in:

- `.github/workflows/ci.yml`
- `.github/workflows/docs.yml`
- `.github/genesis-delivery.json`
- `tests/`
- `manager/autoscaler/go.mod`
- `docker-compose.yml`
- `mkdocs.yml`

Use [Building from Source](../building.md) for local entry points. Hosted Docker
integration and complete pull-request evidence remain owned by the configured CI
workflows.
