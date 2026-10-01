# syntax=docker/dockerfile:1
#
# tproxy-server + official MTProxy backend, multi-architecture.
#
# The relay is pure Go and builds anywhere. MTProxy is C and upstream builds it
# x86-only; docker/build-mtproxy.sh drops the x86-only codegen flags on other
# architectures and applies docker/mtproxy-patches/*.patch so the portable table
# implementations are selected at runtime instead of the SSE4.2/PCLMULQDQ ones.
#
# Supported: linux/amd64, linux/arm64.

# ---------------------------------------------------------------- relay ----
FROM --platform=$BUILDPLATFORM golang:1.24-alpine AS relay

WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY cmd/ ./cmd/
COPY internal/ ./internal/

ARG VERSION=dev
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath \
    -ldflags="-s -w" -o /out/tproxy-server ./cmd/tproxy-server
RUN go test ./...

# -------------------------------------------------------------- mtproxy ----
FROM debian:bookworm-slim AS mtproxy

ARG MTPROXY_COMMIT=f36d8af769ffaeac36978d38c2c0f6d1104c2137
ARG MTPROXY_CHECKSUM=919795c416b870670841a21d1930ad97a24c7b84b9eb8c6f9e3de32f2fdf4655

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential ca-certificates curl libssl-dev patch util-linux zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
COPY docker/build-mtproxy.sh /usr/local/bin/build-mtproxy.sh
COPY docker/mtproxy-patches/ /usr/local/share/mtproxy-patches/

# Keep the verified-archive contract from deploy/install-mtproxy.sh: the pinned
# commit is checksummed, so a build can never silently use different sources.
RUN set -eux; \
    mkdir -p /build/src; \
    curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
        --output /build/mtproxy.tar.gz \
        "https://github.com/TelegramMessenger/MTProxy/archive/${MTPROXY_COMMIT}.tar.gz"; \
    echo "${MTPROXY_CHECKSUM}  /build/mtproxy.tar.gz" | sha256sum -c -; \
    tar -C /build/src --strip-components=1 -xzf /build/mtproxy.tar.gz; \
    rm /build/mtproxy.tar.gz

RUN set -eux; \
    chmod +x /usr/local/bin/build-mtproxy.sh; \
    /usr/local/bin/build-mtproxy.sh /build/src /out /usr/local/share/mtproxy-patches; \
    /out/mtproto-proxy --help >/dev/null 2>&1 || true

# Official MTProxy fetches its AES secret and routing table at runtime from
# core.telegram.org. Fetch them at build time so a running container needs no
# egress to bootstrap; refresh-mtproxy-config.sh re-fetches them daily.
RUN set -eux; \
    curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
        --output /out/proxy-secret https://core.telegram.org/getProxySecret; \
    curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
        --output /out/proxy-multi.conf https://core.telegram.org/getProxyConfig; \
    test "$(wc -c < /out/proxy-secret)" -eq 128; \
    test "$(wc -c < /out/proxy-multi.conf)" -ge 100; \
    grep -q '^default ' /out/proxy-multi.conf; \
    grep -q '^proxy_for ' /out/proxy-multi.conf

# ----------------------------------------------------------------- caddy ---
FROM caddy:2-alpine AS caddy

# --------------------------------------------------------------- runtime ---
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl tini \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --create-home --home-dir /var/lib/mtproxy --shell /usr/sbin/nologin mtproxy

COPY --from=relay  /out/tproxy-server  /usr/local/bin/tproxy-server
COPY --from=mtproxy /out/mtproto-proxy  /usr/local/bin/mtproto-proxy
COPY --from=mtproxy /out/proxy-secret  /etc/mtproxy/proxy-secret
COPY --from=mtproxy /out/proxy-multi.conf /etc/mtproxy/proxy-multi.conf
COPY --from=caddy   /usr/bin/caddy      /usr/local/bin/caddy

COPY docker/entrypoint.sh          /usr/local/bin/entrypoint.sh
COPY docker/refresh-mtproxy-config.sh /usr/local/bin/refresh-mtproxy-config.sh
COPY docker/Caddyfile              /etc/caddy/Caddyfile
COPY docker/site/                  /srv/tproxy-site

RUN chmod 0755 /usr/local/bin/entrypoint.sh /usr/local/bin/refresh-mtproxy-config.sh \
    && mkdir -p /etc/tproxy-server \
    && chown -R root:mtproxy /etc/mtproxy \
    && chmod 0640 /etc/mtproxy/proxy-secret /etc/mtproxy/proxy-multi.conf

# The relay and the admin listener stay on loopback inside the container; only
# Caddy is meant to be published. MTProxy's own ports are never published
# either: the relay dials 127.0.0.1:2398 and nothing else needs them.
EXPOSE 80 443

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD curl -fsS http://127.0.0.1:8081/healthz || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
