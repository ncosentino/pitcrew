---
description: Understand PitCrew's Docker socket, credential, workflow-trigger, and public-repository trust boundaries.
---

# Security Boundaries

PitCrew reduces worker persistence, but self-hosted GitHub Actions runners still
execute repository-controlled code on infrastructure you own.

## Protect the Docker host

The manager mounts `/var/run/docker.sock` so it can create and remove sibling
worker containers. Docker socket access is effectively host-level control.

Run only the committed PitCrew manager on a dedicated host and restrict access
to the machine.

The manager also mounts the Docker host's `/proc` read-only at `/host/proc` to
collect aggregate pressure. On Docker Desktop this is the Linux VM that runs
containers. PitCrew reads only aggregate CPU, load, memory, swap, and PSI files;
it does not publish process IDs, command lines, environment values, or mount
paths. Workers receive neither the Docker socket nor the host-proc mount.

## Keep workers socketless

Worker containers never receive the host Docker socket. Workflows therefore
cannot control the host daemon, but they also cannot use Docker builds,
container actions, service containers, or Testcontainers.

Do not restore host socket access as a convenience. Use a separate disposable
VM or isolated daemon for Docker-dependent workloads.

## Bound specialized container capabilities

Profiles may opt into only two bounded runtime extensions: the typed KVM device and a
canonical shared-memory size. Setup verifies them before manager replacement, and
both managers render the same fixed Docker arguments.

The contract does not accept arbitrary device paths, Linux capabilities, seccomp
settings, blanket privilege, bind mounts, or Docker endpoints. KVM still increases
the host-kernel attack surface, so use it only for trusted workflows under a
dedicated profile label.

Image-building workers use an mTLS rootless BuildKit service through a profile service
network. The service runs without `--privileged`, host ports, or the Docker socket and
uses only the reviewed rootless security options. A worker without the approved
client identity must be rejected.

## Protect registration credentials

PitCrew writes the runner-registration token to `.env` or `.env.<profile>`.
Those files are gitignored and registration variables are removed before
workflow steps begin.

In scale-set mode, the administration token remains in the manager. Each worker
receives only a one-time JIT configuration for its ephemeral registration.
Treat that configuration as secret until the worker consumes it; Docker
administrators can inspect container configuration.

Use the minimum GitHub permissions required for the selected runner scope.

## Keep workload secrets in GitHub

Profile manifests and Docker builds accept only non-secret configuration.
Inject API keys and service credentials through the specific GitHub Actions job
that needs them.

Never bake credentials into a runner image.

## Bound hardware inventory

Managers publish a sanitized hardware inventory for cross-node diagnostics.
It includes processor and core topology when observable, Docker-visible memory,
OS/kernel identity, and Docker storage/runtime versions.

PitCrew never publishes usernames, absolute paths, serial numbers, machine
identifiers, network addresses, MAC addresses, Docker root paths, credentials,
registration material, or job output. Unsupported fields remain `null`; they
are never inferred from processor names.

## Bound active job context

Autoscaled managers receive GitHub scale-set lifecycle messages so they can
protect busy workers. PitCrew publishes only bounded repository, run/job
identifier, display/event name, timestamp, and result fields needed for
operator triage.

The projection excludes raw runner identity, workflow refs, requested labels,
message payloads, logs, step output, environment values, commit text, JIT
configuration, tokens, and registration material. Fixed and recovered workers
without usable lifecycle metadata remain unattributed; resource activity is
never used to guess a job.

## Isolate pool-local services

An optional profile service network gives workers stable Docker DNS access to
operator-owned services. Containers attached to one bridge network can reach
each other's exposed ports, so use one network per profile or equivalent trust
boundary.

Never attach workers to the manager's Compose network. Keep service
administration, publishing, deletion, and upstream credentials unreachable
from workers. A shared trusted service can join several isolated profile
networks under the same alias without placing those worker profiles on one
network.

## Trust workflow triggers

Do not run untrusted fork pull requests on self-hosted workers. A public
repository can still use PitCrew for trusted pushes or manually approved
workflows, but every trigger must be reviewed against GitHub's self-hosted
runner security guidance.
