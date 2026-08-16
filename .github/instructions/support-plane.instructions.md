---
applyTo: "plugins/pitcrew-operations/skills/pitcrew-remote-diagnostics/**,tests/Test-RemoteDiagnostics.ps1,docs/adr/adr-0007-outbound-read-only-support-plane.md,docs/guides/{security-boundaries,copilot-operations}.md"
---

# Support Plane

- Preserve the outbound-only, typed, read-only v1 boundary. Never add a shell,
  arbitrary command, script, path, URL, port-forwarding, or tunnel field.
- Keep the support transport, diagnostics broker, existing connector, and relay
  as separate trust domains. The network-facing transport cannot read PitCrew
  state; the broker cannot access the network or Docker.
- Treat the relay as untrusted storage and delivery. It cannot sign requests,
  decrypt requests or results, select capabilities, or establish node trust.
- Bind every request and result to the tenant, node, capability, expiry,
  canonical digest, and enrolled key. Fail closed on missing or mismatched
  cryptographic evidence.
- Keep replay tombstones and cached signed results outside `.pitcrew-state`.
  Duplicate request digests return the cached result and never rerun collection.
- The broker may invoke only the reviewed collector with
  `-FileOnly -PassThruOnly` against a locally configured PitCrew root.
- File-only collection launches no external command. Excluded Docker, host,
  network, and version evidence must be explicit unavailable values, never
  fabricated zeroes.
- Reuse the existing bounded report, redaction, checksum, import, and diagnosis
  contracts. Add shared cryptographic vectors for envelope changes.
- Preserve direct, SSH, WinRM, package, connector capacity, and connector
  recovery behavior unless a separately versioned migration changes them.
