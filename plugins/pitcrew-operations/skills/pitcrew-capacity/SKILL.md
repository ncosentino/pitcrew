---
name: pitcrew-capacity
description: Add, remove, or resize workers in an existing PitCrew runner pool by invoking Setup-Runner.ps1 and verifying capacity acknowledgement. Use when the user asks to change PitCrew worker counts or repository targets.
license: MIT
---

# PitCrew Capacity

Change only the requested pool capacity through PitCrew's supported setup
script.

Read these shared references before running commands:

- [operations safety](../../references/safety.md)
- [profile replay](../../references/profile-replay.md)

## Workflow

1. Resolve the PitCrew root and selected profile using the profile replay
   reference.
2. Read the current desired, acknowledged, static, and observed state without
   opening any environment or secret file.
3. Translate the request:
   - Add a repository or change its worker count with
     `-AddRepos https://github.com/OWNER/REPOSITORY=COUNT`.
     Always include `=COUNT`; omitting it can replace an existing repository's
     count with the profile default.
   - Remove a repository target with
     `-RemoveRepos https://github.com/OWNER/REPOSITORY`.
   - Change organization capacity with `-Scope org -OrgName NAME -Replicas
     COUNT`.
   - Change enterprise capacity with `-Scope ent -EnterpriseName NAME
     -Replicas COUNT`.
4. Reject zero or negative counts. PitCrew does not support a zero-capacity
   repository profile; removing the final repository is not a substitute for a
   graceful scale-to-zero feature.
5. Build the complete `Setup-Runner.ps1` invocation with the selected profile
   and its stored static configuration, including scope and owner identity. Do
   not pass `-Refresh`, `-Down`, or a token. Always pass `-CapacityOnly` so a
   degraded or mismatched profile fails instead of falling into replacement.
6. Before execution, report the non-secret current and requested capacity plus
   the exact profile being changed.
7. Capture the selected manager container ID using the exact label
   `ephemeral-runner-manager-profile=<profile>`.
   If no matching manager is running, stop before invoking setup.
8. Run `Setup-Runner.ps1` from the PitCrew root.
9. Verify:
   - `desired-capacity.json` contains the requested complete capacity.
   - `acknowledged-capacity.json` has the same generation and desired slot
     count.
   - `observed-state.json` reports the accepted generation.
   - The manager container ID did not change for a capacity-only update.

If setup replaces the manager or changes unrelated static configuration, report
that as an unexpected result and stop. Do not attempt broad Docker cleanup.
