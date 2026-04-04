# vpn-xray

`vpn-xray` is a practical wrapper around [Xray-core](https://github.com/XTLS/Xray-core) for supported router and VPS profiles.

<img src="./docs/assets/gl-mt3000-router.jpg" alt="GL.iNet GL-MT3000 travel router" width="420">

The reference device in this repository is the compact `GL.iNet GL-MT3000` travel router shown above. It runs from `5V`, can be powered from a Mac over USB, and is easy to keep in a bag as a personal network edge. The physical switch visible on the front edge is the source of truth for `path on / path off`.

The main use case is split routing from a work laptop: keep normal traffic on the ordinary uplink, but send selected destinations through your own VPS instead of through a corporate VPN. That is useful when you need stable access to specific external services, including foreign LLM agents, without touching proxy settings on the client. If your current VPS is blocked or lost, the router UI can read another reachable server over SSH and reconfigure it from the router.

## Thanks

This project stands on top of upstream work from:

- [Xray-core](https://github.com/XTLS/Xray-core)
- [OpenWrt](https://openwrt.org/)
- [GL.iNet](https://www.gl-inet.com/)

See [NOTICE.md](./NOTICE.md) for attribution and scope.

## Supported Profiles

Current supported combinations are explicit:

- Router profiles:
  - [`gl-mt3000-glinet`](./routers/gl-mt3000-glinet/README.md)
- VPS profiles:
  - [`debian-13`](./vps/debian-13/README.md)

The repository is structured so more router firmware profiles and more VPS OS profiles can be added later under [`routers/`](./routers/README.md) and [`vps/`](./vps/README.md) without changing the top-level install flow.

## Hello World

Before you start:

- the router must already be reachable over `root` SSH after factory reset
- the VPS must already be reachable over `root` SSH
- the router must have a working uplink during install
- the VPS must have outbound internet during install
- your local machine needs `bash`, `curl`, `ssh`, `tar`, `unzip`, and `python3`
- the installer accepts first-seen SSH host keys automatically with `StrictHostKeyChecking=accept-new`

1. Create your local install file:

```bash
cp install.env.example install.env
```

2. Edit only these two values:

- `ROUTER_SSH`
- `VPS_SSH`

3. Run the full install:

```bash
./install.sh
```

That installer will:

- run router and VPS preflight checks before making changes
- derive router and VPS hostnames from the SSH targets
- generate the Xray UUID, Reality keypair, short ID, and default SNI automatically
- validate the chosen router and VPS profiles
- deploy the VPS config using the selected VPS profile
- deploy the router runtime, UI, shared-rules engine, and bundled VPS profiles
- run a post-deploy verification pass

4. Open the router UI:

- `https://<router-host>/xray.html`

Important for the reference GL.iNet router:

- keep the physical switch in the `ON` position before the final verification pass
- the switch is the source of truth for `path on / path off`
- if the switch is `OFF`, install still completes, but the verification step will stop with an explicit message instead of pretending the proxy path is broken

If you want to test only readiness before the real install:

```bash
PREFLIGHT_ONLY=1 ./install.sh
```

## What This Wrapper Gives You

- transparent TCP forwarding for client devices with no proxy settings on the clients
- `VLESS + Reality` transport over your own VPS
- router-side web UI at `https://<router-host>/xray.html`
- SSH-first provisioning and switching between saved VPS profiles
- router-side provisioning of supported VPS OS profiles bundled during install
- local `full` and `selective` routing modes on the router
- optional GitHub-backed list of domains / IPv4 / CIDR for selective routing

## Repository Layout

Every main folder has its own `README.md`.

- [`install.env.example`](./install.env.example)
  - the only file you copy for a fresh setup
- [`common/`](./common/README.md)
  - shared bootstrap and validation helpers
- [`routers/`](./routers/README.md)
  - router profiles and shared OpenWrt-side assets
- [`vps/`](./vps/README.md)
  - VPS profiles and server-side payloads
- [`docs/`](./docs/README.md)
  - setup notes, web UI behavior, shared rules, and architecture

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
