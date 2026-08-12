FROM myoung34/github-runner:2.336.0-ubuntu-noble@sha256:c803ddbc5b91961aabf3411c6336cb2c838cdaa2f917f76654c15a1948934817

ARG BUILDKIT_VERSION
ARG BUILDKIT_SHA256_X64
ARG BUILDKIT_SHA256_ARM64
ARG CRANE_VERSION
ARG CRANE_SHA256_X64
ARG CRANE_SHA256_ARM64

COPY pitcrew-build-image /usr/local/bin/pitcrew-build-image

RUN set -eu; \
    case "$(uname -m)" in \
        x86_64) \
            architecture='amd64'; \
            crane_architecture='x86_64'; \
            checksum="${BUILDKIT_SHA256_X64}"; \
            crane_checksum="${CRANE_SHA256_X64}" ;; \
        aarch64|arm64) \
            architecture='arm64'; \
            crane_architecture='arm64'; \
            checksum="${BUILDKIT_SHA256_ARM64}"; \
            crane_checksum="${CRANE_SHA256_ARM64}" ;; \
        *) \
            echo "Unsupported BuildKit client architecture: $(uname -m)" >&2; \
            exit 1 ;; \
    esac; \
    test -n "${BUILDKIT_VERSION}"; \
    test -n "${checksum}"; \
    test -n "${CRANE_VERSION}"; \
    test -n "${crane_checksum}"; \
    archive="buildkit-v${BUILDKIT_VERSION}.linux-${architecture}.tar.gz"; \
    curl -fsSL \
        "https://github.com/moby/buildkit/releases/download/v${BUILDKIT_VERSION}/${archive}" \
        -o /tmp/buildkit.tar.gz; \
    printf '%s  %s\n' "${checksum}" /tmp/buildkit.tar.gz | sha256sum -c -; \
    tar -xzf /tmp/buildkit.tar.gz -C /tmp; \
    install -m 0755 /tmp/bin/buildctl /usr/local/bin/buildctl; \
    crane_archive="go-containerregistry_Linux_${crane_architecture}.tar.gz"; \
    curl -fsSL \
        "https://github.com/google/go-containerregistry/releases/download/v${CRANE_VERSION}/${crane_archive}" \
        -o /tmp/crane.tar.gz; \
    printf '%s  %s\n' "${crane_checksum}" /tmp/crane.tar.gz | sha256sum -c -; \
    tar -xzf /tmp/crane.tar.gz -C /tmp crane; \
    install -m 0755 /tmp/crane /usr/local/bin/crane; \
    chmod 0755 /usr/local/bin/pitcrew-build-image; \
    rm -rf /tmp/bin /tmp/buildkit.tar.gz /tmp/crane /tmp/crane.tar.gz; \
    buildctl --version; \
    crane version
