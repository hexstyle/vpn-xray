# Architecture

This repository is organized as a wrapper around Xray with two profile layers:

1. router profile
2. VPS profile

The current reference path is:

`client LAN tcp -> iptables REDIRECT -> redsocks -> local SOCKS -> xray client -> VLESS + Reality -> VPS xray server -> internet`

## Profile Model

Profiles live in:

- [`../routers/`](../routers/README.md)
- [`../vps/`](../vps/README.md)

Current baseline:

- router profile:
  - `gl-mt3000-glinet`
- VPS profile:
  - `debian-13`

The top-level scripts load profile defaults first, then overlay operator-specific values from local `.env` files.

## Source Of Truth

Authority is intentionally split:

- path on/off:
  - physical switch on the GL router
- switch reconciliation:
  - `/etc/init.d/xray-switch-watchdog`
- router runtime config:
  - `/etc/xray/codex-xray.json`
- saved VPS profiles in the UI:
  - `/etc/config/xray_vps`
- VPS server config:
  - profile-specific Xray config path on the VPS
- shared selective rules:
  - operator-owned GitHub repo plus router-side generated state

The web page is not the source of truth for the hardware switch.

## Router Runtime Components

- `codex-xray`
  - runs local `xray-core`
- `codex-transproxy`
  - owns transparent `iptables` rules
- `redsocks`
  - bridges redirected TCP into the local SOCKS inbound
- `xray-switch-watchdog`
  - keeps services aligned with the physical switch
- `router-rules-sync`
  - background GitHub sync for the selective rules layer

## Web UI Components

- `xray-admin`
  - runtime status, smoke checks, logs
- `xray-vps`
  - saved VPS profiles, SSH-first inspection, router/VPS sync
- `xray-rules`
  - local mode toggle plus shared-rules sync/apply state

## Shared Rules Layer

The shared rules system is intentionally separate from the base router/VPS tunnel.

It uses:

- one operator-controlled GitHub repo
- a canonical text file of domains / IPv4 / CIDR
- one router-side consumer per profile

Current consumers:

- GL router:
  - `dnsmasq -> ipset` plus literal `ipset`
- secondary OpenWrt `shadowsocks-libev` profile:
  - resolved IPv4 snapshot

## Known Constraints

- GL selective domain routing depends on client DNS going through the router
- existing TCP sessions do not jump to a new route mid-flight
- `LAN-LAN` and `Wi-Fi repeater` to the same parent network at the same time is an invalid topology
- some failures that look like “proxy is broken” are really uplink quality problems
