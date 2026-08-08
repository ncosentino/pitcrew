---
applyTo: "AGENTS.md,CLAUDE.md,.github/copilot-instructions.md,.github/instructions/**,.github/skills/review-changes/**,.github/genesis-guidance*.json,scripts/guidance/**,tests/Test-Guidance.ps1,docs/contributing/agent-guidance.md,docs/adr/**"
---

# Guidance Architecture

- Keep project identity and unscopable safeguards in `AGENTS.md`; move exact recurring
  rules to scoped instructions and rationale to maintained docs.
- Enforce the root and matched-context budgets declared in
  `.github/genesis-guidance.json`. Free space is not permission to duplicate content.
- One instruction targets one coherent file population and contains only the
  normative minimum plus failure prevention. Do not import or name another
  instruction file.
- Derive changing file, test, package, workflow, and validation inventories through
  scripts or executable manifests instead of copying lists into instructions.
- Files under the reserved `.github/instructions/genesis/` namespace are managed
  output when installed. Specialize PitCrew in project-owned files outside that
  subtree.
- Keep `docs/index.md` as the documentation map. Accepted ADR reasoning is immutable;
  supersede a decision with a new record.
- The review skill owns procedure only. It resolves current instructions, docs,
  decisions, validation, and hosted evidence rather than maintaining another
  standards corpus.
- Update structural positive and negative cases whenever the guidance contract
  changes.
- Generated mirrors may change only through the owning command declared by the
  guidance contract.

See [Agent Guidance](../../docs/contributing/agent-guidance.md).
