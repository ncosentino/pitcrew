---
name: pitcrew-host-diagnostics
description: Collect non-destructive, redacted evidence about a degraded PitCrew runner host, including exact image references, labelled container resource usage, disk and network counters, and host-versus-container URL timings. Use when the user asks why a runner host, profile, or worker is slow, stalled, or degraded.
license: MIT
---

# PitCrew Host Diagnostics

Collect evidence only. This skill never changes host, Docker, manager, or
worker state, and it never waits for a maintenance window.

Read these shared references before running commands:

- [operations safety](../../references/safety.md)
- [profile replay](../../references/profile-replay.md)

## Non-negotiable boundaries

- Never restart Docker, Docker Desktop, the Docker daemon, the host, a manager,
  or a worker.
- Never stop, kill, restart, pause, or remove a manager or worker container.
- Never run `docker system prune`, any other prune, or name-based cleanup.
- Never enter a running worker with `docker exec` or `docker attach`; a worker
  is executing customer jobs.
- Never display `.env`, `.env.*`, tokens, connector identities, JIT
  configuration, runner registration payloads, or job output.
- Every Docker query and the single cleanup must be scoped by exact PitCrew
  labels or by an exact container ID this skill created.
- Stop and ask when installation or profile identity is ambiguous.

## Dry-run mode

Default to dry run when the user asks what the skill would collect, or when the
host is in a sensitive state. In dry run:

1. Resolve identity and read non-secret state only.
2. Print every command that would run, in order, with fully resolved profile,
   labels, image references, URLs, and container name.
3. Create no container, download nothing, and change nothing.
4. Label the report `mode: dry-run` and mark every measurement as
   `not-collected`.

Run the collection only after the user approves the printed plan.

## Identity resolution

1. Resolve the PitCrew root and the selected profile with the profile replay
   reference. Stop when more than one profile matches and none was named.
2. Read only the generated non-secret state:
   - `.pitcrew-state/<profile>/desired-capacity.json`
   - `.pitcrew-state/<profile>/acknowledged-capacity.json`
   - `.pitcrew-state/<profile>/static-profile.json`
   - `.pitcrew-state/<profile>/observed-state.json`
3. Never open an environment or token file, including with a filtered command.
4. Record the desired generation, the acknowledged generation, the observed
   generation, `managerStatus`, and observed-state freshness.

## Exact identity of the running images

Resolve the exact references before any resource query:

- manager image reference from the running manager container
- worker image reference from `static-profile.json.configuration`

```text
docker ps --filter "label=ephemeral-runner-manager-profile=<profile>" --format "{{.ID}} {{.Image}}"
docker image inspect <reference> --format "{{.Id}} {{json .RepoDigests}}"
```

Report the reference, the resolved local image ID, and the repository digests.
When an image is not present locally, report it as unavailable; never pull it
during diagnostics.

## Container resource evidence

Use exact PitCrew labels for every selection:

- manager: `ephemeral-runner-manager-profile=<profile>`
- workers: `ephemeral-managed-runner-profile=<profile>`
- worker slot: `ephemeral-managed-runner-slot`
- worker revision: `pitcrew-worker-revision`

```text
docker ps --filter "label=ephemeral-managed-runner-profile=<profile>" --format "{{.ID}} {{.Image}} {{.Status}}"
docker stats --no-stream --format "{{.Container}} {{.CPUPerc}} {{.MemUsage}} {{.PIDs}} {{.NetIO}} {{.BlockIO}}" <exact-ids>
```

`docker stats --no-stream` is bounded and must be passed the exact container IDs
returned by the label filters. Never run `docker stats` without `--no-stream`
and never run it across every container on the host. If the command exceeds a
short timeout or returns no row for a container, report that container's usage
as unavailable.

## Host capacity evidence

Collect, and mark each item unavailable when the platform or command does not
support it:

```text
docker system df
docker info --format "{{.DockerRootDir}} {{.OperatingSystem}} {{.ServerVersion}}"
docker network ls --format "{{.ID}}"
```

Use `docker network ls` for a network count only; do not inspect, create, or
remove a network.

Free space, inodes, and adapter counters are platform specific:

| Evidence | Linux | Windows |
| --- | --- | --- |
| Free space | `df -P <docker-root>` | `Get-PSDrive -PSProvider FileSystem` |
| Inodes | `df -Pi <docker-root>` | unavailable (NTFS has no inode budget) |
| Adapter errors and drops | `cat /proc/net/dev` | `Get-NetAdapterStatistics` |

Select commands from the actual runner host platform, not from the agent's own
platform. All three are read-only. `Get-NetAdapterStatistics` reports received
and sent discards and errors; report the measurement as unavailable when the
module or cmdlet is missing rather than substituting a write-capable
alternative.

Never fabricate, estimate, or interpolate an unsupported measurement.

## URL timing comparison

1. Use only URLs the caller explicitly approved for this run. Never invent a
   URL, reuse a URL from a previous session, or derive one from job output.
2. Validate each URL before use:
   - the scheme is `http` or `https`
   - there are no embedded credentials (`user:password@`)
   - there is no query string, token, or signature material
   - the host is a literal hostname or address, not a shell expansion
   Stop and ask when validation fails.
3. Time each URL from the host, discarding the body:

   ```text
   curl --silent --show-error --location --max-time 30 --output /dev/null --write-out "%{http_code} %{time_namelookup} %{time_connect} %{time_starttransfer} %{time_total} %{size_download} %{speed_download}\n" <url>
   ```

   On Windows use `curl.exe` with the same arguments and `--output NUL`. When
   `curl.exe` is unavailable, use `Invoke-WebRequest -UseBasicParsing` with a
   discarded response body and report the reduced timing detail.
4. Time the same URLs from exactly one disposable container built from the
   profile's exact worker image:

   ```text
   docker run --rm --name pitcrew-diagnostics-<profile>-<timestamp> --label pitcrew-diagnostics-session=<session-id> <exact-worker-image> <the same curl command>
   ```

   The disposable container never mounts the Docker socket, never mounts a host
   path, and never receives PitCrew credentials or registration input.
5. Persist nothing that was downloaded. Bodies always go to `/dev/null` or
   `NUL`; never use `--output <file>`, `--remote-name`, or a bind mount.
6. Compare host and container results per URL: HTTP status, DNS, connect, first
   byte, total time, and throughput. Report the delta and whether the
   difference points at the host, Docker networking, or the upstream endpoint.

## Cleanup

- `docker run --rm` removes the disposable container on exit.
- Capture the container name and ID at creation. If it survives, remove exactly
  that ID after confirming it carries `pitcrew-diagnostics-session=<session-id>`:

  ```text
  docker rm --force <exact-diagnostic-container-id>
  ```

- Remove nothing else. Never clean up by name pattern, never remove untagged
  images, and never touch a container carrying a PitCrew manager or worker
  label.

## Handoff report

Emit a redacted Markdown summary plus a JSON document carrying the same values,
and state that it can be attached to `ncosentino/pitcrew#8`.

Redact before emitting:

- absolute host paths, replaced with `<pitcrew-root>`
- user names, machine names, and internal host names that are not required
- any URL query string
- everything sourced from an environment file, token, connector identity, JIT
  configuration, or job output, which must never be collected in the first
  place

Structure the report in three explicitly separated sections:

1. **Verified measurements** — collected values with the exact command used.
2. **Unavailable evidence** — each measurement that the platform, permission
   level, or timeout prevented, with the reason.
3. **Hypotheses** — ranked, clearly labelled as unverified, each with the
   non-destructive follow-up that would confirm it.

Never present a hypothesis as a measurement, and never fill a gap in the
unavailable section with an estimate. Recommend remediation as a proposal for
the operator; this skill does not apply it.
