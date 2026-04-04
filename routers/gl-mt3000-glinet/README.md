# GL.iNet GL-MT3000

This is the main supported router profile.

If you are installing from scratch, start with [`../../README.md`](../../README.md) and [`../../docs/GETTING-STARTED.md`](../../docs/GETTING-STARTED.md) first.

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

## Primary Install Shape

Primary path:

- SSH into the router
- run [`../../bootstrap-router.sh`](../../bootstrap-router.sh) on the router
- finish VPS setup from `xray.html`

Advanced path:

- use [`install-router.sh`](./install-router.sh) from a workstation together with the top-level [`../../install.sh`](../../install.sh)

## Ready-State Behavior

This profile now separates:

- platform installed
- active VPS client profile installed

The runtime stays dormant until the router has one valid client profile.

That state is tracked with:

- `/etc/xray/codex-xray.ready`

So after a fresh platform bootstrap it is normal to see the UI waiting for the first VPS sync.
