---
applyTo: "plugins/pitcrew-operations/**,.github/plugin/marketplace.json,tests/Test-{CopilotPlugin,RemoteDiagnostics,PerformanceReport}.ps1,scripts/release/**"
---

# Operations Plugin

- Treat the marketplace, plugin manifest, skills, references, scripts,
  documentation, tests, and release assets as one published product surface.
- Keep marketplace metadata and plugin versions synchronized. Advance versions only
  with the corresponding behavior and contract coverage.
- Skills must use supported PitCrew entry points and exact identities. Do not
  recreate setup, recovery, rollout, or cleanup logic with broad Docker commands.
- Stop on ambiguous installation, profile, release, transport, ingress, or project
  identity. Mutating workflows require a bounded dry run and the explicit
  confirmation defined by that operation.
- Never display or copy environment files, tokens, connector identities, JIT
  material, registration payloads, job output, or private host details.
- Diagnostics remain read-only except for their own exact, run-scoped collector
  container. Reports separate verified measurements, unavailable evidence, and
  labelled hypotheses.
- Package and import workflows must verify checksums, archive shape, identifiers,
  schema versions, size limits, path safety, and redaction before trusting returned
  evidence.
- Release assets must be staged from the reviewed plugin source and accompanied by
  their generated SHA-256 sidecars.
- Add focused hermetic coverage for every changed safety boundary or published skill
  contract.

See [Copilot CLI Operations](../../docs/guides/copilot-operations.md).
