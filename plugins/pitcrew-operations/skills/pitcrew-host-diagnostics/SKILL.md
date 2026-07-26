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
   labels, image references, URLs, probe timeout, and container name.
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

## Capacity reconciliation evidence

Count what is actually running and compare it with what each layer believes.

1. Count live workers per target from exact labels, using the slot label to
   attribute each container to its target:

   ```text
   docker ps --filter "label=ephemeral-managed-runner-profile=<profile>" --format "{{.ID}} {{.Label \"ephemeral-managed-runner-slot\"}} {{.Label \"pitcrew-worker-revision\"}}"
   ```

2. Build a per-target table comparing, for every repository or scale set:
   - live worker containers counted above
   - desired workers in `desired-capacity.json`
   - acknowledged workers in `acknowledged-capacity.json`
   - observed slots in `observed-state.json`, including per-slot `repository`
     and `state`
   - scale-set statistics already present in observed state
     (`autoscaling.targetSlots`, `maximumSlots`, `minimumIdleSlots`,
     `idleRunners`, `busyRunners`, `assignedJobs`, `runningJobs`,
     `availableJobs`, `status`, `lastError`)
3. Report `observedAt` freshness alongside those counts. Stale observed state
   makes every registered count an unverified reading, not a measurement.
4. A live-versus-registered mismatch (for example `2 live / 0 registered` or
   `2 live / 8 registered`) is decisive evidence. Report it verbatim per target.
5. Never make a credentialed GitHub API query to fill a gap. When registered
   counts or scale-set statistics are missing from observed state, report the
   missing evidence explicitly and name the non-destructive follow-up that
   would supply it.

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

### Paired snapshots and deltas

`NetIO`, `BlockIO`, adapter counters, and disk accounting are cumulative, so a
single snapshot cannot attribute pressure to the URL probe or to the active
workload. Take a complete snapshot immediately before the URL probes and a
second immediately after, then report both absolute values and the delta:

- per container: `NetIO` and `BlockIO` delta, plus CPU, memory, and PID values
  at each snapshot
- host: adapter error and drop counter deltas
- Docker: `docker system df` delta for images, containers, and build cache

Record the wall-clock timestamp of each snapshot so the delta has a known
window. When either snapshot is unavailable for a container, report the delta as
unavailable instead of treating the missing side as zero.

### Per-worker writable layer

Multi-gigabyte container layers can exhaust an overlay filesystem while the host
still reports abundant free space, so measure the writable layer per worker
using exact IDs only:

```text
docker ps --size --filter "label=ephemeral-managed-runner-profile=<profile>" --format "{{.ID}} {{.Size}}"
docker inspect --size <exact-container-id> --format "{{.Id}} {{.SizeRw}} {{.SizeRootFs}}"
```

Report `SizeRw` per worker and the profile total. Include `SizeRootFs` only when
the same exact-ID inspection returns it; never inspect every container on the
host to obtain it, and never estimate a layer size.

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
3. Agree the probe timeout with the caller before probing. Use a finite
   caller-approved bound with a default of 300 seconds. Never hard-code a short
   bound such as 30 seconds: a large artifact can legitimately take minutes, and
   a truncated probe discards the decisive measurement.
   - When a probe hits the bound, report it as `timed-out` partial evidence with
     the bytes transferred and elapsed time observed so far.
   - Never record a timed-out probe as zero throughput, as a generic failure, or
     as a successful comparison.
4. Take the "before" resource snapshot, then time each URL from the host,
   discarding the body:

   ```text
   curl --silent --show-error --location --max-time <probe-timeout-seconds> --output /dev/null --write-out "%{http_code} %{remote_ip} %{time_namelookup} %{time_connect} %{time_appconnect} %{time_starttransfer} %{time_total} %{size_download} %{speed_download}\n" <url>
   ```

   `%{remote_ip}` identifies the selected CDN edge and `%{time_appconnect}`
   isolates TLS handshake cost, so a one-off edge selection is not misread as a
   Docker networking fault.

   On Windows use `curl.exe` with the same arguments and `--output NUL`. When
   `curl.exe` is unavailable, use `Invoke-WebRequest -UseBasicParsing` with a
   discarded response body and report the reduced timing detail.
5. Time the same URLs from exactly one disposable container built from the
   profile's exact worker image. Prove the container identity client-side with
   `--cidfile` so cleanup can verify an exact ID:

   ```text
   docker run --rm --cidfile <run-scoped-cidfile> --name pitcrew-diagnostics-<profile>-<timestamp> --label pitcrew-diagnostics-session=<session-id> <exact-worker-image> <the same curl command>
   ```

   When `--cidfile` is unavailable, use an explicit
   `docker create` → capture the printed ID → `docker start --attach` →
   `docker rm <exact-id>` flow instead. Never infer the container identity from
   a name pattern or from `docker ps` output filtered by name.

   The disposable container never mounts the Docker socket, never mounts a host
   path, and never receives PitCrew credentials or registration input.
6. Persist nothing that was downloaded. Bodies always go to `/dev/null` or
   `NUL`; never use `--output <file>`, `--remote-name`, or a bind mount.
7. Take the "after" resource snapshot immediately once the probes finish.
8. Compare host and container results per URL: HTTP status, remote IP, DNS,
   connect, TLS, first byte, total time, throughput, and bytes transferred.
   Report the delta together with the probe-window resource deltas and the live
   worker counts observed during the probe.

## Cleanup

- `docker run --rm` removes the disposable container on exit.
- Read the exact container ID from the `--cidfile`, or from the `docker create`
  output when the create/start flow was used. If the container survives, confirm
  that exact ID still carries `pitcrew-diagnostics-session=<session-id>` before
  removing it:

  ```text
  docker inspect <exact-diagnostic-container-id> --format "{{index .Config.Labels \"pitcrew-diagnostics-session\"}}"
  docker rm --force <exact-diagnostic-container-id>
  ```

- Delete the run-scoped cidfile afterwards. It contains no secret, but it must
  not be reused by a later session.
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
unavailable section with an estimate.

A single host-versus-container pair never establishes a root cause. One pair is
one sample taken under one host load, against one CDN edge, over one path. Keep
these as competing hypotheses until repeated measurements resolve them:

- CDN edge and route variability, evidenced by differing `%{remote_ip}` or
  `%{time_appconnect}` between the two probes
- load-sensitive host contention, evidenced by the probe-window resource deltas
  and the live worker counts at each snapshot
- host-specific network stack or filesystem behaviour, evidenced by adapter
  error and drop deltas and writable-layer growth
- a genuine Docker networking difference

Report which hypotheses the collected evidence weakens and which remain open.
When the container and host results differ substantially, state explicitly that
the run is a single paired sample and name the repeat measurement — same URLs,
same probe timeout, same worker image, under a stated worker load — that would
separate the remaining hypotheses.

Recommend remediation as a proposal for the operator; this skill does not apply
it.
