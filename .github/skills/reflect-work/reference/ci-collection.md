# Bounded CI evidence collection

The reflector does not start, rerun, cancel, quarantine or modify CI. It may inspect
existing evidence through the provider's supported read-only interfaces, subject to
the user's repository authorization and privacy boundaries.

For GitHub Actions, begin with a time-bounded run inventory and the relevant PR/head.
Retrieve every observed run attempt, including failed and canceled attempts. The jobs
API defaults to the latest attempt; use its all-attempt or attempt-specific interface
and paginate explicitly. Do not describe a latest-only response as complete.
Stop at the schema's run/job/byte limits and mark collection partial rather than
silently dropping rows. Never send a private log or repository query to a public
search engine.

The offline helper accepts at most 2 MiB, 100 attempt records and 1,000 jobs, with a
positive UTC window no longer than 366 days. Every non-null record timestamp must be
inside the inclusive window. Widen the explicitly reported window for crossing
attempts or omit them with collection marked incomplete; never keep a claim of
complete coverage after exclusion. An all/complete declaration must contain attempts
1 through the highest observed attempt for each run.

Normalize metadata into `ci-evidence.schema.json`. Use decimal string IDs to avoid
lossy numeric conversions, full commit hashes, UTC timestamps, and null for absent
measurements. Preserve the run identity and attempt separately. Do not include raw
logs, commands, credentials, machine names, or environment variable values. A
non-secret environment fingerprint may identify known equivalent execution settings;
absence is an explicit evidence gap.

Map provider metadata rather than asking the model to calculate durations. Run IDs
and job IDs remain strings; run attempt and head SHA stay attached to the correct
attempt. Keep provider creation timestamps separate from start/completion timestamps.
Do not substitute a rerun start for a missing creation time. Unsupported statuses,
missing pages, unresolved attempt identity and excluded crossing records make the
collection incomplete; do not fabricate completed rows or environment fingerprints.

Run `Get-ReflectionCiSummary.ps1` on that external file and cite the input/output
hashes in the reflection evidence. The helper does not fetch provider data or infer
missing attempts. Check its completeness and cautions before interpreting totals.

## Accounting

Keep distinct:

- trigger to first actionable failure and final acceptable result, when those events
  are available;
- pre-start delay, which may include dependency, approval, concurrency and runner
  availability waits;
- measured job execution intervals and their sum across parallel jobs/attempts;
- the observed elapsed span, not the sum of parallel durations;
- additional measured runner occupancy on attempts after the first;
- missing or unfinished intervals;
- provider billing, artifact/cache storage, and model credits, only when measured
  through their owning systems.

Runner occupancy is not CPU time, billed dollars, or human waiting time. Missing
duration is not zero. Jobs crossing a time window need explicit accounting policy;
follow the helper's contract rather than relabeling lifetime totals as window usage.

## Diagnosis

Same-SHA failure followed by success is suspected nondeterminism, not proven test
flakiness. Check dependencies, merge context, runner/tool versions, inputs, seeds,
test order, service availability, and failure signature. A changed environment can
explain both results. Duplicated work requires equivalent assurance purpose and
inputs, not merely matching test names.

Inspect repeated restores/builds, overlapping push/PR triggers, cache misses,
late fail-fast checks, unnecessary matrices, unstable fixtures and excessive retained
artifacts. Compare against ordinary successful work in the same job family.

### Feedback-loop waste and late failure observation

Compare the validation chosen for each debugging iteration with the smallest declared, authorized command that could answer the current failure.
Repeated broad CI runs for a focused parser, fixture or registration error are a signal to investigate, not an automatic requirement for more instructions.
When policy prevents a narrow local reproduction, propose an existing targeted CI route or request a narrow exception promptly; never bypass authorization or weaken final integration checks.

Inspect whether the agent waited for the entire workflow while a decision-relevant job had already failed.
Record when the failure became observable, when the agent observed it, and when corrective action began.
Account for log/API availability; a timestamp inside a buffered log does not prove the agent could already read it.
Compute failure-to-observation delay only from supplied timestamps and keep it separate from job runtime, queue delay and summed runner consumption.
Missing observation/action timestamps remain unknown.

Look for repeated polling without a decision, missed completion/failure notifications, and superseded diagnostic work that continues after its outcome can no longer validate the next revision.
Propose job-aware monitoring and an explicit next-action/stop condition rather than silently waiting for unrelated long-running jobs.
Canceling an operator-owned superseded diagnostic run is a separately authorized action, not an action this report-only skill performs.

Retain the counterexample: a broad integration run performed once after focused checks can provide required assurance and is not waste merely because it is slow.
Compare scopes and environments before claiming a speedup from local versus CI duration.

Propose savings with denominators and uncertainty. Preserve executed/collected/skipped
test counts, required scenarios/platforms, and existing coverage/assertions.
Quarantine or skipping is not an automatic optimization; any separately approved
quarantine needs an owner, expiry, and visible retained failure evidence.

Sources: [workflow jobs API](https://docs.github.com/en/rest/actions/workflow-jobs),
[workflow cancellation](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-cancellation),
and [flaky-test management](https://learn.microsoft.com/en-us/azure/devops/pipelines/test/flaky-test-management?view=azure-devops).
