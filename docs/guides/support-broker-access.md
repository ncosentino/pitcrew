---
description: Grant the support diagnostics broker only the inherited read access required by the file-only collector.
---

# Support Broker Access

Support-plane transport and diagnostics use separate process identities. The
network-facing agent must not read PitCrew state. The broker receives only the
minimum read and traversal access declared by
[`support-broker-access.json`](https://github.com/ncosentino/pitcrew/blob/main/support-broker-access.json).

## Exact broker reads

The broker executes only the release-matched collector at:

```text
plugins/pitcrew-operations/skills/pitcrew-remote-diagnostics/scripts/Collect-PitCrewDiagnostics.ps1
```

It supplies fixed `FileOnly` and `PassThruOnly` switches plus a closed
diagnostic mode, optional validated profile ID, and deterministic package ID.

The collector probes these PitCrew-root files without reading their contents:

- `Setup-Runner.ps1`
- `RunnerProfiles.Functions.ps1`
- `docker-compose.yml`

For the selected profile it reads only:

- `.pitcrew-state/<profile>/desired-capacity.json`
- `.pitcrew-state/<profile>/acknowledged-capacity.json`
- `.pitcrew-state/<profile>/static-profile.json`
- `.pitcrew-state/<profile>/observed-state.json`

It may also read the bounded connector-health projection:

| Platform | Directory |
| --- | --- |
| Windows | `%ProgramData%\PitCrew\Connector\health` |
| Linux | `/var/lib/pitcrew-connector/health` |

Only `connector-health.json` and `connector-events.jsonl` are part of that
contract.

## Denied surfaces

Do not grant the broker access to environment files, connector identity,
registration or JIT material, job output, the Docker socket, or arbitrary host
paths. The transport agent receives no access to the PitCrew state or connector
health directories.

## Apply access at directories

PitCrew state files are atomically replaced. Every current producer creates its
temporary file in the destination profile directory and then renames it over
the visible path:

- PowerShell publishes desired and static state.
- The fixed manager publishes acknowledgement and observed state.
- The Go autoscaler publishes the same documents.

Installers must therefore apply inheritable access to stable directories rather
than ACLs to the current files:

- **Windows:** grant the broker identity inherited read/list/traverse access
  through directory ACEs. Do not grant the transport-agent identity access.
- **Linux:** grant directory traversal/listing plus default read ACLs to the
  broker identity or broker-only group. Keep the agent outside that group.

The profile directory itself is not replaced during compatible setup, capacity,
manager, or image updates. Same-directory atomic replacement causes every new
state file to receive the directory-owned access policy.

## Installer verification

A support-agent installer must prove:

1. the broker can read the collector and exact state/health files;
2. the agent cannot traverse the state or connector-health directories;
3. neither identity can access the Docker socket;
4. a PitCrew capacity update replaces state and the broker can still read it;
5. a fixed-manager and autoscaler publication preserve the same result.

Failure to prove any check must leave support disabled without changing runner
capacity, managers, workers, connector identity, or credentials.
