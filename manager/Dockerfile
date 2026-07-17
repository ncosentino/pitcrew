# Babysitter image: a tiny Docker-CLI container that keeps a pool of truly-
# ephemeral runner containers filled (see manage-runners.sh). It only needs the
# docker client to talk to the host daemon via the mounted socket — it does NOT
# run dockerd itself (the runners are siblings on the host, not nested).
FROM docker:28-cli

ARG JQ_VERSION=1.8.2
ARG TARGETARCH
ARG TARGETVARIANT
ARG JQ_SHA256_AMD64=b1c22172dd303f3be49e935aa56aa48a8b7a46e0bc838b4997d3bb451495870f
ARG JQ_SHA256_ARM64=8b85c817833814ddca00a144c33705546355afccf0cf39b188f3cdb48b852309
ARG JQ_SHA256_ARMEL=d88f6bd640ef8909b3deb587f12c03a0ed38fe8bd5e2e882e2b1bf88f5dab8d2
ARG JQ_SHA256_ARMHF=78458244fb546469b4042e9e07cf78714ef6848895eb9515df76b4eb0b1dc992
ARG JQ_SHA256_I386=ba996e8ce436973e2f39e2639405a37e8c81ba8c722b71c83996278ad0af16dd
ARG JQ_SHA256_PPC64LE=0dba61281e525ced2111bc00c8bd8078100e8822c33bfb35feee95314bbeeea2
ARG JQ_SHA256_RISCV64=a96e5a78a7b2c5a0575bc2a10dda4b20d84efd8c02c8806539ee5f5e57603e8d
ARG JQ_SHA256_S390X=42b3306c786e3352e3097b8aa03ca0e5631bdc7a6bf133bb8ddd9e4b148d20c8

RUN set -eu; \
    architecture="${TARGETARCH:-$(uname -m)}"; \
    case "${architecture}/${TARGETVARIANT}" in \
        amd64/*|x86_64/*) asset='jq-linux-amd64'; checksum="${JQ_SHA256_AMD64}" ;; \
        arm64/*|aarch64/*) asset='jq-linux-arm64'; checksum="${JQ_SHA256_ARM64}" ;; \
        arm/v6|armv6l/*) asset='jq-linux-armel'; checksum="${JQ_SHA256_ARMEL}" ;; \
        arm/v7|arm/*|armv7l/*) asset='jq-linux-armhf'; checksum="${JQ_SHA256_ARMHF}" ;; \
        386/*|i386/*|i686/*) asset='jq-linux-i386'; checksum="${JQ_SHA256_I386}" ;; \
        ppc64le/*) asset='jq-linux-ppc64el'; checksum="${JQ_SHA256_PPC64LE}" ;; \
        riscv64/*) asset='jq-linux-riscv64'; checksum="${JQ_SHA256_RISCV64}" ;; \
        s390x/*) asset='jq-linux-s390x'; checksum="${JQ_SHA256_S390X}" ;; \
        *) echo "Unsupported jq architecture: ${architecture}/${TARGETVARIANT}" >&2; exit 1 ;; \
    esac; \
    attempt=1; \
    until wget -qO /usr/local/bin/jq \
        "https://github.com/jqlang/jq/releases/download/jq-${JQ_VERSION}/${asset}"; do \
        [ "${attempt}" -ge 3 ] && exit 1; \
        sleep "${attempt}"; \
        attempt=$((attempt + 1)); \
    done; \
    printf '%s  %s\n' "${checksum}" /usr/local/bin/jq | sha256sum -c -; \
    chmod 0755 /usr/local/bin/jq; \
    jq --version

COPY reconciliation.sh /usr/local/bin/reconciliation.sh
COPY manage-runners.sh /usr/local/bin/manage-runners.sh
RUN chmod +x /usr/local/bin/manage-runners.sh /usr/local/bin/reconciliation.sh

ENTRYPOINT ["/usr/local/bin/manage-runners.sh"]
