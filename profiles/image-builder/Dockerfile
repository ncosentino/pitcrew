FROM myoung34/github-runner:2.336.0-ubuntu-noble@sha256:c803ddbc5b91961aabf3411c6336cb2c838cdaa2f917f76654c15a1948934817

ARG BUILDKIT_VERSION
ARG BUILDKIT_SHA256_X64
ARG BUILDKIT_SHA256_ARM64

COPY pitcrew-build-image /usr/local/bin/pitcrew-build-image

RUN set -eu; \
    case "$(uname -m)" in \
        x86_64) \
            architecture='amd64'; \
            checksum="${BUILDKIT_SHA256_X64}" ;; \
        aarch64|arm64) \
            architecture='arm64'; \
            checksum="${BUILDKIT_SHA256_ARM64}" ;; \
        *) \
            echo "Unsupported BuildKit client architecture: $(uname -m)" >&2; \
            exit 1 ;; \
    esac; \
    test -n "${BUILDKIT_VERSION}"; \
    test -n "${checksum}"; \
    archive="buildkit-v${BUILDKIT_VERSION}.linux-${architecture}.tar.gz"; \
    curl -fsSL \
        "https://github.com/moby/buildkit/releases/download/v${BUILDKIT_VERSION}/${archive}" \
        -o /tmp/buildkit.tar.gz; \
    printf '%s  %s\n' "${checksum}" /tmp/buildkit.tar.gz | sha256sum -c -; \
    tar -xzf /tmp/buildkit.tar.gz -C /tmp; \
    install -m 0755 /tmp/bin/buildctl /usr/local/bin/buildctl; \
    chmod 0755 /usr/local/bin/pitcrew-build-image; \
    rm -rf /tmp/bin /tmp/buildkit.tar.gz; \
    buildctl --version
