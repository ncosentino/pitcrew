---
description: Connect ephemeral workers to operator-owned, profile-scoped services through stable Docker DNS without exposing host ports or mounts.
---

# Pool-Local Services

Some profiles benefit from a service that runs once per Docker host, such as a
read-through package mirror. PitCrew can attach workers to one existing Docker
bridge network so repositories use the same network-scoped service name on
every host.

PitCrew does not create, configure, start, stop, inspect credentials for, or
remove the network or any service attached to it.

## Provision the network

Create one local bridge network for each profile or trust boundary:

```powershell
docker network create `
    --driver bridge `
    pitcrew-build-services
```

The network must be user-defined, local, use the `bridge` driver, and not be
internal. Docker's built-in `bridge` network is rejected because it does not
provide the automatic container-name and alias DNS required by this contract.
Workers need normal outbound connectivity to register with GitHub and run jobs.

Never use a PitCrew manager Compose network. The manager owns the Docker
socket and remains isolated from worker service networks.

## Attach the service

Run the operator-owned service with a stable network alias and without
publishing its worker-facing port to the host:

```powershell
docker run --detach `
    --name package-mirror `
    --network pitcrew-build-services `
    --network-alias package-mirror `
    ghcr.io/example/package-mirror@sha256:<digest>
```

The service image, configuration, storage, upgrades, and credentials remain
outside PitCrew. Expose only the read-through interface to workers. Keep
administration, publishing, deletion, and upstream credentials unreachable
from the service network.

## Declare the service network

```json
{
  "schemaVersion": 1,
  "name": "build",
  "description": "Build workers with a pool-local package mirror.",
  "image": "ghcr.io/example/build-runner@sha256:<digest>",
  "labels": ["build"],
  "replicas": 2,
  "pullImage": true,
  "disableDefaultLabels": true,
  "serviceNetwork": {
    "source": "pitcrew-build-services"
  },
  "verificationCommands": [
    "test \"$(wget -qO- http://package-mirror:8080/health)\" = \"ready\""
  ]
}
```

Setup inspects the exact network before changing the manager and attaches
image-verification containers to it. A missing, internal, non-local, non-bridge, or built-in default network rejects
the rollout while the existing pool remains unchanged.

PitCrew passes only the network name to the manager. Service aliases and ports
belong to the operator-owned service deployment.

## Consume the service

Workflows continue to select the profile label:

```yaml
jobs:
  build:
    runs-on: [linux, x64, build]
```

Repository package configuration uses the stable service alias:

```text
http://package-mirror:8080
```

The alias remains identical across hosts even though each host runs its own
network and service instance.

## Preserve trust boundaries

Containers on one Docker bridge network can reach each other's exposed ports.
Use a separate service network for each profile or equivalent trust boundary.
Do not attach unrelated trusted and untrusted worker profiles to one shared
network.

One trusted service instance can join several isolated networks under the same
alias. Workers remain separated because each profile joins only its own
network.

For a host-native service, prefer an operator-owned proxy container that joins
the service network and forwards only the required endpoint. PitCrew does not
give workers a generic host-gateway alias.

## Update or roll back

The service network contributes to the worker revision. Changing its source is
rolling-compatible:

1. Provision the replacement network.
2. Attach the service to both old and new networks under the same alias.
3. Update the profile and run `pitcrew-profile-rollout`.
4. Keep both networks until rollout state converges.
5. Remove the service from the old network, then remove that exact
   operator-owned network.

Busy workers retain their original network until their job finishes. New
workers use the target network. Never use `-Refresh`, `-CapacityOnly`, Compose
teardown, or a Docker restart to change this worker contract.
