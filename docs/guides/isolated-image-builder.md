---
description: Build and publish OCI images from a socketless PitCrew worker through an isolated mTLS BuildKit service.
---

# Isolated Image Builder

The `image-builder` profile builds and publishes OCI images without giving workflow
code the PitCrew host's Docker socket. Its worker contains `buildctl` and reaches one
operator-owned BuildKit daemon through the profile's isolated service network.

This lane is for Dockerfile builds and image publication. It does not support Docker
Compose, Testcontainers, service containers, or integration tests whose bind mounts
must resolve on the runner's Docker daemon.

## Architecture

```text
GitHub job
  -> disposable image-builder worker
  -> mTLS BuildKit API on pitcrew-image-builder network
  -> isolated build daemon
  -> OCI registry
```

The BuildKit daemon is never the PitCrew orchestration daemon. Workers receive no
Docker socket and no generic Docker API.

BuildKit commonly requires elevated daemon-host capabilities. Run it on a dedicated
builder host or virtual machine. If the BuildKit container shares a Docker daemon with
PitCrew, dedicate that entire host to the image-builder trust boundary.

## Provision the service boundary

Create the profile network:

```powershell
docker network create --driver bridge pitcrew-image-builder
```

Configure BuildKit 0.32.2 with a TCP listener protected by mutual TLS:

```toml
root = "/var/lib/buildkit"

[grpc]
  address = [ "tcp://0.0.0.0:1234" ]
  [grpc.tls]
    cert = "/certs/server-cert.pem"
    key = "/certs/server-key.pem"
    ca = "/certs/ca.pem"

[history]
  maxAge = 60
  maxEntries = 1

[worker.oci]
  enabled = true
  gc = true
  max-parallelism = 1
```

Attach the daemon or an operator-owned TLS passthrough proxy to
`pitcrew-image-builder` with network alias `buildkitd`. Do not publish port 1234 to
the host or attach the service to a manager Compose network.

Keep the CA private key and server private key outside PitCrew. Give workflows only a
client CA certificate, client certificate, and client key through GitHub secrets.

## Install the profile

```powershell
.\Setup-Runner.ps1 `
    -Profile image-builder `
    -Repos https://github.com/example/project=1
```

The profile:

- omits broad default labels;
- accepts `runs-on: [linux, x64, image-builder]`;
- permits one active worker across all configured repository targets;
- verifies BuildKit client version 0.32.2 by checksum; and
- requires the exact `pitcrew-image-builder` service network before replacing a
  manager.

## Publish an image

Materialize the client certificate bundle into a job-private directory containing
`ca.pem`, `cert.pem`, and `key.pem`, then call:

```bash
export BUILDKIT_HOST=tcp://buildkitd:1234
export BUILDKIT_TLS_DIR="$RUNNER_TEMP/buildkit-tls"

immutable_ref="$(
  pitcrew-build-image \
    ghcr.io/example/project:candidate \
    . \
    .
)"

printf 'Published %s\n' "$immutable_ref"
```

`pitcrew-build-image`:

1. rejects missing mTLS material;
2. removes cache and unpinned history from a prior interrupted job;
3. sends the local context to BuildKit;
4. pushes the image;
5. validates the returned `sha256` digest; and
6. removes cache and history again on exit.

The profile's aggregate maximum is one because cache pruning is a profile-wide job
boundary. Increasing concurrency requires independent BuildKit daemons and profiles;
do not let concurrent jobs prune one shared daemon.

Registry authentication remains job-scoped. Configure `$DOCKER_CONFIG` inside the
worker and remove it before the job exits. Never put registry credentials in the
profile, image, BuildKit daemon configuration committed to this repository, or
observed state.

## Validate isolation

Before production use, prove:

- a client without the expected certificate is rejected;
- `/var/run/docker.sock` is absent inside the worker;
- the published registry digest matches BuildKit metadata;
- `buildctl du` is empty after the helper exits;
- a cancelled build is cleaned by the next job's preflight; and
- no service administration endpoint is reachable from unrelated profiles.

## Update and rollback

BuildKit client changes are normal worker-image changes. Review the version and
checksums, then replay the complete profile command. Busy workers finish on the prior
image.

Roll back by restoring the previous profile manifest or PitCrew release and replaying
the complete setup command. BuildKit daemon upgrades remain operator-owned and should
be rolled independently after saving their exact configuration and state policy.
