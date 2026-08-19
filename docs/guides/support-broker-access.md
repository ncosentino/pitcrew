---
description: Grant the support diagnostics broker inherited read only on dedicated allowlisted evidence directories.
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

Managers mirror these four documents into
`.pitcrew-state/<profile>/support-evidence`, and the broker reads only:

- `.pitcrew-state/<profile>/support-evidence/desired-capacity.json`
- `.pitcrew-state/<profile>/support-evidence/acknowledged-capacity.json`
- `.pitcrew-state/<profile>/support-evidence/static-profile.json`
- `.pitcrew-state/<profile>/support-evidence/observed-state.json`

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

## Apply access only at dedicated evidence directories

Operational PitCrew state files are atomically replaced alongside unrelated
manager state. Granting inherited broker read on the profile directory would
therefore expose files outside the collector allowlist.

`Setup-Runner.ps1` creates the stable `support-evidence` directory under the
operator's profile state before starting the manager. The fixed manager and Go
autoscaler publish bounded copies of only the four approved documents there.
Each copy uses a same-directory temporary file and rename. A mirror failure is
diagnostic: it is surfaced and retried without stopping scaling or changing
live workers. Before support ACLs are installed, the directory is owner-only
and files retain only the group-class read bit needed for a later named-ACL
mask.

Installers apply inheritable access only to the two directories whose complete
contents are support evidence:

- `.pitcrew-state/<profile>/support-evidence`
- the platform connector-health directory

**Windows** uses a direct list/traverse grant plus inheritable file-read ACEs.
**Linux** uses directory traversal/listing plus default file-read ACLs. The
profile directory remains traverse-only, unrelated state never enters the
mirror, and the transport agent receives no evidence access.

## Installer verification

A support-agent installer must prove:

1. the broker can read the collector and exact state/health files;
2. the agent cannot traverse the state or connector-health directories;
3. neither identity can access the Docker socket;
4. a PitCrew capacity update refreshes the dedicated mirror and the broker can
   still read it;
5. a fixed-manager and autoscaler publication preserve the same result.

Failure to prove any check must leave support disabled without changing runner
capacity, managers, workers, connector identity, or credentials.
