---
name: pitcrew-capacity
description: Configure PitCrew worker capacity and autoscaling by invoking Setup-Runner.ps1 and verifying the resulting manager state. Use when the user asks to add, remove, or resize workers, enable or disable autoscaling, or tune the minimum idle count or scale-down delay.
license: MIT
---

# PitCrew Capacity

Change only the requested pool capacity or autoscaling policy through PitCrew's
supported setup script.

Read these shared references before running commands:

- [operations safety](../../references/safety.md)
- [profile replay](../../references/profile-replay.md)

## Workflow

1. Resolve the PitCrew root and selected profile using the profile replay
   reference.
2. Read the current desired, acknowledged, static, and observed state without
   opening any environment or secret file.
3. Classify the request before building a command:
   - A **capacity-only change** modifies repository targets, repository worker
     maximums, or organization/enterprise replicas while preserving the current
     autoscaling policy.
   - An **autoscaling tuning change** changes minimum idle runners or the
     scale-down delay while preserving scale-set mode.
   - An **autoscaling mode migration** enables or disables scale-set mode and
     changes runner registration topology.
4. Translate capacity changes:
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
5. Reject zero or negative configured maximums. An autoscaled profile reaches
   zero active workers through `-MinimumIdle 0`; a zero configured maximum is
   not valid.
6. Translate autoscaling policy changes:
   - Enable with `-Autoscale`.
   - Enable or tune with `-Autoscale -MinimumIdle COUNT
     -ScaleDownDelaySeconds SECONDS`.
   - Disable with `-Autoscale:$false`.
   Preserve the complete repository/replica capacity and every unrelated static
   profile setting.
7. For a capacity-only change:
   - Preserve `-Autoscale`, `-MinimumIdle`, and
     `-ScaleDownDelaySeconds` exactly when the stored profile is autoscaled.
   - Always pass `-CapacityOnly` so a degraded or mismatched profile fails
     instead of falling into replacement.
   - Require the exact profile manager to be running.
8. For an autoscaling tuning change:
   - Pass `-Refresh` and do not pass `-CapacityOnly`.
   - Manager handoff applies the new policy without rebuilding the unchanged
     worker image, so busy jobs do not require a maintenance window.
9. For an autoscaling mode migration:
   - Query matching GitHub runners at the stored repository, organization, or
     enterprise scope using the stored name prefix and profile labels.
   - Stop if any matching runner is busy and check again immediately before the
     migration.
   - Run the selected profile's exact `-Down` command, then replay the complete
     setup command with the new mode. Fixed and scale-set registrations cannot
     coexist under one live manager.
   - If the profile is stopped, require confirmation that the user intends to
     start it as part of the configuration change.
10. Build the complete `Setup-Runner.ps1` invocation with the selected profile,
   stored static configuration, scope, and owner identity. Never pass a token.
11. Before execution, report the exact profile plus the non-secret current and
   requested capacity/autoscaling policy. State whether the manager should
   remain unchanged or be replaced.
12. Capture the selected manager container ID using the exact label
   `ephemeral-runner-manager-profile=<profile>`.
13. Run `Setup-Runner.ps1` from the PitCrew root.
14. Verify:
   - `desired-capacity.json` contains the requested complete capacity.
   - `acknowledged-capacity.json` has the same generation and desired slot
     count.
   - `observed-state.json` reports the accepted generation.
   - Capacity-only: the manager container ID did not change.
   - Autoscaling enabled/tuned: `configuredSlots` and
     `autoscaling.maximumSlots` match the configured maximum,
     `autoscaling.minimumIdleSlots` and `scaleDownDelaySeconds` match the
     requested policy, and status is not degraded.
   - Autoscaling disabled: `autoscaling` is null and fixed desired/active
     capacity begins recovering.

If the observed manager replacement behavior differs from the classified
operation, report that as an unexpected result and stop. Do not attempt broad
Docker cleanup.
