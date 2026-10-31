---
applyTo: "profiles/image-builder/pitcrew-build-image,tests/Test-ImageCandidateReport.sh,tests/integration/Test-IsolatedImageBuilder.sh"
---

# Image verification pipelines

- Drain streaming archive producers completely; an early-exiting matcher can cause
  a false verification failure under `pipefail`.
- Preserve producer failures and distinguish archive read failure from an absent
  declared member. Never disable `pipefail` or tolerate a failed producer.
- Cover present members followed by a long stream, absent members, and producer
  failure after a match with deterministic fixtures, not sleeps or blind retries.
