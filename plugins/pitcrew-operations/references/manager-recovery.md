# PitCrew Manager-Only Recovery Contract

Use this reference whenever a degraded PitCrew profile must be recovered by
restarting only its manager. Recovery is a one-shot, non-idempotent operation.
It is never retried automatically and never redelivered.

## What recovery is

Manager contract 9 and newer treat an ordinary termination signal without a
matching explicit shutdown request as a handoff: labelled workers stay alive,
active jobs are not deliberately stopped, and the replacement manager rebuilds
its controllers and adopts the surviving workers. Restarting exactly one running
manager is therefore the safest first response to a degraded profile.

Recovery is not diagnosis, not remediation, and not proof of a root cause. A
recovered manager only proves that the manager process was replaced and that its
observed state advanced.

## The only supported command

```text
pwsh ./Setup-Runner.ps1 -Profile <profile> -RecoverManager -ExpectedManagerInstanceId <instance> -ExpectedGeneration <generation> -ExpectedDesiredStateHash <hash> -RecoveryTimeoutSeconds <seconds>
```

The operation itself:

- takes the existing profile operation lock, so it cannot race setup, refresh,
  capacity reconciliation, teardown, or another recovery
- resolves the profile from `.pitcrew-state/<profile>` and generated non-secret
  state, and never needs or prints the stored registration token
- selects the manager only through the exact label
  `ephemeral-runner-manager-profile=<profile>`
- requires exactly one running manager, requires manager contract 9 or newer,
  and refuses while a `manager-shutdown.json` full-stop request exists
- re-verifies profile identity and every fence immediately before mutation
- issues exactly one bounded restart against the exact container ID with the
  established 60-second graceful stop window
- verifies postconditions and returns a nonzero result for anything other than a
  verified recovery

Never reimplement any part of that flow with raw Docker commands.

## Fences

Read the fences from `.pitcrew-state/<profile>/observed-state.json` immediately
before invoking recovery:

- `managerInstanceId` → `-ExpectedManagerInstanceId`
- `generation` → `-ExpectedGeneration`
- `desiredStateHash` → `-ExpectedDesiredStateHash` when present

Stale evidence must cause rejection, not a best-effort restart. When the
operation reports `rejected`, re-read current state and ask the operator again;
do not resubmit the old fences.

## Result classification

| Result | Meaning |
| --- | --- |
| `recovered` | New manager instance, unchanged generation and hash, manager status `running`, and registration or listener state converged. |
| `still-degraded` | The manager returned but registration or listener state did not converge within the bounded window. |
| `rejected` | A precondition or fence failed. Nothing was restarted. |
| `failed` | Docker could not restart the manager, or a postcondition was violated. |
| `indeterminate` | Observed state did not advance, or manager identity was ambiguous afterwards. Current identity must be re-read before any second attempt. |

Only `recovered` exits zero.

## Postconditions

- the manager container is running and exactly one still matches the exact label
- `observed-state.json` advanced after the operation
- `managerInstanceId` changed from the fenced pre-recovery instance
- `managerStatus` is `running`
- the accepted generation and desired-state hash are unchanged
- fixed profiles reconcile registrations; autoscaled profiles return their
  listener to `running` within the same bounded convergence window
- worker containers are observed before and after with exact labels only

A worker that exits during the window completed its ephemeral job naturally.
Recovery issues no worker-directed command, so never report such an exit as a
worker that recovery killed.

## Prohibited actions

- `Setup-Runner.ps1 -Down`, `docker compose down`, any prune, or name-pattern
  cleanup
- restarting Docker, Docker Desktop, the Docker daemon, or the host
- stopping, restarting, killing, pausing, removing, or entering a worker
- selecting containers by anything except the exact PitCrew labels and the exact
  resolved manager ID
- starting a profile that has no currently running manager
- recovering a manager below contract 9
- reading or printing `.env`, tokens, connector identities, JIT configuration,
  registration payloads, or job output
- changing capacity, profile configuration, image identity, checkout revision,
  or generated desired state
- a second automatic attempt after `failed` or `indeterminate`
