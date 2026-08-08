---
applyTo: ".github/workflows/**,.github/genesis-delivery*.json,.githooks/**,scripts/delivery/**"
---

# Pull-Request Delivery

- Treat `.github/genesis-delivery.json`, its schema, workflows, and delivery scripts
  as one executable contract. Keep required checks, workflow names, draft behavior,
  title rules, and merge settings aligned.
- Push feature branches and deliver through pull requests. The pre-push hook must
  continue blocking updates or deletion of the configured default branch.
- Draft validation may use the declared subset. Ready pull requests require fresh
  full validation and every required check.
- Ready Copilot-authored pull requests require the configured trusted human approval
  on the current head SHA.
- Public external-fork workflows require explicit maintainer approval before any
  proposed workflow runs on self-hosted capacity.
- Keep `pull_request_target` jobs isolated from untrusted checkout and execution.
  They may evaluate metadata or enable native merge policy only.
- Do not change runner routing, required checks, or merge policy in one surface while
  leaving the delivery contract stale.
- Conventional pull-request titles remain single-line and within the declared length
  limit.
- Complete hosted evidence belongs to configured CI. Local review records targeted
  checks and any intentionally unrun hosted validation.
