---
title: "ADR-0004: Ephemeral runner execution domains"
status: "Proposed"
date: "2026-08-11"
authors: []
tags: ["architecture", "runners", "execution", "security", "profiles"]
supersedes: ""
superseded_by: ""
---

# ADR-0004: Ephemeral Runner Execution Domains

## Context and scope

PitCrew currently runs every worker as a disposable Linux container. This provides a
strong default lifecycle: one manager owns Docker access, each worker receives one
ephemeral GitHub registration, the worker accepts one job, and Docker removes the
container afterward.

Some self-hosted workloads require an execution domain that an ordinary container
cannot honestly provide. Examples include native Windows kernel behavior, privileged
Linux block-device and mount behavior, and OCI image publication through a build
daemon. Routing those jobs to a normal container under a different label would
misrepresent the available capability. Giving ordinary workers broad host privilege
would instead weaken the security boundary for every existing profile.

This decision defines how PitCrew can represent specialized execution domains without
changing the default container boundary. It covers profile compatibility, manager
placement, runner and credential lifecycle, privilege isolation, recovery,
observability, and the image-builder boundary.

It does not select a hypervisor, provision hardware, define a remote fleet scheduler,
support untrusted fork workflows, or extend host-local admission across machines.

### Verified facts

- PitCrew requires Docker with Linux-container support and describes its workers as
  Linux container runners.
- Only the profile manager receives the Docker socket. Ordinary workers are
  intentionally socketless and cannot run Docker builds, container actions, or
  service containers against that daemon.
- Profile schema version 1 requires an OCI image and has no native-host, virtual
  machine, device, Linux-capability, privileged, or arbitrary executor contract.
- Both the fixed shell manager and the Go autoscaler currently launch and recover
  workers through Docker.
- The Go autoscaler already uses GitHub's Runner Scale Set Client.
- GitHub supports self-hosted runners on physical systems, virtual machines, and
  containers across Linux, Windows, and macOS. GitHub recommends ephemeral runners
  for autoscaling and exposes the scale-set client for custom infrastructure
  provisioning.
- GitHub label matching establishes job eligibility. It does not prove that a runner
  actually owns the operating-system, device, privilege, or isolation capability
  advertised by that label.

### Assumptions

- Operators can provide and maintain the platform-specific virtualization or kernel
  facilities required by an approved execution domain.
- Specialized profiles execute only trusted same-repository workflow code and use
  capability-specific labels.
- Operators can retain runner application diagnostics outside a disposable worker
  without exposing workflow output or registration material through PitCrew state.
- A specialized host can be dedicated to the applicable trust boundary when the
  execution domain grants host-equivalent or virtualization-administrator privilege.

## Decision drivers

- Preserve the socketless, disposable Linux-container worker as the safe default.
- Represent native operating-system and kernel capabilities truthfully.
- Keep one-job isolation and credential destruction explicit across every backend.
- Prevent a workflow input or repository-owned manifest from inventing host access,
  raw launch arguments, or a new executor.
- Keep privileged profiles out of ordinary runner eligibility and host trust
  boundaries.
- Reuse GitHub's scale-set demand and JIT registration contracts where non-container
  lifecycle requires a new manager implementation.
- Fail closed after uncertain cleanup, reversion, ownership, or credential state.
- Avoid a remote credential-bearing runner control plane.
- Preserve versioned, sanitized, backend-neutral operational evidence.
- Keep execution-domain changes explicit and expensive rather than silently rolling
  them through active workers.

## Decision

PitCrew will support explicit ephemeral runner execution domains. Existing profile
schema version 1 remains the unchanged Linux-container contract. A separately
versioned profile contract will discriminate the worker execution domain and its
artifact or image requirements.

### Versioned profile boundary

Schema version 1 continues to mean the current Docker-container worker. Existing
manifests, setup commands, managers, fingerprints, and rolling compatibility retain
their current meaning.

A future schema version 2 will use a discriminated execution-domain contract rather
than requiring every worker artifact to masquerade as an OCI image. Setup and
managers must reject an unknown schema version, domain, artifact kind, capability,
or policy field. They must never fall back to the ordinary Docker domain.

Execution domains are defined by the installed PitCrew release. A profile may select
only a known typed domain and typed policy. It cannot supply an executable, script,
command template, raw Docker arguments, arbitrary host path, or remote endpoint as a
launcher.

Changing a profile's execution domain is not rolling-compatible. It requires an
explicit stopped-profile migration after every active worker and retained backend
unit has been reconciled.

### Ordinary and elevated container domains

The ordinary container domain remains socketless, unprivileged, and compatible with
both fixed and scale-set managers.

Elevated Linux validation may use a distinct container policy only when all of the
following are true:

- the profile uses capability-specific labels and omits broad default labels;
- the operator explicitly approves a typed, allowlisted device and Linux-capability
  policy;
- no worker receives the PitCrew manager Docker socket;
- the host is dedicated to the elevated profile's trust boundary;
- cleanup and restart recovery prove that no fixture device, mount, mapping, or
  worker remains; and
- the policy cannot be selected or expanded by workflow input.

The public contract will not accept blanket raw privilege switches. If the required
kernel behavior cannot be represented by a bounded typed policy, the workload must
use a disposable virtual-machine domain instead.

### Native disposable-VM domain

Native operating-system evidence will use a disposable virtual-machine domain, not a
persistent runner process installed directly on a reusable host.

The first non-container manager path is scale-set only. A native PitCrew manager
service runs on the same execution host as its provisioner and contains both the
scale-set client and the selected built-in executor. It holds the GitHub
administration credential locally, requests JIT configuration, and provisions the
worker locally. No central PitCrew manager sends credentials or arbitrary commands
to a remote execution host.

Each job receives a new virtual machine or an immutable-base clone with a unique
writable layer. The runner registration, runner credentials, workspace, caches,
temporary files, and job-written persistence live only in that per-job unit.
PitCrew must destroy the writable unit before the slot can accept another job.

A backend may use snapshot or immutable-base cloning internally, but "reverted" is
not a success claim by itself. The backend must verify that the prior writable unit
is absent and that the next unit derives from the approved immutable base. Failure
to prove destruction or base identity quarantines the slot and blocks replacement
capacity.

The fixed POSIX manager remains container-only. Native execution therefore requires
scale-set mode and accepts temporary manager-mode asymmetry.

### Credential and diagnostic lifecycle

The manager retains long-lived GitHub administration credentials outside workers.
JIT configuration and generated runner credentials are scoped to one backend unit,
are never persisted in observed state or logs, and are delivered through a
backend-owned one-time bootstrap boundary.

Before a slot is reusable, the backend must prove that the unit containing JIT
configuration, runner credentials, and workflow-writable state was destroyed.
Deleting only the GitHub registration is insufficient.

Ephemeral runner application diagnostics must be forwarded to an operator-owned
store before unit destruction when troubleshooting evidence is required. PitCrew
observed state retains only bounded lifecycle classifications and timestamps; it
never publishes runner logs, workflow output, credentials, raw VM identity, host
paths, or provisioning payloads.

### Backend lifecycle and recovery

Every execution domain implements the same manager-owned lifecycle semantics:

- validate the approved artifact and host capability before accepting demand;
- prepare a unit without allowing the runner process to start;
- bind one exact slot and JIT registration to that unit;
- activate the unit only after applicable admission is accepted;
- observe assignment, running state, completion, and bounded diagnostics;
- preserve an assigned or ambiguously busy unit;
- remove an idle registration before destructive scale-down;
- destroy or quarantine the exact unit after completion, cancellation, or failed
  launch; and
- recover exact owned units after manager restart without broad host scanning.

Backend ownership state is durable and atomic. A manager restart must distinguish a
prepared but unstarted unit, a running or assigned unit, a completed unit awaiting
destruction, and an uncertain unit. Unknown ownership, missing state, failed
destruction, or failed base verification blocks new admission for that slot. Time
alone never converts uncertain state into reusable capacity.

Cancellation does not weaken cleanup. The manager preserves a still-running assigned
unit, then removes its exact registration and backend unit when completion is
confirmed. A partially provisioned unit that never ran is destroyed through its
exact retained ownership record.

### Privilege, routing, and host admission

Capability labels are operator-owned profile configuration. Workflow input may choose
workflow behavior but cannot select an execution domain, add labels, expand devices,
or elevate an ordinary profile.

Native and elevated profiles do not share runner eligibility or a host trust boundary
with ordinary profiles. Their hosts are dedicated to the specialized execution
domain unless a later decision supplies an equivalent cross-domain isolation and
admission proof.

Docker host-local admission applies only to the Docker execution boundary it can
measure and control. A native or elevated backend must either implement a compatible
host-local admission contract or report only queue isolation and configured
capacity. Documentation and observed state must not claim a physical-resource
guarantee when admission evidence is unavailable.

### Isolated image-builder service class

OCI image building does not by itself require a new worker execution domain.
An ordinary socketless container profile may use an operator-owned isolated
BuildKit or Docker daemon through the existing approved service-network contract.

That daemon must not be the PitCrew orchestration daemon, must not expose the host
Docker socket to the worker, must use a dedicated trust boundary and network
unreachable from ordinary profiles, and must provide disposable or explicitly
cleared build state between jobs. If those properties cannot be proven, image
building must use the disposable-VM domain.

Registry credentials remain job-scoped GitHub secrets. They do not enter the worker
image, profile manifest, manager environment, or observed state.

### Compatibility and observed state

Backend-neutral manager logic owns demand, slot identity, registration fencing,
admission, lifecycle classification, retirement, and sanitized diagnostics.
Backend-specific code owns only artifact validation, local provisioning, exact-unit
inspection, activation, destruction, and resource measurement.

The scale-set client is isolated behind PitCrew's internal GitHub-demand adapter so a
pre-1.0 dependency change does not become the public execution-domain contract.

Observed-state evolution is additive and versioned. It may identify the configured
execution domain and bounded capability or quarantine status. Backend-specific raw
identifiers and unsupported measurements remain unavailable rather than being
coerced into Docker-shaped fields.

## Alternatives considered

### Keep specialized runners outside PitCrew

Operators could install standalone native GitHub runners and manage cleanup
separately. This minimizes PitCrew changes and may provision one host quickly.

Persistent services do not provide PitCrew's one-job destruction, recovery,
observability, or profile compatibility guarantees. Separate lifecycle tooling would
duplicate the same credential, cleanup, and failure-state responsibilities. This
remains possible operationally but is not the selected PitCrew architecture.

### Add arbitrary privileged Docker arguments to profiles

Raw `--privileged`, device, mount, or socket arguments could satisfy some Linux jobs
with a small schema change.

This would make an operator manifest an unbounded host-control interface, could expose
the manager daemon, and still would not provide native Windows behavior. PitCrew
instead permits only a future typed elevated policy with dedicated-host isolation and
fail-closed cleanup.

### Use a persistent native process runner and reset its workspace

GitHub supports ephemeral registration for a process runner, so PitCrew could remove
the registration and clean selected directories after each job.

Workflow code with administrator or kernel-facing privilege can persist outside the
workspace. Directory cleanup cannot prove removal of services, drivers, scheduled
tasks, mount state, credentials, or other host changes. A disposable VM provides the
required destruction boundary.

### Use one central manager with remote executor agents

A central manager could hold GitHub credentials and instruct remote Windows, Linux,
or builder agents over a network protocol.

This creates a remote credential-bearing control plane, requires transport identity
and authorization, expands outage and compromise scope, and conflicts with PitCrew's
host-local operating model. Native managers instead own credentials and provisioning
on their execution host.

### Port both fixed and scale-set managers before adding a backend

Full parity would avoid manager-mode asymmetry.

The fixed shell manager is coupled to Docker and POSIX behavior, while the Go
scale-set manager already owns JIT demand and cross-platform compilation. Requiring
both modes would duplicate platform lifecycle work before any native evidence exists.
Initial native support is therefore scale-set only.

### Run every specialized workload in a disposable VM

One VM abstraction would provide a uniform destruction boundary for Windows,
privileged Linux, and image building.

It would also impose VM startup, artifact, and host requirements where a bounded
elevated container or isolated build daemon is sufficient. The selected design uses
the narrowest execution domain that can truthfully provide each capability.

## Consequences

### Positive

- Existing PitCrew profiles keep their current behavior and trust boundary.
- Native Windows and other OS-specific evidence can be represented truthfully.
- Privileged Linux support does not require broad privilege on ordinary workers.
- Credential and writable-state destruction become explicit backend obligations.
- Uncertain cleanup or reversion removes capacity instead of contaminating a later
  job.
- Scale-set demand, profile routing, and sanitized observed state remain shared
  control-plane concepts.
- Image builders can use an isolated daemon without exposing the orchestration socket.

### Negative

- PitCrew gains a second manager deployment topology and a new profile schema version.
- Native hosts require a privileged PitCrew service plus platform-specific
  virtualization and immutable worker artifacts.
- Native execution initially lacks fixed-manager support.
- Elevated and native profiles require dedicated host trust boundaries, increasing
  hardware and idle-capacity cost.
- Backend lifecycle, quarantine, credential destruction, and crash recovery require
  substantially more deterministic and live validation.
- Existing Docker host-admission guarantees do not automatically cover new execution
  domains.

### Neutral

- GitHub remains the queue and demand authority.
- Operators still own hardware, immutable artifacts, registry access, and capacity.
- This decision does not select Hyper-V, QEMU, libvirt, another hypervisor, or a
  remote fleet-management system.
- Specialized capacity remains unavailable until each domain satisfies its
  confirmation evidence.

## Confirmation

The decision is structurally confirmed when:

- schema version 1 behavior and compatibility tests remain unchanged;
- schema version 2 rejects unknown domains and contains no arbitrary launcher or raw
  host-control field;
- changing execution domains requires an explicit stopped-profile migration;
- native managers run the scale-set client and executor locally without a remote
  command channel;
- ordinary profiles cannot acquire elevated labels, devices, capabilities, service
  networks, or execution domains through workflow input;
- observed state reports backend and quarantine evidence without credentials, raw
  unit identity, host paths, or workflow output; and
- the image-builder reference architecture cannot reach the PitCrew orchestration
  daemon.

An execution domain is operationally confirmed only after deterministic tests and
live same-repository evidence prove:

- one JIT registration and one writable unit per job;
- credential and writable-state destruction before slot reuse;
- cancellation and partial-provision cleanup;
- manager-restart recovery for prepared, running, completed, and uncertain units;
- quarantine after failed destruction or immutable-base verification;
- preservation of assigned or ambiguously busy work;
- exact capability routing with no hosted fallback; and
- the domain-specific native, elevated, or builder behavior it advertises.

Acceptance of this record does not claim that any specialized execution domain is
already implemented or qualified.

## References

- [PitCrew documentation map](../index.md) establishes Linux-container support as the
  current installation and execution boundary.
- [Routing Workloads](../guides/routing-workloads.md) demonstrates that native
  operating systems and Docker-dependent jobs are outside ordinary worker
  capabilities today.
- [Security Boundaries](../guides/security-boundaries.md) demonstrates the
  manager-only Docker socket boundary and recommends an isolated daemon or disposable
  VM for Docker-dependent work.
- [Contributor Architecture](../contributing/architecture.md) demonstrates that both
  current manager modes own disposable Docker workers and publish one common
  observed-state contract.
- [ADR-0002](adr-0002-workload-agnostic-service-classes.md) requires capability
  profiles to remain workload-agnostic and distinguishes queue isolation from a
  physical-resource guarantee.
- [ADR-0003](adr-0003-dedicated-host-admission-service.md) demonstrates the current
  Docker-host-local admission and fail-closed lease boundary that new domains do not
  inherit automatically.
- [GitHub self-hosted runners reference](https://docs.github.com/en/actions/reference/runners/self-hosted-runners)
  establishes supported execution substrates, recommends ephemeral runners for
  autoscaling, and identifies the Runner Scale Set Client as the customization
  boundary for VM, container, and native infrastructure.
- [Specialized execution-domain workstream](https://github.com/ncosentino/pitcrew/issues/106)
  records the backend-specific implementation and qualification work owned outside
  this decision.
