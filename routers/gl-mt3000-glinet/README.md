# GL.iNet GL-MT3000

This is the main supported router profile.

## Firmware Family

- GL.iNet firmware on top of OpenWrt
- hardware switch available on the front edge of the device
- transparent TCP forwarding implemented with:
  - `xray-core`
  - `redsocks`

## Profile Preconditions

This profile expects:

- GL.iNet hardware model `mt3000`
- OpenWrt / GL runtime with `uci`, `jsonfilter`, `iptables`, `ipset`, `dnsmasq`, `start-stop-daemon`, and `opkg`
- `dnsmasq` build with `ipset` support, because selective routing tracks domains through `dnsmasq -> ipset`

## What This Profile Installs

- `codex-xray`
- `codex-transproxy`
- `xray-switch-watchdog`
- `router-rules-sync`
- standalone web UI at `https://<router-host>/xray.html`
- bundled VPS profiles under `/usr/share/vpn-xray/vps`

## First-Run Input

For the default quickstart, the operator only needs:

- `ROUTER_SSH`
- `VPS_SSH`

Everything else is generated or defaulted by the profile unless you intentionally turn on advanced features such as Git-backed shared rules.
