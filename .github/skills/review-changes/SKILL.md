---
name: review-changes
description: >
  Review PitCrew changes before commit, push, or pull-request delivery against
  applicable instructions, project docs and ADRs, repository-declared validation,
  and existing CI evidence.
---

# Review PitCrew Changes

This skill owns review procedure, not project standards. Current instructions, docs,
ADRs, schemas, tests, scripts, manifests, and workflows remain authoritative.

## Review boundary

- Judge changed lines and their direct invariant blast radius.
- Report pre-existing divergence separately and exclude it from the verdict.
- Do not demand unrelated migration work because a document describes a target state.
- Do not invent findings for a clean diff.
- Review is read-only unless the user explicitly requests fixes.

## 1. Resolve the scope

Confirm the worktree and branch:

```powershell
git rev-parse --show-toplevel
git branch --show-current
git status --short
```

Select scope in this order:

1. Explicit refs, pull request, or paths supplied by the user.
2. All uncommitted changes: unstaged, staged, and untracked.
3. Otherwise `git merge-base origin/main HEAD` through `HEAD`.

Use `git --no-pager diff`, `git --no-pager diff --cached`, and full reads for
untracked files. For a pull request, confirm the actual base and head with
`gh pr view` and `gh pr diff`.

State the selected scope and changed files.

## 2. Resolve governing sources

Read `.github/genesis-guidance.json`, then resolve every applicable instruction from
the changed-path array:

```powershell
$changedPaths = @('<path-1>', '<path-2>')
& scripts/guidance/Get-ApplicableInstructions.ps1 -Path $changedPaths
```

Read the returned instructions in full. Follow relevant links from the documentation
map, contributor architecture, ADR index, and changed docs.

Project-owned instructions and accepted PitCrew ADRs specialize reusable defaults.
When `.github/instructions/genesis/` is installed, do not edit it to express local
policy.

For changes under `plugins/pitcrew-operations/`, read the complete affected skill,
its referenced safety contracts, manifest surfaces, and focused tests. Those skills
are published product behavior.

## 3. Resolve validation

Inventory declared validation:

```powershell
pwsh scripts/guidance/Get-ValidationInventory.ps1
```

Inspect the actual workflow and test definitions before choosing commands.

- Run the smallest offline command that covers the changed behavior.
- Use focused PowerShell suites, Go package selection, shell contracts, strict MkDocs,
  or Compose validation only when their owning surfaces changed.
- Do not invent a tool or command absent from repository code, docs, manifests, or
  workflows.
- Do not run the complete Docker integration suite, credentialed checks, live GitHub
  runner scenarios, or host operations on a workstation.
- Pull-request CI and configured PitCrew capacity own complete hosted evidence.
- For a pull request, inspect `gh pr checks` rather than reproducing heavy work.

Record commands, results, and required checks that were not run.

## 4. Review what gates do not prove

Read every changed file and inspect:

- one-job worker lifecycle and manager-only Docker access;
- exact profile, slot, label, and container identity;
- active-job preservation during capacity, image, and manager transitions;
- fixed/autoscaled semantic parity and GitHub-authoritative demand;
- observed-state privacy, bounded evidence, and null-versus-zero semantics;
- manifest, schema, manager-contract, and generated-state consequences;
- operations-plugin identity, confirmation, redaction, and release consistency;
- delivery trust boundaries, required checks, and untrusted workflow execution;
- documentation authority, canonical URLs, navigation, and Pages noindex behavior;
- credentials, private host details, untrusted inputs, and destructive actions.

Use the governing source for each exact rule. These categories are prompts, not a
second standards corpus.

## 5. Reflect on guidance

Treat review as a bounded feedback loop, not a default instruction-edit trigger.

Before final handoff, invoke [reflect-work](../reflect-work/SKILL.md) once when the current task or review shows either:

- one significant misstep or material correction with concrete risk or impact; or
- repeated evidence of avoidable friction, or a demonstrated tooling, guidance or CI gap.

The reflection skill uses this task's already-collected evidence and returns zero or one prevention proposal for the handoff.
Local and cloud agents use the same repository-local procedure; no personal plugin or cross-session history is required.
Normal TDD failures, necessary exploration and clean successful work are not automatic triggers.
Do not invoke it again merely to fill a recommendation quota or expand the original task into unrelated cleanup.

The lesson must be generalizable, supported by concrete evidence, and assigned to the correct owner.
Do not propose guidance for a one-off, speculative, hyper-specific or stylistic incident, or when existing guidance or executable checks already cover it effectively.
Prefer code or tests for enforceable behavior, instructions for recurring exact rules, docs for rationale, skills for procedures, and `AGENTS.md` only for unscopable safeguards.

Review remains read-only.
Report no guidance change when the threshold is not met; do not edit guidance automatically.

## 6. Report

Open with:

- `Scope:` reviewed range or paths
- `Verdict:` `Approve`, `Approve with nits`, or `Request changes`
- `Validation:` observed, passed, failed, and not-run evidence
- `Guidance reflection:` `no change warranted` or one evidence-backed candidate

Group introduced findings by severity:

- **Blocker** - broken behavior, security or destructive risk, failing required
  validation, or violation of an accepted architecture or delivery boundary.
- **Major** - clear correctness or contract defect that should be fixed before merge.
- **Minor** - bounded maintainability, coverage, documentation, or guidance defect.
- **Nit** - optional polish.

Every finding includes:

`severity - file:line - issue - governing source - concrete fix`

If there are no introduced findings, say so plainly. State uncertainty and missing
evidence instead of implying an unrun check passed.
