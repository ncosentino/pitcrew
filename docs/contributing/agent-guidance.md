---
description: Understand where PitCrew agent guidance lives, how conflicts resolve, and how changes are reviewed.
---

# Agent Guidance

PitCrew separates guidance by ownership and loading cost. The accepted architecture
is recorded in [ADR-0001](../adr/adr-0001-docs-first-agent-guidance.md).

## Sources of authority

| Surface | Responsibility |
| --- | --- |
| `AGENTS.md` | Project identity, trusted-source routing, and safeguards needed before any file is selected |
| `CLAUDE.md`, `.github/copilot-instructions.md` | Minimal harness redirects |
| `.github/instructions/` | Exact recurring rules for coherent file populations |
| `docs/` | Current architecture, rationale, tradeoffs, and failure modes |
| `docs/adr/` | Accepted significant decisions and their consequences |
| `.github/skills/review-changes/` | On-demand review procedure |
| Product skills under `plugins/` | Operator-facing PitCrew behavior |
| Code, schemas, tests, scripts, and workflows | Deterministic executable truth |

When sources disagree, investigate the executable contract and correct stale prose.
Project-owned instructions govern exact local rules. Accepted ADRs govern significant
structural decisions. Docs explain why those rules exist.

## Project-owned and managed instructions

PitCrew's instructions are project-owned unless they live under the reserved
`.github/instructions/genesis/` subtree. Project-owned specialization belongs outside
that subtree.

Managed instructions are currently not installed. They may be adopted later through
their owning synchronization tool after the selected instruction composition is
proven compatible. A future sync may replace only the managed subtree; it must not
overwrite PitCrew instructions, root files, docs, or review tooling.

### Current divergence

Selected reusable rules currently conflict with this repository's declared
toolchain, testing scope, and portable shell contracts. PitCrew keeps its local
guidance project-owned until that managed layer is safe to consume.

## Context budgets

- `AGENTS.md`: at most 60 lines and 3,072 UTF-8 bytes.
- `CLAUDE.md`: one-line `@AGENTS.md` redirect.
- Copilot root instructions: at most three lines and 128 UTF-8 bytes.
- One instruction: review above 100 lines or 8 KiB.
- Matching instruction stack: target at most 300 lines or 16 KiB; hard maximum
  600 lines or 32 KiB.

An available byte or line budget is not permission to duplicate rationale. Put one
concern with one canonical owner.

## Reviewing changes

Use the repository-local
[review-changes skill](https://github.com/ncosentino/pitcrew/blob/main/.github/skills/review-changes/SKILL.md)
before delivery.
It resolves the actual diff, applicable instructions, documentation and ADR context,
repository-declared validation, and hosted CI evidence.

The skill reviews changed lines and their direct invariant blast radius. Existing
divergence is reported separately and is not assigned to an unrelated change.

The supporting scripts are:

- `scripts/guidance/Get-ApplicableInstructions.ps1`
- `scripts/guidance/Get-ValidationInventory.ps1`
- `scripts/guidance/Test-GuidanceContract.ps1`

`tests/Test-Guidance.ps1` protects the guidance structure with deterministic positive
and negative cases.
