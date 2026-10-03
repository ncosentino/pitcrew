---
description: Attach operator-provisioned Docker named volumes to ephemeral workers as bounded read-only or read-write data mounts.
---

# External Data Volumes

Some workloads require large immutable reference data that should remain
outside runner images and disposable worker layers. PitCrew can attach an
existing Docker named volume to every worker of one approved profile.

PitCrew does not create, populate, modify, inspect driver options for, or remove
external data volumes. Storage mounting and authentication remain entirely
operator-owned.

## Provision the volume

Create the named volume before applying the profile. For example, an
operator-managed read-only NFS volume can be created with:

```powershell
docker volume create `
    --driver local `
    --opt type=nfs `
    --opt "o=addr=STORAGE_HOST,ro,nfsvers=4" `
    --opt "device=:/export/reference-data/v1" `
    pitcrew-reference-data-v1
```

Do not place usernames, passwords, tokens, or private storage addresses in a
tracked profile manifest. PitCrew only receives the resulting external volume
name.

## Declare the logical mount

```json
{
  "schemaVersion": 1,
  "name": "reference-tests",
  "description": "Workers with immutable reference data.",
  "image": "ghcr.io/example/reference-runner@sha256:<digest>",
  "labels": ["reference-tests"],
  "replicas": 1,
  "pullImage": true,
  "disableDefaultLabels": true,
  "readOnlyVolumes": [
    {
      "name": "reference-data",
      "source": "pitcrew-reference-data-v1"
    }
  ],
  "verificationCommands": [
    "test -f /mnt/pitcrew-data/reference-data/manifest.json"
  ]
}
```

PitCrew derives `/mnt/pitcrew-data/reference-data` from the logical name.
Profiles cannot select arbitrary container paths, bind host paths, devices, or
sockets. Read-only mounts use `readonly` and `volume-nocopy`.
Both lists together allow at most eight entries. Logical names and Docker source
volume names must be unique across the combined lists.

## Writable shared data

Trusted producer jobs can declare `readWriteVolumes` with the same entry shape:

```json
{
  "readWriteVolumes": [
    {
      "name": "handoff",
      "source": "pitcrew-build-handoff-rw"
    }
  ],
  "verificationCommands": [
    "probe=$(mktemp /mnt/pitcrew-data/handoff/probe.XXXXXX) && printf verified > \"$probe\" && test \"$(cat \"$probe\")\" = verified && rm \"$probe\""
  ]
}
```

This is a fragment to add to a complete profile. Provision the writable volume
first, using operator-reviewed storage settings, for example:

```powershell
docker volume create `
    --driver local `
    --opt type=nfs `
    --opt "o=addr=STORAGE_HOST,rw,nfsvers=4.1" `
    --opt "device=:/export/build-handoff" `
    pitcrew-build-handoff-rw
```

Writable mounts use `volume-nocopy` without `readonly`. They are deliberate
shared persistent state between all jobs of that profile, not disposable worker
storage. Route only trusted workflows to that profile, and use a dedicated
profile when other repositories must not receive the mount. Access mode belongs
to the reviewed profile; a workflow cannot override it.

A separate consumer profile can mount an operator-provisioned read-only volume
backed by the same storage. Enforce read-only access in its storage options as
well as the container mount. Use run-and-attempt-specific directories and verify
published file hashes before consumption. The producer or another explicitly
authorized writer owns cleanup: a read-only consumer cannot delete files.

## Apply and route

Use the complete external-profile command:

```powershell
.\Setup-Runner.ps1 `
    -ProfilePath C:\profiles\reference-tests\profile.json `
    -Repos https://github.com/example/project=1
```

Setup inspects the exact named volume before changing the manager and attaches
it to every image-verification container with the declared access mode. A missing volume or failed data
verification leaves the running profile unchanged.

Workflows request the profile label, not the volume:

```yaml
jobs:
  reference-tests:
    runs-on: [linux, x64, reference-tests]
```

## Update or roll back

1. Provision and verify a new external volume.
2. Review the profile source-volume change.
3. Apply it with `pitcrew-profile-rollout`.
4. Treat `update.status: rolling` as successful partial convergence.
5. Keep the previous volume until every required check accepts the new data.

Adding or removing writable mounts, changing their source, or changing access
mode advances the worker revision without changing routing or capacity.

Busy workers retain their original volume until their one job finishes. New
workers use the target volume. Roll back by restoring the previous source
volume name and replaying the complete profile command.

Never use `-Refresh`, `-CapacityOnly`, Compose teardown, or a Docker restart to
change the worker data mount.
