# vpn-xray

`vpn-xray` is a practical wrapper around [Xray-core](https://github.com/XTLS/Xray-core) for supported router and VPS profiles.

<img src="./docs/assets/gl-mt3000-router.jpg" alt="GL.iNet GL-MT3000 travel router" width="420">

The reference device in this repository is the compact `GL.iNet GL-MT3000` travel router shown above. It runs from `5V`, can be powered from a Mac over USB, and is easy to keep in a bag as a personal network edge. The physical switch visible on the front edge is the source of truth for `path on / path off`.

The main use case is split routing from a work laptop: keep normal traffic on the ordinary uplink, but send selected destinations through your own VPS instead of through a corporate VPN. That is useful when you need stable access to specific external services, including foreign LLM agents, without touching proxy settings on the client. If your current VPS is blocked or lost, the router UI can read another reachable Debian VPS over SSH and move the Xray config there quickly.

## Thanks

This project stands on top of upstream work from:

- [Xray-core](https://github.com/XTLS/Xray-core)
- [OpenWrt](https://openwrt.org/)
- [GL.iNet](https://www.gl-inet.com/)

See [NOTICE.md](./NOTICE.md) for attribution and scope.

## Supported Profiles

Current supported combinations are intentionally explicit:

- Router profiles:
  - [`gl-mt3000-glinet`](./routers/gl-mt3000-glinet/README.md)
- VPS profiles:
  - [`debian-13`](./vps/debian-13/README.md)

The repository is structured so more profiles can be added later under [`routers/`](./routers/README.md) and [`vps/`](./vps/README.md) without changing the top-level flow.

## What This Wrapper Gives You

- transparent TCP forwarding for client devices with no proxy settings on the clients
- `VLESS + Reality` transport over your own VPS
- router-side web UI at `https://<router-host>/xray.html`
- SSH-first provisioning and switching between saved VPS profiles
- local `full` and `selective` routing modes on the router
- optional GitHub-backed list of domains / IPv4 / CIDR for selective routing

## Hello World

1. Create local config files:

```bash
cp config/router.env.example config/router.env
cp config/vps.env.example config/vps.env
```

2. Edit only these two values:

- `config/router.env`
  - `ROUTER_SSH`
- `config/vps.env`
  - `VPS_SSH`

3. Run the full install:

```bash
./scripts/install-stack.sh
```

That script will:

- derive router and VPS hostnames from the SSH targets
- generate the Xray UUID, Reality keypair, short ID, and default SNI automatically
- validate the generated config
- deploy the VPS config
- deploy the router runtime and UI
- run a post-deploy verification pass

4. Open the router UI:

- `https://<router-host>/xray.html`

## Main Docs

- [Documentation Index](./docs/README.md)
- [Setup Runbook](./docs/SETUP-RUNBOOK.md)
- [Current Supported State](./docs/CURRENT-LAB-STATE.md)
- [Web UI](./docs/WEB-UI.md)
- [Shared Rules](./docs/SHARED-RULES.md)
- [Architecture](./docs/ARCHITECTURE.md)

## Repository Layout

- [`config/`](./config/README.md)
  - local `.env` templates and quickstart notes
- [`scripts/`](./scripts/README.md)
  - entrypoints such as `install-stack.sh`, deploy, verify, and validation scripts
- [`routers/`](./routers/README.md)
  - router profiles, router-side files, and future firmware targets
- [`vps/`](./vps/README.md)
  - VPS OS profiles and server-side config templates
- [`docs/`](./docs/README.md)
  - human-facing usage, architecture, and UI documentation

## Current Defaults

These are already handled by the supported profiles and do not need to be entered by hand for the first install:

- `xray-core 26.3.27`
- GL package URLs and checksums for `redsocks` and `libevent`
- proxy ports `1083 / 1084 / 12345`
- shared-rules sync interval `30s`
- Debian 13 Xray config path and service defaults

## Verification Targets

Prefer these checks:

- `https://www.google.com`
- `https://ifconfig.me/ip`
- `https://ipinfo.io/ip`
- `https://api.openai.com/v1/models`

Do not use `chatgpt.com` as the main success criterion. VPS IP reputation can still trigger Cloudflare challenges even when the transport path is healthy.
