---
title: "ADR-0001: Docs-first agent guidance"
status: "Accepted"
date: "2026-08-07"
authors: []
tags: ["architecture", "documentation", "agents"]
supersedes: ""
superseded_by: ""
---

# ADR-0001: Docs-first Agent Guidance

## Context

PitCrew combines PowerShell orchestration, portable shell managers, a Go autoscaler,
Docker contracts, JSON schemas, public documentation, CI delivery, and published
Copilot operations skills.

The root `AGENTS.md` accumulated repository structure, architecture invariants,
validation commands, and detailed delivery policy. That content was mostly correct,
but it loaded for every task and duplicated rules already owned by docs, workflows,
tests, schemas, and the Genesis delivery contract. The repository had no scoped
contributor instructions, local review skill, guidance resolver, or structural
guidance gate.

PitCrew also intends to consume reusable Genesis-managed instructions. The current
common set is not yet safe for this repository because it prescribes undeclared Go
tooling, applies command-specific testing rules broadly, and treats one shell-option
combination as the only valid failure model. Genesis issue
[#408](https://github.com/ncosentino/genesis/issues/408) tracks that reusable work.

## Decision drivers

- Keep always-loaded context small.
- Deliver exact rules only to the file populations that need them.
- Preserve PitCrew's lifecycle, trust-boundary, privacy, and delivery policy.
- Keep operator-facing skills separate from contributor review procedure.
- Derive validation from executable repository sources.
- Permit later Genesis-managed adoption without overwriting local guidance.
- Enforce the structure mechanically.

## Decision

PitCrew adopts a layered, docs-first guidance architecture.

### Root entrypoints

`AGENTS.md` contains only project identity, trusted-source routing, exceptional
cross-cutting safeguards, and delivery routing. It is limited to 60 lines and 3,072
UTF-8 bytes.

`CLAUDE.md` remains the one-line `@AGENTS.md` redirect.
`.github/copilot-instructions.md` remains a minimal pointer to `AGENTS.md`.

### Scoped instructions

Project-owned files under `.github/instructions/` contain terse normative rules for
coherent file populations. Architecture, alternatives, and long examples stay in
docs. Dynamic inventories are derived by scripts rather than copied into prose.

The `.github/instructions/genesis/` namespace is reserved for future managed
instructions. Only the Genesis synchronization workflow may replace it. PitCrew
specialization remains outside that subtree.

### Documentation and decisions

`docs/index.md` is the canonical documentation map. `mkdocs.yml` owns site navigation
and the published build. Contributor architecture and guidance pages state current
truth and link to existing public guides rather than duplicating them.

Significant guidance decisions live under `docs/adr/`.

### Review and validation

`.github/skills/review-changes/` owns review procedure, not another standards corpus.
It resolves the current diff, applicable instructions, docs and ADRs, executable
validation, and hosted evidence.

Repository-owned guidance scripts discover matching instructions and validation
surfaces. `tests/Test-Guidance.ps1` enforces root budgets, redirects, documentation
reachability, ADR lifecycle, instruction metadata and context budgets, review wiring,
and controlled negative fixtures.

The existing CI contracts job runs the guidance test. Complete Docker integration and
hosted validation remain with CI.

### Product skills and generated mirrors

The installable operations skills under `plugins/pitcrew-operations/` remain product
surfaces with their own safety and testing contracts. They are not moved into the
contributor review skill.

No generated Claude instruction mirror is introduced. The root redirect is sufficient
for current harnesses.

## Alternatives considered

**Keep root-only guidance.** This avoids migration but keeps unrelated architecture,
commands, and delivery policy permanently loaded and leaves no structural drift gate.

**Use only project-owned instructions.** This is accurate today but would duplicate
reusable guidance indefinitely. Project-owned instructions are the immediate layer,
while the managed namespace remains available after Genesis issue #408.

**Sync all common Genesis instructions immediately.** This provides managed updates
but introduces verified conflicts with PitCrew's declared toolchain and portable shell
behavior. Managed adoption is deferred rather than locally forking those generic
rules.

**Put every invariant in instructions.** Exact rules would arrive at edits, but
architecture and rationale would become recurring context and human documentation
would remain fragmented.

## Consequences

### Positive

- Root context becomes bounded.
- Exact lifecycle and trust-boundary rules arrive with relevant edits.
- Existing public docs and executable contracts remain authoritative.
- Review derives validation rather than maintaining another command table.
- Future Genesis-managed adoption has a protected namespace and precedence model.
- Structural drift is detected before delivery.

### Negative

- Guidance now spans several deliberately different surfaces.
- Contributors must classify new content by owner.
- The structural gate and documentation map require maintenance.
- Genesis-managed adoption remains a separate follow-up until upstream guidance is
  compatible.

## Confirmation

The guidance test, strict MkDocs build, before/after inventory, and repository-local
review skill confirm this decision. Hosted CI remains the owner of complete runner and
Docker integration evidence.
