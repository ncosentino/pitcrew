---
description: Run independent general-purpose and specialized GitHub Actions runner pools on one Docker host.
---

# Named Profiles

Named profiles let one host run several isolated worker pools without
duplicating the manager implementation.

## Start the general-purpose pool

Provision the implicit `default` profile for routine build and test work:

```powershell
.\Setup-Runner.ps1 `
    -Repos https://github.com/you/project-a=3,https://github.com/you/project-c=4
```

The default profile retains GitHub's default labels and adds
`general-purpose`.

## Start a specialized pool

Provision a separate Copilot CLI pool for evaluation workloads:

```powershell
.\Setup-Runner.ps1 `
    -Profile copilot-cli `
    -Repos https://github.com/you/project-b=2,https://github.com/you/project-c=2
```

PitCrew assigns a distinct Compose project, manager, environment file, image,
runner-name prefix, routing label, and cleanup label to the named profile.

## Change one profile

Re-running setup converges only the selected profile:

```powershell
.\Setup-Runner.ps1 `
    -Profile copilot-cli `
    -Repos https://github.com/you/project-b=4,https://github.com/you/project-c=2
```

The general-purpose pool stays online while the specialized pool is replaced.

## Stop one profile

Stop a named profile without affecting the other managers:

```powershell
.\Setup-Runner.ps1 -Profile copilot-cli -Down
```

Stop the default pool separately:

```powershell
.\Setup-Runner.ps1 -Down
```

## Share capacity across repositories

Repository-scoped workers cannot accept jobs from another repository. Use
organization or enterprise scope for shared capacity:

```powershell
.\Setup-Runner.ps1 `
    -Profile copilot-cli `
    -Scope org `
    -OrgName your-organization `
    -Replicas 4
```
