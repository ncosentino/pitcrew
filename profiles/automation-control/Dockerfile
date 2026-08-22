ARG RUNTIME_IMAGE=mcr.microsoft.com/dotnet/runtime-deps:8.0-noble@sha256:6533e6633f557e0bc2b5c87bc19ba1dc069fd5e38d2703c6d6abadc9fbc378d7

FROM ${RUNTIME_IMAGE} AS git-build

ARG GIT_VERSION
ARG GIT_SHA256

USER root

RUN set -eu; \
    apt-get update; \
    apt-get install --yes --no-install-recommends \
        build-essential \
        curl \
        libcurl4-openssl-dev \
        libssl-dev \
        xz-utils \
        zlib1g-dev; \
    rm -rf /var/lib/apt/lists/*; \
    test -n "${GIT_VERSION}"; \
    test -n "${GIT_SHA256}"; \
    curl --fail --location --retry 5 --retry-delay 2 \
        "https://www.kernel.org/pub/software/scm/git/git-${GIT_VERSION}.tar.xz" \
        --output /tmp/git.tar.xz; \
    printf '%s  %s\n' "${GIT_SHA256}" /tmp/git.tar.xz | sha256sum -c -; \
    mkdir /tmp/git; \
    tar -xJf /tmp/git.tar.xz -C /tmp/git --strip-components=1; \
    make -C /tmp/git -j"$(nproc)" \
        prefix=/opt/git \
        NO_GETTEXT=YesPlease \
        NO_PERL=YesPlease \
        NO_PYTHON=YesPlease \
        NO_RUST=YesPlease \
        NO_TCLTK=YesPlease \
        NO_EXPAT=YesPlease \
        all; \
    make -C /tmp/git \
        prefix=/opt/git \
        NO_GETTEXT=YesPlease \
        NO_PERL=YesPlease \
        NO_PYTHON=YesPlease \
        NO_RUST=YesPlease \
        NO_TCLTK=YesPlease \
        NO_EXPAT=YesPlease \
        install; \
    install -D -m 0644 \
        /tmp/git/COPYING \
        /opt/git/share/licenses/git/COPYING; \
    find /opt/git -type f -perm /111 -exec sh -c \
        'for path do if readelf -h "${path}" >/dev/null 2>&1; then strip --strip-unneeded "${path}"; fi; done' \
        sh {} +

FROM ${RUNTIME_IMAGE}

ARG TARGETARCH
ARG RUNNER_VERSION
ARG RUNNER_SHA256_X64
ARG RUNNER_SHA256_ARM64
ARG GH_VERSION
ARG GH_SHA256_X64
ARG GH_SHA256_ARM64
ARG POWERSHELL_VERSION
ARG POWERSHELL_SHA256_X64
ARG POWERSHELL_SHA256_ARM64

ENV RUNNER_MANUALLY_TRAP_SIG=1 \
    ACTIONS_RUNNER_PRINT_LOG_TO_STDOUT=1 \
    ImageOS=ubuntu24 \
    HOME=/home/runner \
    GH_PAGER=cat \
    GIT_PAGER=cat \
    PAGER=cat \
    PATH=/opt/git/bin:/opt/git/libexec/git-core:/opt/microsoft/powershell/7:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

USER root

COPY --from=git-build /opt/git /opt/git

RUN set -eu; \
    apt-get update; \
    apt-get install --yes --no-install-recommends \
        curl \
        jq \
        libgssapi-krb5-2; \
    rm -rf /var/lib/apt/lists/*; \
    rm -rf \
        /usr/bin/perl \
        /usr/bin/perl5.* \
        /usr/lib/*/perl-base \
        /usr/share/perl*; \
    groupadd --gid 1001 runner; \
    useradd --uid 1001 --gid 1001 --create-home --shell /bin/bash runner; \
    case "${TARGETARCH}" in \
        amd64) \
            runner_architecture='x64'; \
            runner_checksum="${RUNNER_SHA256_X64}"; \
            gh_architecture='amd64'; \
            gh_checksum="${GH_SHA256_X64}"; \
            powershell_architecture='x64'; \
            powershell_checksum="${POWERSHELL_SHA256_X64}" ;; \
        arm64) \
            runner_architecture='arm64'; \
            runner_checksum="${RUNNER_SHA256_ARM64}"; \
            gh_architecture='arm64'; \
            gh_checksum="${GH_SHA256_ARM64}"; \
            powershell_architecture='arm64'; \
            powershell_checksum="${POWERSHELL_SHA256_ARM64}" ;; \
        *) \
            echo "Unsupported automation-control architecture: ${TARGETARCH}" >&2; \
            exit 1 ;; \
    esac; \
    test -n "${RUNNER_VERSION}"; \
    test -n "${runner_checksum}"; \
    test -n "${GH_VERSION}"; \
    test -n "${gh_checksum}"; \
    test -n "${POWERSHELL_VERSION}"; \
    test -n "${powershell_checksum}"; \
    curl --fail --location --retry 5 --retry-delay 2 \
        "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-${runner_architecture}-${RUNNER_VERSION}.tar.gz" \
        --output /tmp/runner.tar.gz; \
    printf '%s  %s\n' "${runner_checksum}" /tmp/runner.tar.gz | sha256sum -c -; \
    install -d -o runner -g runner /actions-runner; \
    tar -xzf /tmp/runner.tar.gz -C /actions-runner; \
    rm -rf \
        /actions-runner/externals/node20_alpine \
        /actions-runner/externals/node24_alpine; \
    find /actions-runner/externals/node20 \
        -mindepth 1 \
        -maxdepth 1 \
        ! -name bin \
        ! -name LICENSE \
        -exec rm -rf {} +; \
    find /actions-runner/externals/node24 \
        -mindepth 1 \
        -maxdepth 1 \
        ! -name bin \
        ! -name LICENSE \
        -exec rm -rf {} +; \
    find /actions-runner/externals/node20/bin \
        -mindepth 1 \
        ! -name node \
        -delete; \
    find /actions-runner/externals/node24/bin \
        -mindepth 1 \
        ! -name node \
        -delete; \
    curl --fail --location --retry 5 --retry-delay 2 \
        "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${gh_architecture}.tar.gz" \
        --output /tmp/gh.tar.gz; \
    printf '%s  %s\n' "${gh_checksum}" /tmp/gh.tar.gz | sha256sum -c -; \
    tar -xzf /tmp/gh.tar.gz -C /tmp; \
    install -m 0755 \
        "/tmp/gh_${GH_VERSION}_linux_${gh_architecture}/bin/gh" \
        /usr/local/bin/gh; \
    install -D -m 0644 \
        "/tmp/gh_${GH_VERSION}_linux_${gh_architecture}/LICENSE" \
        /usr/share/licenses/gh/LICENSE; \
    curl --fail --location --retry 5 --retry-delay 2 \
        "https://github.com/PowerShell/PowerShell/releases/download/v${POWERSHELL_VERSION}/powershell-${POWERSHELL_VERSION}-linux-${powershell_architecture}.tar.gz" \
        --output /tmp/powershell.tar.gz; \
    printf '%s  %s\n' "${powershell_checksum}" /tmp/powershell.tar.gz | sha256sum -c -; \
    install -d /opt/microsoft/powershell/7; \
    tar -xzf /tmp/powershell.tar.gz -C /opt/microsoft/powershell/7; \
    chmod 0755 /opt/microsoft/powershell/7/pwsh; \
    ln -s /opt/microsoft/powershell/7/pwsh /usr/local/bin/pwsh; \
    rm -rf \
        /tmp/runner.tar.gz \
        /tmp/gh.tar.gz \
        "/tmp/gh_${GH_VERSION}_linux_${gh_architecture}" \
        /tmp/powershell.tar.gz; \
    chown -R runner:runner /actions-runner /home/runner; \
    test -x /actions-runner/bin/Runner.Listener; \
    test -x /actions-runner/externals/node20/bin/node; \
    test -x /actions-runner/externals/node24/bin/node; \
    test ! -e /actions-runner/externals/node20_alpine; \
    test ! -e /actions-runner/externals/node24_alpine; \
    test ! -e /actions-runner/externals/node20/lib/node_modules; \
    test ! -e /actions-runner/externals/node24/lib/node_modules; \
    git --version; \
    gh --version; \
    jq --version; \
    pwsh -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'

WORKDIR /actions-runner
USER runner
