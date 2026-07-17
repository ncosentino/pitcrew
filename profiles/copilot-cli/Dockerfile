FROM myoung34/github-runner:ubuntu-noble

ARG COPILOT_CLI_VERSION
ARG COPILOT_CLI_SHA256_X64
ARG COPILOT_CLI_SHA256_ARM64

RUN set -eu; \
    case "$(uname -m)" in \
        x86_64) \
            asset='copilot-linux-x64.tar.gz'; \
            checksum="${COPILOT_CLI_SHA256_X64}" ;; \
        aarch64|arm64) \
            asset='copilot-linux-arm64.tar.gz'; \
            checksum="${COPILOT_CLI_SHA256_ARM64}" ;; \
        *) \
            echo "Unsupported runner architecture: $(uname -m)" >&2; \
            exit 1 ;; \
    esac; \
    test -n "${COPILOT_CLI_VERSION}"; \
    test -n "${checksum}"; \
    curl -fsSL \
        "https://github.com/github/copilot-cli/releases/download/v${COPILOT_CLI_VERSION}/${asset}" \
        -o /tmp/copilot.tar.gz; \
    printf '%s  %s\n' "${checksum}" /tmp/copilot.tar.gz | sha256sum -c -; \
    tar -xzf /tmp/copilot.tar.gz -C /tmp; \
    install -m 0755 /tmp/copilot /usr/local/bin/copilot; \
    rm -f /tmp/copilot /tmp/copilot.tar.gz; \
    copilot --version
