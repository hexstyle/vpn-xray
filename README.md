# vpn-xray

Portable OpenWrt bundle for a GL.iNet child router that forwards client TCP traffic to a VPS over `VLESS + Reality`, with no proxy settings on client devices.

This repository is intentionally sanitized:

- no live router IPs
- no live VPS IPs
- no live UUIDs / Reality keys / passwords
- no tracked local `.env` files

Everything that must be personalized is supplied through local untracked env files created from examples.

## Start Here

- [Audit](./docs/AUDIT.md)
- [Agent Runbook](./docs/AGENT-RUNBOOK.md)
- [Architecture](./docs/ARCHITECTURE.md)
- [Shared Rules](./docs/SHARED-RULES.md)
- [Web UI](./docs/WEB-UI.md)
- [Sanitized Validation Matrix](./docs/CURRENT-LAB-STATE.md)
- [UI Extensibility Notes](./docs/UI-EXTENSIBILITY.md)

## What This Bundle Provides

- deploys `xray-core 26.3.27` to the child router
- deploys `redsocks` and `libevent2-core7`
- installs OpenWrt init scripts for `codex-xray`, `codex-transproxy`, `xray-switch-watchdog`, and `router-rules-sync`
- keeps the GL hardware switch as the source of truth for `path on/off`
- provides a standalone admin page at `https://<router>/xray.html`
- manages VPS profiles on the router through an SSH-first flow
- supports shared destination rules through an operator-owned GitHub repo
- supports two consumers for the shared list:
  - GL selective routing via `dnsmasq -> ipset`
  - ASUS `shadowsocks-libev dst_ips_forward`

## Mandatory Local Files

Create these untracked files before you start:

```bash
cp config/vps.env.example config/vps.env
cp config/router.env.example config/router.env
# optional, only if you also deploy the ASUS consumer
cp config/asus-router.env.example config/asus-router.env
```

These local `.env` files are ignored by git.

Required values are enforced. The deploy scripts fail fast if placeholders remain.

Validate them explicitly before deploy:

```bash
./scripts/validate-env.sh vps
./scripts/validate-env.sh router
# optional
./scripts/validate-env.sh asus
```

## Quick Start

1. Fill `config/vps.env`.
2. Fill `config/router.env`.
3. Deploy the VPS:

```bash
./scripts/deploy-vps-config.sh
```

4. Deploy the GL router:

```bash
./scripts/deploy-child-router.sh
```

5. Verify the GL router:

```bash
./scripts/verify-child-router.sh
```

6. If you also need the ASUS shared-rules consumer:

```bash
./scripts/deploy-asus-rules.sh
```

## Required Parameters

Values you must replace in local env files:

- router management host
- router LAN address
- home/admin subnet
- VPS host
- Xray UUID
- Reality public/private key pair
- Reality short ID
- SNI / camouflage host
- shared-rules GitHub repo URLs
- router device IDs used by the shared-rules sync layer

Values already pinned here and normally reused as-is:

- `xray-core 26.3.27`
- GL package URLs and checksums for `redsocks` / `libevent`
- default ports `1083 / 1084 / 12345`
- default sync interval `30s`

## Verification Targets

Prefer these checks:

- `https://www.google.com`
- `https://ifconfig.me/ip`
- `https://ipinfo.io/ip`
- `https://api.openai.com/v1/models`

Do not use `chatgpt.com` as the success criterion. VPS IP reputation can still trigger Cloudflare challenge even when the transport path is healthy.

## Shared Rules Model

The shared rules repo is external to this repo and operator-owned.

Expected shape:

- one GitHub repo chosen by the operator
- canonical file at `lists/shared-targets.txt`
- one non-comment rule per line
- supported rule types:
  - domain
  - IPv4
  - IPv4 CIDR

Behavior:

- `full` mode on GL sends all LAN TCP through the VPS path
- `selective` mode on GL routes:
  - literal IP/CIDR by `ipset`
  - domains dynamically by `dnsmasq -> ipset`
- ASUS consumes a resolved IPv4 snapshot because `shadowsocks-libev` cannot match domains directly

## Operational Constraints

- Do not connect the child router to the same parent network by both `LAN-LAN` and `Wi-Fi repeater` at the same time.
- Domain-based selective routing on GL depends on clients using the router DNS path.
- Already-open TCP sessions do not jump to a new routing decision mid-flight; new rules fully dominate only after the relevant DNS/cache/connection state turns over.
- The rules sync loop runs every `30s` by default and avoids redundant runtime work when GitHub and the applied ruleset already match.

## Reproducibility Notes

- `config/router.env.example`, `config/vps.env.example`, and `config/asus-router.env.example` are the public templates.
- `scripts/validate-env.sh` is the preflight gate.
- `scripts/deploy-vps-config.sh`, `scripts/deploy-child-router.sh`, and `scripts/deploy-asus-rules.sh` are the supported entrypoints.
- `scripts/register-router-rules-deploy-key.sh` bootstraps the router deploy key for the shared-rules GitHub repo.

## File Map

- `config/router.env.example`: child-router template
- `config/vps.env.example`: VPS template
- `config/asus-router.env.example`: ASUS shared-rules template
- `scripts/validate-env.sh`: placeholder / required-field validation
- `scripts/deploy-vps-config.sh`: deploy VPS `xray` config
- `scripts/deploy-child-router.sh`: deploy GL router runtime, web UI, and shared-rules consumer
- `scripts/deploy-asus-rules.sh`: deploy ASUS shared-rules consumer
- `scripts/verify-child-router.sh`: smoke-test the GL proxy path
- `router-files/router-rules`: shared-rules sync / merge / apply tool
- `router-files/xray.html`: standalone admin page
- `router-files/xray-admin.cgi`: runtime / logs / smoke backend
- `router-files/xray-vps.cgi`: VPS-profile / SSH-first backend
- `router-files/xray-rules.cgi`: shared-rules backend

## Publication Note

Before publishing, this repository was audited and converted to a sanitized, placeholder-driven shape. If a future agent adds tracked live values again, that is a regression.
