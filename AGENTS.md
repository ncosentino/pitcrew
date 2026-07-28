# Agent Instructions

PitCrew orchestrates isolated, ephemeral GitHub Actions runner pools with
PowerShell, Docker Compose, and a POSIX shell manager.

## Repository structure

- `Setup-Runner.ps1` is the operator entry point.
- `RunnerProfiles.Functions.ps1` resolves and validates profile manifests.
- `runner-profile.schema.json` defines the public profile contract.
- `manager/` contains the socket-owning babysitter container.
- `manager/autoscaler/` contains the opt-in GitHub Runner Scale Set controller.
- `manager/reconciliation.sh` validates desired capacity and derives stable slot
  keys for the manager.
- `profiles/` contains built-in specialized worker images.
- `tests/Test-RunnerProfiles.ps1` is the hermetic contract suite.
- `docs/` and `mkdocs.yml` define the public documentation site.

## Invariants

- A worker handles one job and is destroyed with `--rm`.
- Only the manager mounts the host Docker socket.
- Resource telemetry is collected by the manager and published through
  credential-free observed state; connectors remain read-only consumers.
- Named profiles have isolated Compose projects, state files, labels, and
  cleanup selectors.
- Capacity-only updates leave existing workers and the manager untouched;
  removed slots drain after their current runner exits.
- Autoscaled profiles treat configured capacity as a maximum and use GitHub's
  scale-set statistics as the only demand count.
- Named profiles omit GitHub's broad default labels unless explicitly opted in.
- Validate new images before replacing a live profile.
- Never put credentials in manifests, Docker build arguments, images, examples,
  or tracked environment files.
- Never broaden cleanup from exact labels to container-name matching.
- Keep `docs/_headers` noindex rules on Pages production and preview origins;
  the canonical Dev Leader router removes that header from public responses.

## Validation

Run the smallest relevant command:

```powershell
pwsh tests/Test-RunnerProfiles.ps1
pwsh tests/Test-CopilotPlugin.ps1
```

```bash
sh -n manager/manage-runners.sh
go -C manager/autoscaler test ./...
go -C manager/autoscaler vet ./...
docker compose --file docker-compose.yml config --quiet
python -m mkdocs build --strict
```

## Pull Request Delivery

- Local commits are unrestricted checkpoints. Push only feature branches;
  direct updates or deletion of `main` are blocked by `.githooks/pre-push`.
- Run targeted checks while iterating. Before final validation, inspect the
  actual CI runner routing and validate locally enough to avoid repeated
  hosted-CI failures.
- Agent-initiated PRs default to draft. "Open a PR" and "publish a PR" mean
  ready for review; "open a draft PR" and "open a PR so I can review" mean
  draft.
- Genesis drafts run the runner-contract subset and publish `Draft CI`. Moving
  a PR to ready starts fresh full validation and publishes the required `CI`
  check.
- Ready Copilot-authored PRs require one trusted human approval on the current
  SHA when `GENESIS_REVIEW_POLICY=copilot-one-approval`.
- Public external fork workflows from all contributors require explicit
  maintainer approval before they run. Approval authorizes the complete
  proposed workflow, including any runner selection.
- Native merges use GitHub's branch auto-delete setting. The inactive private
  workflow-run template is retained only for repositories that cannot use
  protected native delivery.

Before opening a ready PR, publishing a draft, or pushing more commits to an
already-ready PR:

1. Confirm the PR title follows conventional commit semantics.
2. Record validation evidence and assess omitted behavior, implementation gaps,
   failing or missing tests, technical debt, missing coverage, weak assertions,
   and assumptions.
3. Fix every high-severity issue or keep the PR in draft. Disclose remaining
   medium- and low-severity findings in the PR body.

Keep documentation URLs canonical under
`https://www.devleader.ca/projects/pitcrew` without trailing slashes.
