---
applyTo: "manager/**/*.sh,manager/Dockerfile,docker-compose.yml,tests/Test-ManagerReconciliation.sh,tests/integration/**"
---

# Manager Lifecycle

- Keep manager scripts portable to their declared shell. Long-running reconciliation
  may classify expected nonzero statuses explicitly; do not replace that control flow
  with unconditional `set -e` or assume `pipefail` is portable.
- Only the manager mounts the host Docker socket and read-only host pressure source.
  Worker launch arguments must not propagate either mount.
- Launch workers for one job with `--rm` and ephemeral registration. A replacement
  worker is a new container, never a restarted job container.
- Select managers and workers through exact profile labels, slot labels, or exact
  container IDs. Never broaden adoption, cleanup, or teardown to container-name
  matching.
- Ordinary manager handoff preserves sibling workers. Only an explicit, fenced
  profile shutdown may remove the selected profile's workers.
- Removed slots drain after their current worker exits. Unknown Docker or registration
  state preserves the worker and surfaces degraded evidence rather than guessing that
  removal is safe.
- Desired, accepted, diagnostic, retirement, and observed state must be written
  atomically and remain restart-safe.
- Manager errors must retain the last valid pool and return a nonzero or degraded
  result. Do not fabricate successful reconciliation.
- Update shell syntax checks, hermetic reconciliation contracts, and real Docker
  integration coverage for lifecycle changes.

See [Rolling Updates](../../docs/guides/rolling-updates.md) and
[Security Boundaries](../../docs/guides/security-boundaries.md).
