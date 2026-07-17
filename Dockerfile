# Self-hosted GitHub Actions runner image.
#
# Base: myoung34/github-runner — the most-starred dockerized Actions runner. It
# registers an ephemeral, repo/org/enterprise-scoped runner purely from env vars
# and already bundles a broad OS-level toolchain: PowerShell 7 (jobs that run
# `shell: pwsh`), git, curl/wget, node, python3, gh, sudo, unzip/tar — running as
# root, so jobs that `sudo apt-get install` extra deps work.
#
# `ubuntu-noble` is Ubuntu 24.04 LTS. Do NOT switch to the `latest` tag: it is
# Ubuntu 20.04 (focal), which recent .NET no longer supports. Per-job SDKs (.NET,
# Go, Rust, Hugo, Flutter) are installed at runtime by each workflow's setup-*
# actions, exactly as on GitHub-hosted ubuntu, so they are intentionally absent.
#
# This layer is deliberately thin. The base already provides pwsh; the build-time
# check below turns "the base still ships the tools jobs assume" into a loud build
# failure instead of a silent CI break if a future base tag drops them. Add any
# pool-wide runner tooling here.
FROM myoung34/github-runner:ubuntu-noble

# Build-time invariant: fail loudly if the base ever stops shipping what CI needs.
RUN command -v pwsh >/dev/null && pwsh --version \
 && command -v git  >/dev/null && git  --version \
 && command -v gh   >/dev/null && gh   --version
