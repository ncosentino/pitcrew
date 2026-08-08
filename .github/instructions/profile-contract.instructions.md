---
applyTo: "Setup-Runner.ps1,RunnerProfiles.Functions.ps1,runner-profile.schema.json,profiles/**,docker-compose.yml,tests/Test-RunnerProfiles.ps1"
---

# Profile and Setup Contract

- Resolve and mutate exactly one selected profile. Preserve every unrelated profile,
  target, capacity value, label, scope, and operator-owned resource.
- Validate manifests, image inputs, external volumes, service networks, and
  verification commands before replacing a live manager.
- Keep credentials out of manifests, Docker build arguments, images, examples, and
  tracked environment files. Reuse stored registration credentials only through the
  supported setup path.
- Keep static profile identity separate from mutable desired capacity. Capacity-only
  updates must leave the manager and compatible workers untouched.
- Preserve active workers during compatible manager, image, resource, and capacity
  changes. Registration topology or routing changes require an explicit profile stop.
- Treat configured autoscaling counts as maximums. Zero active capacity is expressed
  through the established pause or minimum-idle contracts, not an invalid manifest
  replica default.
- Named profiles omit GitHub's broad default labels unless the operator explicitly
  opts in. The profile name remains a mandatory routing label.
- Advance schema, normalization, fingerprints, generated state, documentation, and
  hermetic contract tests together when the public profile contract changes.
- A manager contract version may advance only when fixed and autoscaled
  implementations plus observed-state validation support the same contract.

Use [Configuration](../../docs/configuration.md) and
[Contributor Architecture](../../docs/contributing/architecture.md) for rationale.
