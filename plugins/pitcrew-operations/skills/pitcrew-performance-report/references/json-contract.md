# Performance report JSON contract

`pitcrew-performance-report.json` is a sanitized automation contract. Exact
workflow-run reports use contract version 3 with these required top-level
fields:

```json
{
  "schemaVersion": 3,
  "generatedAt": "2026-09-17T00:00:00.0000000+00:00",
  "selection": {
    "mode": "workflow-run-attempt",
    "workflowRun": {
      "repository": "owner/repository",
      "runId": "123456789",
      "attempt": 1,
      "jobInterval": {
        "from": "2026-09-17T00:00:00.0000000+00:00",
        "to": "2026-09-17T00:10:00.0000000+00:00"
      }
    }
  },
  "range": {
    "from": "2026-09-16T23:59:30.0000000+00:00",
    "to": "2026-09-17T00:10:30.0000000+00:00"
  },
  "repositories": ["owner/repository"],
  "verifiedMeasurements": {},
  "unavailableEvidence": [],
  "hypotheses": [],
  "limitations": []
}
```

## Selection modes

- Existing range reports remain contract 2 and retain their prior shape without
  a `selection` field.
- Contract-3 `workflow-run-attempt` reports identify one exact repository, run
  ID, and attempt.
  `jobInterval` is the unpadded interval derived from the selected completed
  GitHub jobs. `range` is the bounded Dashboard interval after adding two raw
  telemetry cadences on each side.

Run IDs are strings in the JSON contract so consumers never lose precision.
Attempts are positive integers.

## Evidence semantics

- `verifiedMeasurements` contains only measurements supported by exact retained
  evidence.
- `unavailableEvidence` records missing, stale, ambiguous, partial, or truncated
  evidence. Absence is never converted to zero.
- `hypotheses` contains labelled interpretations and required follow-up, never
  asserted causes.
- `limitations` contains the interpretation boundaries that apply to every
  report.

Contract 3 preserves every contract-2 measurement section and adds the required
`selection` discriminator only for exact-run mode. Consumers must reject
unknown higher schema versions until reviewed.

## Privacy boundary

The report never includes raw runner names, Dashboard node display names,
credentials, logs, artifacts, environment values, step output, registration
material, workflow file paths, or URL query strings. Exact runner names are
hashed locally and only the lowercase SHA-256 correlation value may appear.

The command writes:

- `pitcrew-performance-report.json`
- `pitcrew-performance-report.md`

It performs no workflow, runner, capacity, manager, Docker, or host mutation.
