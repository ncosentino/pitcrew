---
name: pitcrew-profile-recover
description: Recover one explicitly selected degraded PitCrew profile with a single safe manager-only restart, after a read-only dry run and explicit operator confirmation, without touching workers, capacity, images, Docker, or the host. Use when a named profile's manager is degraded, stalled, or reporting listener or registration failures.
license: MIT
---

# PitCrew Profile Recovery

Recover the manager of one degraded profile. Workers keep running by
construction: this skill issues no worker-directed command at all.

Read these shared references before running commands:

- [operations safety](../../references/safety.md)
- [profile replay](../../references/profile-replay.md)
- [manager-only recovery contract](../../references/manager-recovery.md)

## Non-negotiable boundaries

- Never run `Setup-Runner.ps1 -Down`, Compose teardown, any prune, or
  name-pattern cleanup.
- Never restart Docker, Docker Desktop, the Docker daemon, or the host.
- Never stop, restart, kill, pause, remove, or enter a worker container.
- Never select containers beyond the exact PitCrew labels and the exact resolved
  manager ID.
- Never start a profile that has no currently running manager.
- Never recover a manager below contract 9.
- Never read or print environment files, tokens, connector identities, JIT
  configuration, registration payloads, or job output.
- Never change capacity, profile configuration, image identity, checkout
  revision, or generated desired state.
- Never claim that a manager restart proves the outage's root cause.
- Never start recovery automatically because a diagnostic reported a problem.

## Identity resolution

1. Resolve exactly one PitCrew installation with the profile replay reference.
2. Use the profile the user named. An omitted profile is never permission to
   recover every profile. When exactly one configured profile exists below
   `.pitcrew-state`, show it to the user and continue only with that one.
   Otherwise stop and ask which profile to recover.
3. Read only generated non-secret state:
   - `.pitcrew-state/<profile>/desired-capacity.json`
   - `.pitcrew-state/<profile>/acknowledged-capacity.json`
   - `.pitcrew-state/<profile>/static-profile.json`
   - `.pitcrew-state/<profile>/observed-state.json`
4. Never open `.env`, `.env.*`, a token file, a connector identity, a JIT
   payload, or job output, including with a filtered command.

## Preflight evidence

Collect read-only evidence with exact labels only:

```text
docker ps --filter "label=ephemeral-runner-manager-profile=<profile>" --format "{{.ID}} {{.Status}}"
docker inspect <exact-manager-id> --format "{{ index .Config.Labels \"pitcrew-manager-contract-version\" }}"
docker ps --filter "label=ephemeral-managed-runner-profile=<profile>" --format "{{.ID}} {{.Status}}"
```

Record from observed state: `managerInstanceId`, `generation`,
`desiredStateHash`, `managerStatus`, `observedAt` freshness, mode
(fixed or autoscaled), `configuredSlots`, `activeSlots`, `eligibleSlots`, and
`autoscaling.targetSlots` and `autoscaling.status` when present.

Stop and report `rejected` without any mutation when the exact manager label
matches zero or more than one container, when the manager contract is below 9,
when `.pitcrew-state/<profile>/manager-shutdown.json` exists, or when observed
state is missing or belongs to another profile.

## Dry-run mode

Always dry run first. Display:

1. the selected profile and its resolved installation root
2. the manager contract version and the exact manager match count
3. the current manager instance and generation fences, plus the desired-state
   hash when present
4. the local worker count and the observed eligibility, target, and freshness
   evidence
5. the exact invocation that would run, with secret-free arguments:

   ```text
   pwsh ./Setup-Runner.ps1 -Profile <profile> -RecoverManager -ExpectedManagerInstanceId <instance> -ExpectedGeneration <generation> -ExpectedDesiredStateHash <hash> -RecoveryTimeoutSeconds <seconds>
   ```

6. every prohibited action that will not occur, quoted from the recovery
   contract: no teardown, no prune, no cleanup, no Docker or host restart, no
   worker command, no capacity or configuration change, no image change, no
   credential access, and no second attempt

Change nothing during the dry run.

## Explicit confirmation

Require explicit operator confirmation of that printed plan before invoking
recovery. Earlier generic approval to diagnose a host, update a pool, or run
Docker commands is never approval to restart a manager. If the operator has not
confirmed this exact profile and these exact fences, stop.

## Recovery

Invoke only the first-class operation, exactly as printed in the dry run. Never
reproduce its restart logic with raw Docker commands, and never add a Docker
argument of your own.

Re-read observed state immediately before invoking so the fences are current. If
the fences moved, return to the dry run instead of submitting stale values.

## Verification and reporting

Capture post-recovery state with the same read-only commands and compare it with
the preflight snapshot. Report exactly one result:

- `recovered`
- `still-degraded`
- `rejected`
- `failed`
- `indeterminate`

Report with evidence: the manager instance before and after, the unchanged
generation and desired-state hash, the manager status, observed-state freshness,
worker counts before and after with their exact IDs, and the fixed registration
or autoscaled listener convergence state.

A worker that disappeared during the window finished its ephemeral job. Recovery
issued no worker command, so never describe such an exit as a worker that
recovery stopped. State plainly that a restarted manager is not a root cause.

## One attempt only

Stop after one attempt. On `still-degraded`, `failed`, or `indeterminate`, hand
the evidence back to the operator and stop. Never escalate to a Docker daemon or
Docker Desktop restart, a host reboot, a worker restart or removal, cleanup, a
capacity change, a profile replay, or a release update, and never repeat the
recovery on your own initiative.

## Multiple profiles

Process explicitly named profiles strictly one at a time. Each profile gets its
own fresh preflight, its own dry run, and its own explicit confirmation. Stop the
whole batch after the first `rejected`, `failed`, or `indeterminate` result and
report the profiles that were not attempted.

## Redaction

Redact absolute host paths as `<pitcrew-root>`, plus user names, machine names,
and internal host names that are not required. Never emit anything sourced from
an environment file, token, connector identity, JIT configuration, registration
payload, or job output, which this skill never reads in the first place.
