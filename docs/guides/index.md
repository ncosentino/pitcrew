---
description: Task-focused PitCrew guides for profiles, workflow routing, custom images, and security boundaries.
---

# Guides

Use these guides after completing [Getting Started](../getting-started.md):

- [Named Profiles](named-profiles.md) - run independent worker pools on one host.
- [Custom Profiles](custom-profiles.md) - define a specialized image and verification contract.
- [Repository-Owned Worker Images](repository-owned-images.md) - publish,
  activate, update, and roll back an external OCI runner image.
- [Read-Only External Data Volumes](external-data-volumes.md) - attach
  operator-provisioned immutable datasets to workers without exposing storage
  credentials.
- [Pool-Local Services](pool-local-services.md) - reach operator-owned services
  through stable, profile-scoped Docker DNS without worker mounts or host
  ports.
- [Routing Workloads](routing-workloads.md) - target the correct pool from GitHub Actions.
- [Demand-Driven Autoscaling](autoscaling.md) - shrink idle pools and
  automatically restore capacity for queued work.
- [Rolling Updates](rolling-updates.md) - replace managers immediately, roll
  safe idle workers, and preserve active jobs.
- [Security Boundaries](security-boundaries.md) - protect the Docker host and workflow credentials.
- [Copilot CLI Operations](copilot-operations.md) - install repeatable capacity
  and version-update skills.
