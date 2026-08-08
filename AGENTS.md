# Agent Instructions

PitCrew orchestrates isolated, ephemeral GitHub Actions runner pools with
PowerShell, Docker Compose, and a POSIX shell manager.

## Sources of truth

- Start with the [documentation map](docs/index.md) and
  [contributor architecture](docs/contributing/architecture.md).
- Path-scoped files under `.github/instructions/` own exact rules for matching
  edits. `.github/genesis-guidance.json` defines budgets and review wiring.
- Accepted decisions live under `docs/adr/`.
- Product operations procedures live under
  `plugins/pitcrew-operations/skills/`; they are published user-facing contracts.
- Code, schemas, tests, scripts, manifests, and workflows are executable truth.
  Investigate and correct stale prose when sources disagree.

## Global safeguards

- Preserve the one-job disposable-worker model and manager-only Docker socket
  boundary.
- Preserve active jobs during compatible capacity, image, and manager changes.
  Use exact profile labels or container IDs; never broaden cleanup by name.
- Never commit credentials, registration material, non-public repository or host
  details, or developer-specific paths. Sanitize every public artifact.

## Delivery

- Push feature branches and deliver through pull requests. Follow
  `.github/genesis-delivery.json`, the owning workflows, and `.githooks/pre-push`.
- Run targeted checks while iterating; complete Docker and hosted evidence belongs
  to configured CI and PitCrew capacity.
- Before delivery, run
  [review-changes](.github/skills/review-changes/SKILL.md) and disclose missing
  evidence, assumptions, and deliberately deferred work.
