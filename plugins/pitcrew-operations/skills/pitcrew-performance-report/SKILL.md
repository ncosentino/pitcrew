---
name: pitcrew-performance-report
description: Correlate bounded GitHub Actions job timing with scoped PitCrew Dashboard node, profile, telemetry, hardware, and cross-profile overlap evidence without reading logs or mutating runners.
license: MIT
---

# PitCrew Performance Report

Create a read-only, redacted cross-node performance report with the supported
script in this skill.

Read [operations safety](../../references/safety.md) before running commands.

## Required inputs

Collect all of these from the caller:

- one PitCrew Dashboard base URL;
- one tenant identifier;
- one or more explicitly approved `OWNER/REPOSITORY` values;
- an inclusive start and exclusive end time;
- optional node, profile, workflow, and job filters;
- an optional output directory.

Require the raw diagnostic credential in the process environment variable
`PITCREW_DIAGNOSTICS_CREDENTIAL`. Never ask the caller to place it in a URL,
script argument, repository file, report, command history, or log.

Use the caller's existing `gh` authentication for GitHub metadata. Never send
PitCrew or repository data to another service.

A profile filter requires explicit Dashboard node IDs. Current fleet pages
cannot enumerate a removed profile, so `-Profile` without `-NodeId` must fail
instead of silently dropping retained history. When a profile-scoped
credential forbids node history and no exhaustive profile list was supplied,
the report marks the assignment universe incomplete and verifies no mappings.

## Non-negotiable boundaries

- Query only workflow-run and job metadata: IDs, names, exact runner name,
  labels, timestamps, status, and conclusion.
- Never request or display job logs, artifacts, environment values, step
  output, caches, secrets, registration payloads, or JIT configuration.
- Never mutate a workflow, run, job, runner, capacity command, manager,
  connector, Docker daemon, container, image, network, volume, or host.
- Never use fuzzy runner prefixes or host-name guesses. Hash the exact GitHub
  `runner_name` locally and join only by exact lowercase SHA-256 equality.
- Never treat a missing, ambiguous, stale, partial, or truncated match as zero
  or as a successful measurement.

## Supported command

Resolve this skill's `scripts` directory and invoke:

```powershell
pwsh ./scripts/New-PitCrewPerformanceReport.ps1 `
    -DashboardUrl https://dashboard.example `
    -TenantId example `
    -Repositories owner/repository `
    -From 2026-08-01T00:00:00Z `
    -To 2026-08-02T00:00:00Z
```

Add only caller-approved filters:

```powershell
-NodeId <dashboard-node-guid> `
-Profile project-ci `
-Workflow build `
-Job test `
-OutputDirectory <report-directory>
```

Before execution, print the Dashboard origin, tenant, repositories, UTC range,
filters, and output directory. Print only whether the diagnostic environment
variable is present; never print its value.

## Correlation and analysis contract

The script:

1. reads Dashboard history capabilities;
2. paginates the scoped current fleet;
3. reads bounded node history, or permitted profile history when node history
   is forbidden by credential scope;
4. paginates GitHub workflow runs and every job for the approved repositories;
5. hashes each exact runner name locally;
6. maps only one exact hash whose retained assignment interval overlaps the job;
7. calculates count, median, p95, range, and timeout/cancellation rate;
8. calculates same-node overlap with jobs mapped to other profiles;
9. includes sanitized hardware and hardware changes;
10. projects contract-18 host-admission fields and summarizes status,
    epoch/decision progress, held/borrowed/pending/withheld units, and
    admission-related deficit reasons by node and profile;
11. records partial telemetry, retention loss, truncation, missing timestamps,
    unmatched hashes, and ambiguous hashes as unavailable evidence.

Cross-profile overlap is an association, not proof of contention. Hardware
differences are context, not benchmark rankings.

Host-admission interpretation is also bounded:

- `disabled` is a measured state; null status is unreported evidence.
- `degraded` and `unavailable` do not establish a zero balance.
- Positive withheld units show that new worker demand was gated, not how long
  a GitHub job waited or why a running job took longer.
- Policy units are measurement-derived abstractions, not CPU cores, memory,
  worker counts, or universal workload weights.
- GitHub queue eligibility and host admission are separate. The report covers
  jobs GitHub started and cannot infer every job that remained queued without a
  runner assignment.

## Report handoff

Return the full absolute paths to:

- `pitcrew-performance-report.md`
- `pitcrew-performance-report.json`

The files carry equivalent measurements and use three explicit sections:

1. **Verified measurements**
2. **Unavailable evidence**
3. **Hypotheses**

The report omits raw runner names and node display names. It uses Dashboard
node IDs plus neutral `node-N` labels and contains no credentials, internal
paths, job output, or URL query strings.

State explicitly:

- correlation is not causation;
- one paired sample is not a host benchmark;
- host-admission units are abstract policy accounting, not resource
  measurements or workload priority;
- withheld admission is not proof of GitHub queue delay or job-duration cause;
- the non-destructive repeat measurement that would confirm each hypothesis.
