FROM myoung34/github-runner@sha256:5fc9233a610f209154f0b4c997a4529ef13e16ffbd9fa9a35a172a45efd25c78

ARG DOTNET_SDK_VERSION
ARG DOTNET_SDK_SHA512_X64
ARG DOTNET_SDK_SHA512_ARM64
ARG NODE_VERSION
ARG NODE_SHA256_X64
ARG NODE_SHA256_ARM64

ENV DOTNET_ROOT=/usr/share/dotnet \
    DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    DOTNET_NOLOGO=1 \
    DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1 \
    DOTNET_GENERATE_ASPNET_CERTIFICATE=false

RUN set -eu; \
    case "$(uname -m)" in \
        x86_64) \
            dotnet_rid='linux-x64'; \
            dotnet_checksum="${DOTNET_SDK_SHA512_X64}"; \
            node_rid='linux-x64'; \
            node_checksum="${NODE_SHA256_X64}" ;; \
        aarch64|arm64) \
            dotnet_rid='linux-arm64'; \
            dotnet_checksum="${DOTNET_SDK_SHA512_ARM64}"; \
            node_rid='linux-arm64'; \
            node_checksum="${NODE_SHA256_ARM64}" ;; \
        *) \
            echo "Unsupported runner architecture: $(uname -m)" >&2; \
            exit 1 ;; \
    esac; \
    test -n "${DOTNET_SDK_VERSION}"; \
    test -n "${NODE_VERSION}"; \
    test -n "${dotnet_checksum}"; \
    test -n "${node_checksum}"; \
    curl -fsSL \
        "https://builds.dotnet.microsoft.com/dotnet/Sdk/${DOTNET_SDK_VERSION}/dotnet-sdk-${DOTNET_SDK_VERSION}-${dotnet_rid}.tar.gz" \
        -o /tmp/dotnet-sdk.tar.gz; \
    printf '%s  %s\n' "${dotnet_checksum}" /tmp/dotnet-sdk.tar.gz | sha512sum -c -; \
    mkdir -p "${DOTNET_ROOT}"; \
    tar -xzf /tmp/dotnet-sdk.tar.gz -C "${DOTNET_ROOT}"; \
    rm -f /tmp/dotnet-sdk.tar.gz; \
    ln -s "${DOTNET_ROOT}/dotnet" /usr/local/bin/dotnet; \
    curl -fsSL \
        "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-${node_rid}.tar.gz" \
        -o /tmp/node.tar.gz; \
    printf '%s  %s\n' "${node_checksum}" /tmp/node.tar.gz | sha256sum -c -; \
    tar -xzf /tmp/node.tar.gz -C /usr/local --strip-components=1 \
        --exclude CHANGELOG.md --exclude LICENSE --exclude README.md; \
    rm -f /tmp/node.tar.gz; \
    dotnet --list-sdks; \
    node --version; \
    npm --version
