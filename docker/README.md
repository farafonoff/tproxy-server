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

## Requirements

The relay, the site and the tunnel work anywhere. **The backend does not.** It
needs a host whose public IPv4 is either on an interface or behind a 1:1 NAT
that preserves the source port - a VPS, a cloud instance, a dedicated server.

A Cloudflare Tunnel solves *inbound* reachability, which is what this
deployment needed most, but it does nothing for the *outbound* middle-end. If
your host is behind CGNAT or any other port-rewriting NAT, everything will start
and look healthy while no Telegram traffic ever flows. Check
[Port-rewriting NAT](#port-rewriting-nat-this-cannot-work-behind-cgnat) before
debugging anything else; it is the most common way this fails.

## Quick start

```bash
scripts/preflight.sh         # can this host carry Telegram traffic at all?
scripts/gen-env.sh           # .env with a fresh secret; warns if it cannot
$EDITOR .env                 # set TPROXY_HOSTNAME and TUNNEL_TOKEN
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
| `TPROXY_PUBLIC_IP` | the public IPv4 Telegram sees this host arriving from. See below. |
| `TPROXY_PUBLIC_UPSTREAM` | delegate the site to a loopback app instead of `/srv/tproxy-site`. |
| `TPROXY_SITE_ADDRESS` | `http://:80` for a tunnel, `https://HOSTNAME` for direct. |
| `MTPROXY_WORKERS` / `MTPROXY_MAX_CONNECTIONS` | backend process limits. |

## Port-rewriting NAT: this cannot work behind CGNAT

**Read this before deploying anywhere unusual.** Official MTProxy mixes the
endpoints' **IP addresses *and* ports** into the AES key that protects its
middle-end handshake (`net/net-crypto-aes.c`, `aes_create_keys`):

```c
*((unsigned *)(str + 36))       = server_ip;
*((unsigned short *)(str + 40)) = client_port;
*((unsigned *)(str + 48))       = client_ip;
*((unsigned short *)(str + 52)) = server_port;
```

MTProxy's only translation facility is `nat_translate_ip()`
(`net/net-connections.c`). There is no port equivalent anywhere in the codebase,
and every call site passes `c->our_port` / `c->remote_port` through unmodified.

That gives three cases:

| network | port preserved? | works? |
| --- | --- | --- |
| public address on the interface | yes | yes, no `--nat-info` needed |
| 1:1 / static NAT (EC2, GCE) | yes | yes, `--nat-info` fixes the address |
| **CGNAT / symmetric NAT** | **no** | **no - not fixable** |

Behind CGNAT the carrier also rewrites the **source port** to a random high
port. The DC hashes the port it observed, MTProxy hashes the port it chose, and
no configuration can bridge that. The handshake completes, the reply goes out,
and the DC closes the connection because it cannot decrypt it.

The symptom is silent and easy to misread. `readyz` stays 200, the container
stays healthy, clients connect, streams open, and no data ever comes back. The
only real signal, at `-v -v -v -v`, is a steady stream of:

```
Disconnected from RPC Middle-End (fd=25)
```

Confirm your situation before spending time on anything else:

```bash
scripts/preflight.sh
```

It reports the public and local addresses, detects CGNAT from either the public
address or a `100.64.0.0/10` local address, and explains the consequence.

If the public address is not listed on any interface, and your egress is a
`100.64.0.0/10` address (RFC 6598 carrier-grade NAT), this deployment cannot
carry Telegram traffic. Use a VPS with a public IPv4 on the interface.

`TPROXY_PUBLIC_IP` exists for the 1:1-NAT case, where the address must be
corrected. The entrypoint pairs it with this container's own address - the first
half has to match the address MTProxy sees on its own socket, and inside a
container that is the container address, not the host's - and detects the public
side at startup when it is left empty.

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
scripts/preflight.sh               can this host carry Telegram traffic at all?
scripts/gen-env.sh                 .env with a fresh secret; warns if it cannot
```
