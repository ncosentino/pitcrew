# Current admission snapshot JSON contract

`pitcrew-admission-snapshot.json` is a sanitized point-in-time automation
contract. Consumers must require `schemaVersion` 1 and reject unknown higher
versions until reviewed.

```json
{
  "schemaVersion": 1,
  "generatedAt": "2026-09-18T21:00:00.0000000+00:00",
  "scope": {
    "nodeId": "00000000-0000-0000-0000-000000000001",
    "profileId": "project-ci",
    "requestedWorkers": 4
  },
  "evidence": {
    "authority": "pitcrew-manager",
    "source": "host-admission",
    "managerContractVersion": 21,
    "sourceObservedAt": "2026-09-18T20:59:45.0000000+00:00",
    "dashboardReceivedAt": "2026-09-18T20:59:46.0000000+00:00",
    "evaluatedAt": "2026-09-18T21:00:00.0000000+00:00",
    "responseGeneratedAt": "2026-09-18T21:00:00.0000000+00:00",
    "freshnessBoundary": "2026-09-18T21:01:45.0000000+00:00",
    "freshness": "current",
    "coverage": "complete",
    "retention": "live",
    "completeness": "complete",
    "unavailableReason": null
  },
  "admission": {
    "status": "available",
    "epoch": 4,
    "decisionSequence": 51,
    "hostPolicyFingerprint": "example-host-policy",
    "profilePolicyFingerprint": "example-profile-policy",
    "unitCost": 2,
    "requestedUnits": 8,
    "allocatableUnits": 10,
    "allocatableWorkers": 5,
    "theoreticalMaximumUnits": 14,
    "theoreticalMaximumWorkers": 7,
    "pendingUnits": 0,
    "withheldUnits": 0,
    "withholdingReason": null
  },
  "disposition": "admissible-now",
  "reason": "current-allocatable-capacity-sufficient",
  "limitations": [
    "This is a point-in-time observation, not a capacity reservation or a promise that a later acquisition will succeed.",
    "Fair-share rotation, intervening leases, and new demand may change the next coordinator decision.",
    "Admission units are abstract policy accounting, not CPU, memory, worker priority, or universal workload weights.",
    "The snapshot does not estimate GitHub queue wait or workflow completion time."
  ]
}
```

The executable schema is
[`admission-snapshot.schema.json`](admission-snapshot.schema.json).

## Dispositions

- `admissible-now` means the positive requested worker count does not exceed
  the fresh coordinator-reported `allocatableWorkers` value.
- `insufficient-now` means fresh complete evidence measured fewer allocatable
  workers than requested. A measured zero remains zero.
- `unknown` covers stale, partial, unavailable, last-known, unsupported,
  missing, malformed, or incomplete evidence; it is never converted to zero.

Only fresh, complete, live Dashboard claim evidence for an `available`
contract-19-or-newer admission projection can produce a non-unknown
disposition. `degraded`, `unavailable`, and `disabled` remain explicit status
values, but they never authorize a capacity conclusion. A contract-19 manager
without contract-21 source provenance remains `unknown` because its freshness
cannot be established safely.

## Stability and privacy

The policy fingerprints are opaque compatibility identities, not credentials.
The output excludes the diagnostic credential, tenant, node display name,
manager identity, connector identity, repositories, runner names, slots,
container identifiers, host paths, image references, logs, and job output.

The snapshot is not a reservation. Fair-share rotation, intervening leases,
new demand, manager state, and connector delivery can change immediately after
the observation. Admission units are not CPU, memory, priority, or universal
worker weights, and the result does not predict queue wait or completion time.
