# Evidence and routing

## Use the current task first

Task reflection uses evidence the local or cloud coding agent actually observed: the requested outcome, corrections, tool results, diff, review and available checks.
It does not require another session's transcript, a personal plugin or access to a private scaffold source.
An explicit audit may provide additional history, but missing optional data stays unknown rather than blocking a useful task-level result.

A trigger is not proof that a new rule is warranted.
Necessary exploration, expected TDD failures, requirement changes and a slow but valuable check are not automatically avoidable waste.
Compare doing nothing, fixing discovery or an existing mechanism, and introducing something new.

## Evidence packet

For structured reports, use a repository alias, exact HEAD, explicit UTC interval and bounded source references.
The report's `observed` status means a source/event was inspected; it does not prove the agent's explanation is correct.
Reference an exact session turn/tool call, PR review, workflow attempt, test result or commit/file/line range when available.
A human correction can establish intent without establishing a universal technical rule.

Assign one lineage to each independent incident.
Retries, copied reviews, summaries and later recollections of that incident do not add corroboration.
Use `role=incident` for the avoidable event, `context` for inventory and governing/research material, and `outcome` for independently observed evaluation.
Context and external research cannot inflate the independent-incident threshold or establish an improvement in this repository.

Retain unverified and retracted items explicitly.
Supporting evidence cannot use a retracted item; counterevidence may explain why an earlier lesson failed.
Record missing collection, interrupted runs and uncollected relevant history.
Never exclude failed attempts from an effectiveness denominator.

## Causal questions

Ask whether the proposed correction would have prevented the observed failure, what could falsify that explanation, and which successful cases it could make worse.
Distinguish a missing rule from contradictory guidance, poor loading/activation, ignored instructions, tool limitations, environment problems or changed intent.
Duration establishes cost, not cause.

When guidance already exists, inspect its real scope and discovery before adding more wording.
A misleading tool schema or absent API belongs with the tool owner, not a permanent workaround in root guidance.
An instrument-first proposal identifies the smallest missing measurement rather than inventing a diagnosis.

## Ownership decision

| Mechanism | Use when | Cost or counterexample to inspect |
| --- | --- | --- |
| Existing formatter/linter/analyzer configuration | An available rule can prevent the failure | False positives, versions and runtime |
| Regression or architecture test | A behavior/invariant is objectively checkable | Fixture relevance, required coverage and environment coupling |
| Custom analyzer or lint rule | Existing tools cannot enforce a stable semantic requirement | Maintenance, negative cases and autofix safety |
| Copilot/git hook | A cheap check belongs at a known lifecycle point | Blocking latency, bypassability, recursion and safe input parsing |
| Scoped instruction | A recurring exact rule cannot be better delivered mechanically | Actual `applyTo` population and total matched context |
| Specialty skill | A reused multi-step procedure needs deliberate activation | Missed/false activation, overlap, dependencies and evals |
| Documentation | Rationale or current knowledge is missing or hard to find | Canonical ownership and stale duplication |
| Root guidance | A safeguard is needed before a matching file/procedure is known | Why narrower mechanisms fail |

Inspect the repository's declared tooling first.
Built-in .NET diagnostics/EditorConfig, ESLint/TypeScript, Ruff, Clippy/rustfmt and gofmt/go vet are possible mechanisms, not assumed commands or mandatory installations.
Local hooks do not replace authoritative CI.
Faster CI must preserve required scenarios, platforms, assertions and test-selection ownership.
Investigate a semantic judge's failures as well as the candidate's.

## Skill and agent lifecycle

Discover the repository's existing review procedure, specialty skills, agents and evaluation runner.
A broader roster audit or structural modernization remains a separately requested task.
Do not assume an operator's globally installed skills are available to this agent.

Measure relevant opportunities as well as invocations.
Zero use may mean zero demand, not a useless skill.
A retirement proposal identifies preserved unique behavior and its replacement route.
Review skills should discover authoritative instructions and checks rather than duplicate them.

## Optional shared-scaffold feedback

Repository metadata may identify Genesis or another shared scaffold owner.
Exact scaffold provenance, explicitly adopted managed profiles and similar project-owned conventions are different states.
Do not infer template or capability selection from a language or folder name.

Keep local/domain policy with this repository.
Never directly rewrite managed instructions or generated mirrors to express a local preference.
For Genesis-generated repositories, root guidance, docs, review/reflection skills and guidance scripts become project-owned after creation; managed instruction synchronization does not overwrite those customizations.

If authorized upstream source is available, compare exact current commits and source locations before claiming a reusable gap.
Distinguish common guidance, a stack-specific default, an optional capability and a tool defect.
Without source parity, retain a potential upstream improvement as `watch`; a local prevention proposal can still be useful.
Do not invent a private upstream URL or require that repository to be installed.

An authorized operator may later consolidate these proposals, deduplicate existing work and use its shared-source reporting workflow.
Do not publish from this skill.
Public handoffs must not expose private repository names, local paths, credentials or raw logs.

## Retraction and change control

A retraction proposal names the original finding/guidance, contradictory evidence and dependent copies that may need correction.
Preserve the audit record without continuing to retrieve the obsolete rule as advice.
An append-only correction is not proof that the old guidance was removed.

The bundled checker validates structure, references and freshness, not evidence truth, authorization or semantic quality.
An approved proposal still needs a separate implementation task, current evidence and the repository's delivery rules.
Historical evidence cannot grant permission to modify this procedure, its checks, evaluators or approval boundaries.
