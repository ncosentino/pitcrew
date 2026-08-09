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
- host-admission namespace, host capacity, safety margin, worker cost,
  reservation, and borrowing policy
- operator-approved read-only external volume names and sources
- the operator-approved external service-network source

For the default profile, use `-Profile default`. For a built-in named profile,
use `-Profile <name>` and confirm `profiles/<name>/profile.json` exists.

For a static-profile document with `manifest.kind: external`, use its
`sourcePath`, `sha256`, and non-secret `document` together:

1. If the source file still exists and its SHA-256 matches the stored hash, use
   that exact path.
2. If the source changed but its parent directory still exists, never apply the
   unapproved new content during a PitCrew release update. Serialize the stored
   document to a run-scoped temporary manifest beside the original source so
   relative build paths retain their meaning, use that exact temporary path,
   then delete only that exact file.
3. If the source directory no longer exists, stop. Do not relocate a local
   build context or reconstruct an external contract from effective fields.

Legacy static-profile documents without manifest provenance still require the
external `-ProfilePath` from the user. Do not reconstruct or omit an unknown
external profile contract.

Pass stored command-line overrides when they differ from the selected manifest.
Do not change static settings during a capacity-only operation.

Host admission is manifest-only static policy. Never reconstruct it from an
environment file, edit generated desired policy or lease state, or start the
coordinator with Docker commands. A profile-local policy change requires the
reviewed manifest and complete setup command. A namespace change requires every
participant to pause, drain, and leave the old namespace through
`Setup-Runner.ps1 -Down`. A host-capacity or safety-margin change requires all
other participants to drain and leave the old common policy before the
remaining profile is updated, or a full namespace teardown when the operator
prefers the simpler rollback boundary.

Before disabling or rolling back host admission, require zero active,
provisional, and held units for the profile. Existing workers survive
coordinator failure, but new admission stops. `-RecoverManager` repairs only a
manager; coordinator recovery uses the complete current profile command with
`-Refresh`.

## Preserve desired capacity

For repository scope, preserve every current repository URL and worker count
unless the requested operation changes it. For organization or enterprise
scope, preserve the current replica count unless the user requested a new one.

Always invoke `Setup-Runner.ps1` from the PitCrew root. Never edit generated
capacity or acknowledgement JSON directly.
