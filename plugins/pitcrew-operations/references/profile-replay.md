# Replaying a PitCrew Profile Safely

Use this reference whenever `Setup-Runner.ps1` must operate on an existing
profile.

## Locate the profile

The PitCrew root must contain:

- `Setup-Runner.ps1`
- `RunnerProfiles.Functions.ps1`
- `docker-compose.yml`
- `.pitcrew-state/<profile>/`

Use the profile named by the user. When no profile is named, enumerate the
directories immediately below `.pitcrew-state`. Continue automatically only
when exactly one configured profile exists.

## Read only non-secret state

Read:

- `.pitcrew-state/<profile>/desired-capacity.json`
- `.pitcrew-state/<profile>/static-profile.json`
- `.pitcrew-state/<profile>/acknowledged-capacity.json`
- `.pitcrew-state/<profile>/observed-state.json`

Do not read an environment file with a content-viewing tool. `Setup-Runner.ps1`
reuses the selected profile's stored `ACCESS_TOKEN` when `-Token` is omitted, so
the agent never needs to extract or print that secret.

## Preserve static configuration

Use `static-profile.json.configuration` to preserve:

- scope, organization, or enterprise identity
- image and pull behavior
- labels
- runner group
- runner name prefix
- autoscaling mode, minimum idle runners, and scale-down delay

For the default profile, use `-Profile default`. For a built-in named profile,
use `-Profile <name>` and confirm `profiles/<name>/profile.json` exists.

When the stored configuration contains a build or verification contract that
cannot be traced to a built-in manifest, require the external `-ProfilePath`
from the user. Do not reconstruct or omit an unknown external profile contract.

Pass stored command-line overrides when they differ from the selected manifest.
Do not change static settings during a capacity-only operation.

## Preserve desired capacity

For repository scope, preserve every current repository URL and worker count
unless the requested operation changes it. For organization or enterprise
scope, preserve the current replica count unless the user requested a new one.

Always invoke `Setup-Runner.ps1` from the PitCrew root. Never edit generated
capacity or acknowledgement JSON directly.
