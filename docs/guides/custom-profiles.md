---
description: Create a PitCrew profile with a dedicated runner image, capability labels, and runtime verification.
---

# Custom Profiles

A custom profile describes one specialized GitHub Actions worker pool.

## Create the manifest

Create `profile.json` beside the profile's Dockerfile:

```json
{
  "$schema": "../../runner-profile.schema.json",
  "schemaVersion": 1,
  "name": "browser-testing",
  "description": "Pinned browser-testing workers.",
  "image": "pitcrew-browser-testing:local",
  "labels": ["browser"],
  "replicas": 2,
  "pullImage": false,
  "disableDefaultLabels": true,
  "build": {
    "context": ".",
    "dockerfile": "Dockerfile",
    "args": {
      "BROWSER_VERSION": "123.0.0"
    }
  },
  "verificationCommands": [
    "browser --version"
  ]
}
```

Use `-ProfilePath` when the manifest is outside PitCrew's built-in
`profiles/<name>/` directory.

## Build the image

When a manifest defines `build`, PitCrew builds the image before replacing the
live profile. Build arguments are restricted to non-secret configuration.

Never place tokens, passwords, API keys, or private keys in a profile manifest
or Docker build. Inject workload credentials through the GitHub Actions job.

## Verify the image

Use `verificationCommands` to assert stable executable paths and pinned
versions. PitCrew runs every command against the prepared image before stopping
the current profile.

If verification fails, the existing profile remains online.

## Route jobs to the profile

Every named profile receives its profile name as a mandatory label:

```yaml
jobs:
  browser-tests:
    runs-on: [linux, x64, browser-testing]
```

Keep `disableDefaultLabels` enabled unless broad `self-hosted` jobs are
intentionally allowed to consume the profile.
