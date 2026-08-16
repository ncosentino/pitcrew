---
name: pitcrew-remote-diagnostics
description: Triage a PitCrew incident remotely first, then run a fixed read-only collector through the outbound support relay, directly, through explicit PowerShell SSH or WinRM transport, or through a deterministic agent-handoff bundle and verify the returned diagnosis.
license: MIT
---

# PitCrew Remote Diagnostics

Diagnose first; never mutate the node. This skill automates the evidence handoff
that `pitcrew-host-diagnostics` previously required an operator to compose.

Read these shared references before running commands:

- [operations safety](../../references/safety.md)
- [profile replay](../../references/profile-replay.md)

Use only the supported scripts in this skill's `scripts` directory:

- `New-PitCrewDiagnosticsPreflight.ps1`
- `Invoke-PitCrewRemoteDiagnostics.ps1`
- `New-PitCrewDiagnosticsPackage.ps1`
- `Collect-PitCrewDiagnostics.ps1`
- `Import-PitCrewDiagnostics.ps1`
- `Invoke-PitCrewSupportRelay.ps1`

## Non-negotiable boundaries

- Never restart, stop, kill, pause, remove, reconfigure, or update Docker, a
  service, a manager, a worker, a connector, or the host.
- Never read `.env`, `.env.*`, connector identity, credentials, tokens, JIT
  configuration, registration payloads, job output, logs, artifacts, or
  arbitrary host paths.
- Never add a generic inbound command channel or store SSH, WinRM, Dashboard,
  GitHub, or connector credentials.
- SSH and WinRM are allowed only when the caller explicitly supplies the host,
  user, and any key or in-memory `PSCredential`. Never discover transport
  targets or credentials.
- Docker queries use exact PitCrew labels or exact container IDs. The only
  removable container is the collector's own run-scoped diagnostic container,
  after its exact ID and `pitcrew-diagnostics-session` label are verified.
- URL probes use only caller-approved query-free HTTP or HTTPS URLs and a
  caller-approved finite timeout.

## Phase 1: remote-first preflight

Before requesting host evidence, collect what the failed connector channel
cannot invalidate:

1. Read the Dashboard node card, incident, last accepted heartbeat, and stale
   projection warning through the available Dashboard surface.
2. Read the exact affected GitHub Actions run or job metadata with `gh`. Never
   request logs or artifacts.
3. Probe only the explicitly supplied public Dashboard origin. Require HTTPS
   except for loopback testing and never follow redirects.
4. Read the latest published PitCrew and Dashboard releases.
5. Narrow the diagnostic mode:
   - `ConnectorOffline`
   - `CapacityMismatch`
   - `JobNotAssigned`
   - `HostPressure`
   - `Full`

Persist the safe preflight evidence:

```powershell
pwsh ./scripts/New-PitCrewDiagnosticsPreflight.ps1 `
    -DiagnosticMode ConnectorOffline `
    -PublicDashboardUrl https://dashboard.example `
    -GitHubRunUrl https://github.com/owner/repository/actions/runs/123 `
    -DashboardNodeId <dashboard-node-id> `
    -DashboardNodeStatus offline `
    -DashboardNodeLastSeenAt 2026-08-07T09:00:00Z `
    -DashboardIncident connector-offline `
    -OutputPath <session-directory>\pitcrew-diagnostics-preflight.json
```

Omit unavailable optional inputs rather than inventing them. The preflight file
must exist before relay, direct, transport, or package collection begins.

## Phase 2: choose one execution path

### Outbound support relay

Prefer `Relay` when the node advertises the read-only support-plane v1
capability. The node polls outward over HTTPS; the skill never opens an inbound
connection or receives a shell.

```powershell
pwsh ./scripts/Invoke-PitCrewRemoteDiagnostics.ps1 `
    -ExecutionMode Relay `
    -DashboardUrl https://dashboard.example `
    -TenantId <tenant-id> `
    -DashboardNodeId <support-node-id> `
    -Profile <profile> `
    -DiagnosticMode CapacityMismatch `
    -PreflightPath <session-directory>\pitcrew-diagnostics-preflight.json `
    -OutputDirectory <session-directory>\pitcrew-diagnostics
```

The request uses the expiring read-only credential from
`PITCREW_DIAGNOSTICS_CREDENTIAL`. The skill independently verifies that the
node signature matches the identity bound when the session was created, then
imports the signed report through the same package and diagnosis contracts as
direct and handoff collection.

If the bounded wait ends before completion, retain the returned session ID and
the returned node-key fingerprint, request digest, and expiry. Resume with
`-SupportSessionId`, `-SupportNodeSigningKeyFingerprint`,
`-SupportRequestDigest`, and `-SupportExpiresAt` plus the same node, mode, and
profile instead of creating another request.

Relay mode never requests a mutation, accepts arbitrary node paths, handles
device private keys, or falls back to another transport when signature,
tenant, node, capability, or package verification fails.

### Direct

Use `Direct` only when the current session is already on the PitCrew node and
the exact installation root is known.

```powershell
pwsh ./scripts/Invoke-PitCrewRemoteDiagnostics.ps1 `
    -ExecutionMode Direct `
    -PitCrewRoot <pitcrew-root> `
    -Profile <profile> `
    -DiagnosticMode ConnectorOffline `
    -PreflightPath <session-directory>\pitcrew-diagnostics-preflight.json `
    -OutputDirectory <session-directory>\pitcrew-diagnostics
```

### Explicit SSH

Use `Ssh` only for an explicitly supplied PowerShell-remoting SSH endpoint. The
script transmits the fixed collector source in memory and returns its structured
object; it does not install an agent or copy credentials.

```powershell
pwsh ./scripts/Invoke-PitCrewRemoteDiagnostics.ps1 `
    -ExecutionMode Ssh `
    -PitCrewRoot <remote-pitcrew-root> `
    -Profile <profile> `
    -DiagnosticMode HostPressure `
    -SshHostName <explicit-host> `
    -SshUserName <explicit-user> `
    -SshKeyFilePath <explicit-key-file> `
    -PreflightPath <session-directory>\pitcrew-diagnostics-preflight.json `
    -OutputDirectory <session-directory>\pitcrew-diagnostics
```

The key file is optional when the caller's existing SSH agent or configuration
already supplies authentication. Never create or copy a key.

### Explicit WinRM

Use `WinRM` only for an explicitly supplied computer name. Pass an in-memory
`PSCredential` only when the caller already provided one through the active
PowerShell session; never serialize it.

```powershell
pwsh ./scripts/Invoke-PitCrewRemoteDiagnostics.ps1 `
    -ExecutionMode WinRM `
    -PitCrewRoot <remote-pitcrew-root> `
    -Profile <profile> `
    -DiagnosticMode CapacityMismatch `
    -WinRMComputerName <explicit-host> `
    -PreflightPath <session-directory>\pitcrew-diagnostics-preflight.json `
    -OutputDirectory <session-directory>\pitcrew-diagnostics
```

### Agent handoff

When no approved transport exists, create a deterministic package in the
session's persistent directory:

```powershell
pwsh ./scripts/Invoke-PitCrewRemoteDiagnostics.ps1 `
    -ExecutionMode Package `
    -PitCrewRoot <remote-pitcrew-root> `
    -Profile <profile> `
    -DiagnosticMode Full `
    -PreflightPath <session-directory>\pitcrew-diagnostics-preflight.json `
    -OutputDirectory <session-directory>\pitcrew-diagnostics
```

Return the generated ZIP, SHA-256 file, and package ID. The ZIP contains the
collector, manifest, collector checksum, exact invocation, and exact node-agent
prompt. Do not manually rewrite its command or prompt.

## Dry-run transport plan

Add `-PlanOnly` to print the resolved execution mode, diagnostic mode, package
ID, profile, approved URLs, timeout, and explicit transport without connecting,
creating a package, or writing output.

## Optional URL probes

Add only URLs the caller explicitly approved:

```powershell
-ApprovedUrl https://example.test/artifact `
-ProbeTimeoutSeconds 300
```

Accept at most four URLs and a timeout from 1 through 900 seconds. Reject
credentials, query strings, fragments, shell expansions, and invented URLs.
Redirects are not followed because each destination would require separate
approval. Curl configuration files are disabled and response bodies are
discarded. The container sample uses the recorded immutable local worker image
ID with `--pull=never` and an explicit `curl` entrypoint, so it neither pulls an
image nor starts the worker registration entrypoint. One host/container pair is
one sample, not proof of a root cause.

## Phase 3: verify and import returned evidence

For an agent handoff, accept only a ZIP containing:

- `pitcrew-diagnostics.json`
- `pitcrew-diagnostics.md`
- `result-manifest.json`

Import it with the package ID and collector checksum from the original bundle:

```powershell
pwsh ./scripts/Import-PitCrewDiagnostics.ps1 `
    -InputPath <returned-results.zip> `
    -ExpectedPackageId <package-id> `
    -ExpectedCollectorSha256 <collector-sha256> `
    -PreflightPath <session-directory>\pitcrew-diagnostics-preflight.json `
    -OutputDirectory <session-directory>\pitcrew-diagnosis
```

The importer rejects path traversal, extra archive entries, oversized files,
checksum mismatches, package mismatches, unsupported schemas, unredacted root
paths, and forbidden secret-bearing property names. It correlates preflight,
connector outage, observed-state, and collection timestamps.

For manager contract 18, the imported diagnosis must contain the validated,
bounded host-admission projection: status, namespace, epoch, decision sequence,
host policy values and fingerprint, profile cost/reservation/borrowing and
accounting, pending/withheld units, and the last decision. It must also preserve
fixed or per-target capacity-deficit freshness and reasons.

Classify evidence honestly:

- `disabled` is observed policy state.
- `degraded` means policy identity or current demand accounting is incomplete.
- `unavailable` means coordinator measurements were not obtained; null values
  stay unavailable rather than becoming zero.
- An absent host-admission object on an older manager contract is unsupported
  evidence, not proof that admission was disabled. Disabled cannot be inferred
  from null.

Keep `host-admission-withheld`, `host-admission-degraded`, and
`host-admission-unavailable` distinct from profile `admission-ceiling`, GitHub
demand, Docker, JIT, listener, cleanup, and unknown evidence. Admission units
are abstract policy accounting, not CPU, memory, worker counts, queue weights,
or a performance diagnosis.

## Handoff

Return the absolute paths to:

- `pitcrew-diagnostics-diagnosis.json`
- `pitcrew-diagnostics-diagnosis.md`

The diagnosis has three explicit sections:

1. **Verified measurements**
2. **Unavailable evidence**
3. **Hypotheses**

Keep hypotheses labelled as unverified and name the next non-destructive
measurement that would confirm each one. Never turn one sample, stale evidence,
or an unavailable measurement into a root cause.
