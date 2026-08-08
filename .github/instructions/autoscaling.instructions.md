---
applyTo: "manager/autoscaler/**/*.go,manager/autoscaler/go.mod,manager/autoscaler/go.sum"
---

# Autoscaler

- Use GitHub Runner Scale Set statistics as the demand authority. Configured counts
  are hard maximums; local CPU, memory, or container activity never invents demand.
- Scale up immediately toward assigned demand and the configured idle floor. Remove
  excess idle capacity only after the stabilization delay.
- Reserve profile-wide admission atomically before generating JIT configuration.
  Preserve rotating fairness and release unused capacity so one target cannot starve
  the others.
- Remove an idle registration through GitHub before Docker cleanup. Any assigned,
  busy, ambiguous, or failed-removal worker remains alive.
- Preserve durable retirement, cleanup, listener, and session ownership state across
  manager restart.
- Bound external calls with contexts and explicit deadlines. Propagate errors with
  actionable, sanitized evidence; never log tokens, JIT payloads, raw response
  bodies, job output, or unbounded payloads.
- Keep fixed and autoscaled observed-state contracts semantically aligned. Missing
  evidence remains unavailable rather than inferred.
- Use the repository-declared `go test ./...` and `go vet ./...` gates. Do not add or
  prescribe an undeclared lint framework.
- Cover concurrency, cancellation, fairness, scale-down delay, busy-worker
  preservation, and failure recovery with deterministic tests.

See [Demand-Driven Autoscaling](../../docs/guides/autoscaling.md).
