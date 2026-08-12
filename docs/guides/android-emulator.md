---
description: Run disposable hardware-accelerated Android 14 emulator jobs through a typed KVM PitCrew profile.
---

# Android Emulator Runners

The `android-emulator` profile runs Android 14 inside the same disposable container
as the GitHub Actions runner. Each job receives a fresh emulator, runner workspace,
and registration. Docker removes all of them together when the job ends.

The worker remains socketless. It receives only the typed `/dev/kvm` device plus
bounded shared memory and resource limits.

## Host requirements

The built-in profile requires:

- an x86-64 Linux Docker daemon;
- hardware virtualization exposed as `/dev/kvm`;
- enough available memory and CPU for the configured limits; and
- trusted same-repository workflow triggers.

Docker-Android's public Android 14 image is amd64-only. Arm64 hosts fail verification
instead of using emulation or another image silently.

Docker Desktop on Windows can work only when its Linux VM exposes nested
virtualization and `/dev/kvm`. Setup runs image verification with the exact KVM device
before replacing a live manager, so an incompatible host fails without disturbing the
current profile.

## Install the profile

```powershell
.\Setup-Runner.ps1 `
    -Profile android-emulator `
    -Repos https://github.com/example/mobile-project=1
```

The profile defaults to:

- Docker-Android Android 14 release `v3.6.0-p0`, pinned by digest;
- zero idle workers and one active worker maximum;
- 8 GiB memory with no additional swap;
- four CPU cores, 4,096 processes, and 2 GiB shared memory;
- labels `android`, `android-14`, and `android-emulator`; and
- behavior analytics, web VNC, and web log sharing disabled.

Copy the manifest to an external operator-owned profile before adding calibrated
host-admission policy or changing resource limits.

## Run Android tests

```yaml
jobs:
  android:
    runs-on: [linux, x64, android-emulator]
    steps:
      - uses: actions/checkout@v6

      - name: Start Android emulator
        run: start-android-emulator

      - name: Run connected tests
        run: ./gradlew connectedCheck
```

The helper starts the upstream Docker-Android process supervisor as `androidusr`,
forces analytics and web endpoints off, waits for `device_status=READY`, and verifies
Android's `sys.boot_completed` property.

Set supported upstream variables before invoking the helper when a workflow needs a
different device profile:

```yaml
- name: Start Android emulator
  env:
    EMULATOR_DEVICE: Samsung Galaxy S10
    ANDROID_EMULATOR_START_TIMEOUT_SECONDS: 900
  run: start-android-emulator
```

Appium can be enabled for a trusted job with `APPIUM=true`. It remains inside the
worker; PitCrew publishes no Appium, ADB, VNC, or log port to the host.

## Isolation and security

KVM is a host-kernel interface. Use this profile only for trusted workflow code and a
dedicated capability label. Do not enable broad `self-hosted` routing or untrusted
fork pull requests.

The profile does not provide:

- the Docker socket;
- blanket `--privileged`;
- arbitrary devices or Linux capabilities;
- persistent Android data volumes; or
- a shared emulator between jobs.

Enroll the profile in the host's admission namespace with a measured worker cost
before claiming protected physical headroom. The built-in CPU and memory values are
container limits, not proof that the host can safely run a particular concurrency.

## Update and rollback

Android image updates require a reviewed upstream release tag and immutable digest.
Replaying setup builds and verifies the candidate before manager handoff. Existing
assigned workers finish with their original image and runtime policy.

Roll back by restoring the previous PitCrew release or external profile manifest and
replaying the complete setup command. Never remove `/dev/kvm`, change runtime policy,
or force-remove the worker while a job is assigned.
