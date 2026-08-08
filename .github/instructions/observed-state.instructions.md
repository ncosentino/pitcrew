---
applyTo: "observed-state.schema.json,manager/{observability,diagnostics,registration,reconciliation}.sh,manager/autoscaler/**/*.go,tests/Test-RunnerProfiles.ps1,tests/Test-ManagerReconciliation.sh"
---

# Observed-State Contract

- Keep the schema, fixed manager, autoscaler, and contract tests aligned for every
  manager contract version.
- Distinguish measured zero from unavailable, partial, stale, or unknown evidence.
  Do not coerce missing values to zero or retain stale values as current.
- Keep local Docker counts, GitHub registration or scale-set counts, and desired
  targets as separate evidence sources.
- Resource activity is diagnostic evidence, not proof that a worker is busy and not a
  source of job identity.
- Publish only bounded operational metadata. Exclude credentials, environment values,
  JIT configuration, registration payloads, raw runner names, container identity,
  absolute host paths, network addresses, job logs, step output, and raw external
  errors.
- Sanitize journal evidence before persistence and keep every retained collection
  bounded in item count and serialized size.
- Contract changes are additive unless a separately versioned migration explicitly
  says otherwise. Older readers must be able to ignore new fields safely.
- A diagnostic write failure must not stop scaling, remove a worker, or discard valid
  desired, accepted, retirement, or cleanup state.
- Update the schema, both producers, documentation, and deterministic tests in the
  same change.

See [Configuration](../../docs/configuration.md) and
[Security Boundaries](../../docs/guides/security-boundaries.md).
