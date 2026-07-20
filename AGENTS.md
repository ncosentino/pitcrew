# Agent Instructions

PitCrew orchestrates isolated, ephemeral GitHub Actions runner pools with
PowerShell, Docker Compose, and a POSIX shell manager.

## Repository structure

- `Setup-Runner.ps1` is the operator entry point.
- `RunnerProfiles.Functions.ps1` resolves and validates profile manifests.
- `runner-profile.schema.json` defines the public profile contract.
- `manager/` contains the socket-owning babysitter container.
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
docker compose --file docker-compose.yml config --quiet
python -m mkdocs build --strict
```

Keep documentation URLs canonical under
`https://www.devleader.ca/projects/pitcrew` without trailing slashes.
