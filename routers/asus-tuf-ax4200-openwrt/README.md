# Asus TUF-AX4200

Secondary supported router profile on standard OpenWrt firmware.

If you are installing from scratch, start with [`../../README.md`](../../README.md) and [`../../docs/GETTING-STARTED.md`](../../docs/GETTING-STARTED.md) first.

## Firmware Family

- Standard OpenWrt firmware (not GL.iNet)
- transparent TCP forwarding implemented with:
  - `xray-core`
  - `redsocks`

## Profile Preconditions

This profile expects:

- OpenWrt hardware model `asus,tuf-ax4200`
- OpenWrt runtime with `uci`, `jsonfilter`, `iptables`, `ipset`, `dnsmasq`, `start-stop-daemon`, and `opkg`
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

- run [`../../bootstrap-router-ssh.sh`](../../bootstrap-router-ssh.sh) from a computer that has local `ssh` with `ROUTER_PROFILE=asus-tuf-ax4200-openwrt`
- or SSH into the router and run [`../../bootstrap-router.sh`](../../bootstrap-router.sh) there
- finish VPS setup from `xray.html`

Advanced path:

- use [`install-router.sh`](./install-router.sh) from a workstation together with the top-level [`../../install.sh`](../../install.sh)

## Ready-State Behavior

The runtime stays dormant until the router has one valid client profile.

That state is tracked with:

- `/etc/xray/codex-xray.ready`

So after a fresh platform bootstrap it is normal to see the UI waiting for the first VPS sync.
