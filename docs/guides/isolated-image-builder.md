---
description: Build, verify, and publish OCI images from socketless PitCrew workers through a rootless same-host BuildKit service.
---

# Isolated Image Builder

The `image-builder` profile builds OCI images without giving workflow code the
PitCrew host's Docker socket. Disposable workers contain `buildctl`, `crane`, and
`pitcrew-build-image`; a rootless BuildKit service performs build execution on the
same Docker host.

This lane supports Dockerfile build verification and image publication. It does not
provide Docker Compose, Testcontainers, service containers, or a generic Docker API.

## Architecture

```text
GitHub job
  -> disposable image-builder worker
  -> mTLS on pitcrew-image-builder network
  -> rootless BuildKit service
  -> optional OCI registry
```

The service runs as UID 1000 and receives no Docker socket or host port. Dockerfile
build processes run inside the BuildKit container and see only the context streamed
by `buildctl`; they cannot read the Actions runner filesystem or registration state.

## Host prerequisites

Rootless BuildKit requires unprivileged user namespaces. On Ubuntu 24.04 or later,
the host may require:

```text
kernel.apparmor_restrict_unprivileged_userns=0
```

The service uses exactly:

```text
seccomp=unconfined
apparmor=unconfined
systempaths=unconfined
```

It never uses `--privileged` or `--oci-worker-no-process-sandbox`. If these rootless
settings cannot start successfully, qualification fails; do not substitute
privileged BuildKit on a shared PitCrew node.

## Generate service and client certificates

Run from the PitCrew checkout:

```powershell
$certificates = .\services\image-builder\New-PitCrewBuildKitCertificates.ps1 `
    -OutputDirectory <operator-owned-certificate-directory>
```

The script creates:

```text
authority/ca.pem
authority/ca-key.pem
server/ca.pem
server/server-cert.pem
server/server-key.pem
client/ca.pem
client/cert.pem
client/key.pem
```

It prints paths, expiry, and certificate fingerprints but never private material.
Keep `authority` and `server` outside repositories and GitHub. Store only the three
`client` files as protected, job-scoped repository secrets.

## Start the rootless service

```powershell
.\services\image-builder\Setup-PitCrewImageBuilderService.ps1 `
    -ServerCertificateDirectory $certificates.serverDirectory
```

The setup script:

- creates or validates `pitcrew-image-builder`;
- creates the exact state volume and an immutable certificate volume keyed by the
  server certificate fingerprint;
- imports only server material into the certificate volume;
- starts the pinned rootless BuildKit Compose service;
- verifies that it is healthy, non-privileged, socketless, and attached only to the
  intended network; and
- preserves service state and certificates when stopped.

The service remains running while Actions workers scale to zero.
Certificate rotation creates a new volume and force-recreates the service. A failed
replacement restores the previously recorded certificate volume before returning an
error.

Stop it only after the image-builder profile has no active workers:

```powershell
.\services\image-builder\Setup-PitCrewImageBuilderService.ps1 -Down
```

## Install the worker profile

```powershell
.\Setup-Runner.ps1 `
    -Profile image-builder `
    -Repos https://github.com/example/project=1
```

The effective GitHub labels include `linux`, the host architecture,
`image-builder`, and `oci-builder`. The profile permits one active worker across all
targets because cleanup applies to the entire BuildKit daemon.

An operator may add a repository-specific alias while preserving built-in labels:

```powershell
.\Setup-Runner.ps1 `
    -Profile image-builder `
    -Labels 'oci-builder,project-image-builder' `
    -Repos https://github.com/example/project=1
```

## Materialize job credentials

Create a job-private directory containing `ca.pem`, `cert.pem`, and `key.pem`, then
set:

```bash
export BUILDKIT_HOST=tcp://buildkitd:1234
export BUILDKIT_TLS_DIR="$RUNNER_TEMP/buildkit-tls"
export DOCKER_CONFIG="$RUNNER_TEMP/docker-config"
```

Use an `if: always()` step to delete both directories. Never upload them as artifacts,
print them, or include them in profile state.

## Verify a pull request without publishing

```bash
pitcrew-build-image \
  --image-ref ghcr.io/example/project:candidate \
  --context . \
  --dockerfile . \
  --platform linux/amd64 \
  --build-arg SDK_VERSION=1.2.3 \
  --output-oci "$RUNNER_TEMP/project-verification.tar"
```

This builds the Dockerfile, writes an OCI tarball, verifies its digest with `crane`,
and creates no registry tag. Put toolchain assertions inside the Dockerfile so the
build itself proves the resulting image contract.

## Publish and verify an immutable image

After materializing job-scoped registry authentication:

```bash
immutable_ref="$(
  pitcrew-build-image \
    --image-ref ghcr.io/example/project:sha-"$GITHUB_SHA" \
    --context . \
    --dockerfile . \
    --platform linux/amd64 \
    --build-arg SDK_VERSION=1.2.3 \
    --label org.opencontainers.image.revision="$GITHUB_SHA" \
    --push \
    --verify-registry
)"

printf 'Published %s\n' "$immutable_ref"
```

The helper compares BuildKit metadata with the registry digest returned by pinned
`crane`. A mismatch fails the job.

Build arguments with secret-shaped names are rejected. Use BuildKit secret mounts for
future secret-bearing build inputs; do not pass secrets as ordinary build arguments.

## Qualification

Before enabling a repository workflow, prove:

- the service runs as UID 1000 and is not privileged;
- all three required security options are present;
- an authenticated client connects and a CA-only client is rejected;
- `/var/run/docker.sock` and the server private key are absent inside workers;
- an unrelated profile cannot resolve `buildkitd`;
- literal build arguments and labels are not shell-expanded;
- pull-request mode produces an OCI tarball and no registry tag;
- push mode returns the same digest as the registry;
- `buildctl du` is empty after each job; and
- the next job removes cache/history left by an interrupted predecessor.

## Update and rollback

Update PitCrew through the published release and replay the service setup plus profile
setup. Existing assigned workers finish naturally.

If qualification fails:

1. keep repository image-builder workflows disabled;
2. stop or drain the exact image-builder profile;
3. stop the service without deleting its volumes;
4. retain service logs, configuration, certificate fingerprints, and state for
   diagnosis; and
5. restore the prior workflow and PitCrew release.
