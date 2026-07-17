---
description: Reference every PitCrew setup parameter, runner-profile field, generated state value, and default.
---

# Configuration

`Setup-Runner.ps1` is the operator entry point. Each invocation converges one
profile without changing other profiles on the same host.

## Setup parameters

| Parameter | Required | Description | Default |
|-----------|----------|-------------|---------|
| `-Token` | No | Fine-grained PAT used only to register runners. When omitted, PitCrew uses `gh auth token`. | Authenticated `gh` token |
| `-Profile` | No | Built-in profile name. | `default` |
| `-ProfilePath` | No | Path to an external profile manifest. Relative image-build paths resolve from the manifest directory. | None |
| `-Scope` | No | GitHub runner scope: `repo`, `org`, or `ent`. | `repo` |
| `-Repos` | Repository scope | Repository URLs, optionally followed by `=workers`. | None |
| `-AddRepos` | No | Adds repositories to the selected profile's generated state. | None |
| `-RemoveRepos` | No | Removes repositories from the selected profile's generated state. | None |
| `-OrgName` | Organization scope | GitHub organization name. | None |
| `-EnterpriseName` | Enterprise scope | GitHub enterprise name. | None |
| `-Replicas` | No | Default workers per repository, or total workers for organization/enterprise scope. `0` auto-sizes to half the host processors with a minimum of two. | Profile value |
| `-Labels` | No | Comma-separated custom labels. The mandatory profile label remains. | Profile value |
| `-NamePrefix` | No | Prefix shown for runner registrations in GitHub. | Host name plus profile |
| `-Image` | No | Overrides the profile's worker image. | Profile value |
| `-PullImage` | No | Controls whether setup pulls a prebuilt image before verification. | Profile value |
| `-RunnerGroup` | No | Organization or enterprise runner group. | Profile value |
| `-Down` | No | Stops only the selected profile and removes its managed workers. | Off |

## Repository worker counts

Repository scope supports a different count for every target:

```powershell
.\Setup-Runner.ps1 -Repos `
    https://github.com/you/light-project=1,`
    https://github.com/you/heavy-project=6
```

These workers are dedicated to their repositories. Use organization or
enterprise scope when several repositories should share one capacity pool.

## Profile manifest

Named profiles conform to
[`runner-profile.schema.json`](https://github.com/ncosentino/pitcrew/blob/main/runner-profile.schema.json).

| Field | Required | Description |
|-------|----------|-------------|
| `schemaVersion` | Yes | Manifest contract version. Version `1` is currently supported. |
| `name` | Yes | Lowercase profile identifier and mandatory routing label. |
| `description` | Yes | Human-readable purpose. |
| `image` | Yes | Worker image tag. |
| `labels` | Yes | Additional capability labels. |
| `replicas` | Yes | Default positive worker count. |
| `pullImage` | No | Pull a prebuilt image before verification. |
| `disableDefaultLabels` | No | Omit GitHub's broad default labels. Named profiles default to `true`. |
| `runnerGroup` | No | Organization or enterprise runner group. |
| `verificationCommands` | No | Shell commands executed in the prepared image before profile replacement. |
| `build` | No | Local Docker build context, Dockerfile, and non-secret build arguments. |

## Generated state

The default profile writes `.env`; named profiles write `.env.<profile>`. These
static environment files contain the runner-registration token plus image,
labels, scope, runner group, and name-prefix settings. PitCrew generates them
and Git ignores them. Do not edit or commit them.

Mutable capacity is stored separately under
`.pitcrew-state/<profile>/desired-capacity.json`. The document contains no
registration token or workload credential. Setup validates the complete next
document, writes it through a temporary file and atomic rename, and waits for
the running manager to acknowledge its generation.

For repository scope, desired state records each repository URL and worker
count. Organization and enterprise scope record one shared replica count. The
manager derives stable ordinal slot keys, so changing a repository from five
workers to six starts only ordinal six. Changing it back to five drains only
ordinal six.

## Capacity reconciliation

When the static profile fingerprint is unchanged and the manager is running,
setup skips image pull/build and verification, leaves the manager container
untouched, and publishes only desired capacity. Reapplying identical capacity
is a no-op.

Scale-down is graceful:

- A runner already executing a job is never force-removed because capacity
  decreased.
- Once the draining runner container exits, its slot stops instead of spawning
  a replacement.
- An idle ephemeral runner can accept one final job before it exits. PitCrew
  does not query GitHub's runner `busy` state in this reconciliation path.

Changes to image, labels, default-label behavior, scope, organization or
enterprise identity, runner group, name prefix, registration token, build or
verification contract, or manager runtime contract continue to replace the
selected profile.

## Legacy and direct Compose bootstrap

When neither desired nor last-valid state exists, the manager can import
`REPO_URLS` or `REPO_URL` for repository scope, or `RUNNER_REPLICAS` for
organization and enterprise scope. This is a one-time adapter for
pre-reconciliation `.env` files and direct `docker compose up` usage.

After the adapter creates generation one, environment changes do not alter
capacity. Use `Setup-Runner.ps1` for every subsequent update so generation,
locking, atomic publication, and acknowledgement remain enforced.

The mounted directory contains no credentials. If Docker creates a missing bind
source as root, the manager makes that directory host-writable so a later setup
command can replace state atomically. Pre-create the directory when stricter
host ownership is required.

On the first setup run after upgrading, `-AddRepos` and `-RemoveRepos` import
repository targets from the old profile environment when desired state has not
been created yet.
