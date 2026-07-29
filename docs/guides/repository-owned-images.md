---
description: Publish repository-owned OCI runner images and roll them through PitCrew without interrupting active jobs.
---

# Repository-Owned Worker Images

PitCrew consumes operator-approved OCI images; it does not own a toolchain
catalog or let workflow input select arbitrary host infrastructure.

## Ownership boundary

The workload repository owns:

- the runner Dockerfile and installed toolchain;
- trusted image validation and GHCR publication;
- the external PitCrew profile manifest;
- workflow routing to the profile label.

The host operator owns:

- registry authentication when the image is private;
- approval of the immutable image digest;
- profile installation, update, and rollback;
- capacity and resource policy.

## Publish the image

Build on trusted infrastructure and publish an immutable manifest digest:

```text
ghcr.io/example/project-runner@sha256:<manifest-digest>
```

Pull requests may build and test the image, but should not publish a deployable
tag. Never place source credentials, package credentials, registration tokens,
or generated workload output in an image layer.

## Commit an external profile

```json
{
  "schemaVersion": 1,
  "name": "project-ci",
  "description": "Repository-owned CI workers.",
  "image": "ghcr.io/example/project-runner@sha256:<manifest-digest>",
  "labels": ["project"],
  "replicas": 2,
  "pullImage": true,
  "disableDefaultLabels": true,
  "verificationCommands": [
    "test -x /actions-runner/bin/Runner.Listener",
    "tool --version"
  ]
}
```

PitCrew records the manifest source, content hash, and non-secret document in
local static state. This provenance lets release-update tooling replay the
approved profile instead of silently applying later source changes.

## Install and route

Apply the complete profile command with the approved targets and capacity:

```powershell
.\Setup-Runner.ps1 `
    -ProfilePath C:\profiles\project-ci\profile.json `
    -Repos https://github.com/example/project=2
```

The workflow requests the profile name:

```yaml
jobs:
  build:
    runs-on: [linux, x64, project-ci]
```

GitHub must choose a registered runner before workflow steps execute. A workflow
therefore selects a profile label, not an OCI image reference.

## Update the image

1. Review and merge the Dockerfile change.
2. Publish a new immutable image digest.
3. Review and merge the profile digest change.
4. Run `pitcrew-profile-rollout` for one host and profile.
5. Confirm the target image ID and worker revision.
6. Treat `update.status: rolling` as a successful partial rollout.
7. Update remaining hosts after the first host is healthy.

Setup prepares and verifies the candidate before manager handoff. Scale-set
profiles replace stale idle workers and retain assigned workers. Fixed profiles
let existing ephemeral workers finish and naturally turn over.

## Roll back

Restore the prior manifest digest and replay the complete profile command. Do
not use `-Refresh`, `-CapacityOnly`, Compose teardown, or a Docker restart for a
worker-image rollback.

The local static profile retains the prior approved manifest evidence needed to
construct an explicit rollback plan. Never let a repository workflow activate
or roll back host infrastructure automatically.
