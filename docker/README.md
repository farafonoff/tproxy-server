# Container deployment

Runs the relay, official MTProxy and Caddy in one container, published through
a Cloudflare Tunnel so no public IP address and no inbound 80/443 are needed.

This is a fork of `telegramdesktop/tproxy-server`. Two things differ from the
upstream `deploy/install.sh` reference layout:

1. **The backend builds on any architecture.** Upstream requires x86_64 because
   official MTProxy hardcodes x86 codegen flags and SSE4.2/PCLMULQDQ intrinsics.
   See [Cross-architecture builds](#cross-architecture-builds).
2. **No systemd, nftables, or ACME certificate.** A container cannot own the
   host's firewall or its port 80, so the firewall rule and the Caddy TLS mode
   are replaced accordingly. Only Caddy binds a published port.

## Quick start

```bash
scripts/gen-env.sh          # .env with a fresh secret and a detected NAT pair
$EDITOR .env                # set TPROXY_HOSTNAME and TUNNEL_TOKEN
docker compose up -d --build
```

Add the public hostname to the tunnel (Zero Trust -> Networks -> Tunnels -> your
tunnel -> Public hostnames):

| hostname | type | service |
| --- | --- | --- |
| your hostname | HTTP | `http://tproxy:80` |

```bash
docker compose --profile tunnel up -d
```

The hostname must be exactly `TPROXY_HOSTNAME`: the relay derives the bridge
capability from the hostname and the secret, so a client configured with any
other host derives a different capability and sees the public site instead of
the bridge.

## Verifying

```bash
# inside the container, over the loopback admin listener
docker compose exec tproxy curl -sS http://127.0.0.1:8081/healthz
docker compose exec tproxy curl -sS http://127.0.0.1:8081/readyz
docker compose exec tproxy curl -sS http://127.0.0.1:8081/metrics

# the public site, and the anti-probing property: a wrong capability must be
# byte-identical to the site, and an authentic one in a noncanonical query
# must 404
docker compose exec tproxy sh -c 'curl -s -o /dev/null -w "%{http_code} %{size_download}\n" -H "Host: $TPROXY_HOSTNAME" http://127.0.0.1:8080/'
docker compose exec tproxy sh -c 'curl -s -o /dev/null -w "%{http_code} %{size_download}\n" -H "Host: $TPROXY_HOSTNAME" "http://127.0.0.1:8080/?bridge=wrong"'
```

MTProxy reaches Telegram lazily, on the first client stream. The only failure
that produces no error anywhere is the NAT one, so check the middle-end
directly:

```bash
docker compose logs tproxy | grep -c 'Disconnected from RPC Middle-End'
```

A steady non-zero count means MTProxy is announcing an address Telegram never
sees arrivals from. See [The NAT trap](#the-nat-trap).

## Configuration

All of it lives in `.env`; see `.env.example`.

| variable | meaning |
| --- | --- |
| `TPROXY_HOSTNAME` | **required.** The hostname clients are configured with. |
| `TPROXY_SECRET` | **required.** `openssl rand -hex 16`. The client-facing secret. |
| `TPROXY_BASE_PATH` | optional. Moves the bridge off the site root. |
| `TPROXY_CARRIER_MODE` | `https` (default), `https-lanes`, `websocket`, `websocket-lanes`. |
| `TPROXY_NAT_INFO` | `<local>:<public>` for MTProxy's middle-end. See below. |
| `TPROXY_PUBLIC_UPSTREAM` | delegate the site to a loopback app instead of `/srv/tproxy-site`. |
| `TPROXY_SITE_ADDRESS` | `http://:80` for a tunnel, `https://HOSTNAME` for direct. |
| `MTPROXY_WORKERS` / `MTPROXY_MAX_CONNECTIONS` | backend process limits. |

## The NAT trap

MTProxy derives the AES keys for its middle-end session from its own **source
address**. Behind any NAT - including a container bridge, 1:1 NAT, or a cloud
instance - the address MTProxy sees is not the one Telegram sees, the two sides
derive different keys, and every middle-end connection is dropped right after
the handshake.

This fails silently. Clients complete the obfuscated2 handshake, the relay
accepts streams and grants `WINDOW`, and then every stream stalls forever with
no error on any layer. `TPROXY_NAT_INFO=<local>:<public>` fixes it;
`scripts/gen-env.sh` fills it in by default.

## The public site

The relay must serve the whole hostname and stay the single gateway, so there
is deliberately no separately hosted path around it. Two modes:

- **Static** (default) - mount your own site over `/srv/tproxy-site`. The relay
  reads it into memory once at start.
- **Application** - set `TPROXY_PUBLIC_UPSTREAM=http://127.0.0.1:3000` and run
  an app on a loopback port. See `PUBLIC_SITE.md`.

Exactly one of the two must be set or the relay refuses to start.

`docker/site/index.html` is a placeholder, not a real site. The upstream project
ships none on purpose: many operators deploying the same starter page would give
active probers a reliable fingerprint. Replace it before real use.

## Cross-architecture builds

The image builds on `linux/amd64` and `linux/arm64`.

The relay is Go and builds anywhere. The backend is C, and official MTProxy is
x86-only:

- `Makefile` hardcodes `-march=core2 -mfpmath=sse -mssse3 -mpclmul`.
- `common/crc32.c` and `common/crc32c.c` implement CRC-32 and CRC-32C with
  SSE4.2 and PCLMULQDQ, gated on `__LP64__` - which is *also* true on aarch64.
- `common/precise-time.h` defines `rdtsc()` for i386 and x86_64 only.
- `common/server-functions.h` defines `mfence()` with inline x86 assembly.
- `common/cpuid.c` includes GCC's x86-only `<cpuid.h>`.
- `net/net-events.c` includes the i386-only `<sys/io.h>` (unused).

`docker/build-mtproxy.sh` handles this: it drops the x86-only codegen flags on
other architectures and applies `docker/mtproxy-patches/*.patch`, which gate the
SIMD fast paths on `__x86_64__` and supply aarch64 equivalents (`cntvct_el0` for
`rdtsc`, `__atomic_thread_fence` for `mfence`, a `kdb_cpuid()` stub reporting no
SIMD).

This loses throughput, not correctness. Both CRC implementations already select
between the SIMD and the portable table path **at runtime** via CPUID, so on
aarch64 the stub simply makes them choose the table path, which is plain C and
always correct. Verified on aarch64 against reference vectors:

```
crc32  = ce0c5114   (matches zlib.crc32)
crc32c = 3c18f4d6   (matches the Castagnoli reference)
```

A native aarch64 fast path (`crc32cx` and PMULL) would restore the throughput.
That is an optimization, not a port.

The patches apply to the pinned, checksummed MTProxy commit
`f36d8af769ffaeac36978d38c2c0f6d1104c2137`, so a non-x86 build is reproducible
from the same verified archive the x86 build uses. Upstreaming them to
`TelegramMessenger/MTProxy` is the durable fix.

## Security notes

* Only Caddy is published, and compose binds it to `127.0.0.1`. The relay
  (8080/8081) and MTProxy (2398/8888) listen on loopback **inside the container
  only**; nothing else needs to reach them.
* Do not put this hostname behind Cloudflare Access, a CDN, or any other proxy
  in the first deployment: the relay derives its capability from the hostname,
  and an extra hop in front of it changes what the client sees.
* Do not enable access logging of raw URIs on Caddy or the relay. The bridge URL
  carries the derived capability, and the WebSocket carrier's session bearer
  travels in `Sec-WebSocket-Protocol`.
* `TPROXY_SECRET` is the only thing protecting the relay. `.env` is mode 0600
  and gitignored.
* Back up `tproxy-config:/etc/tproxy-server/token.key` and keep it unchanged
  across restarts. A missing or permissive key fails startup; no ephemeral key
  is generated, because rotating it would invalidate live sessions.

## Layout

```
Dockerfile                       multi-stage, both architectures
docker-compose.yml               relay + MTProxy + Caddy (+ tunnel profile)
docker/build-mtproxy.sh          arch-aware MTProxy build
docker/mtproxy-patches/          aarch64 patches for the pinned commit
docker/entrypoint.sh             renders config, supervises the three processes
docker/Caddyfile                 site address, TLS mode, single gateway
docker/refresh-mtproxy-config.sh daily routing-data refresh
docker/site/                     placeholder site (replace it)
scripts/gen-env.sh               .env with a fresh secret and NAT pair
```
