# Current Supported State

This document tracks the supported baseline without storing live secrets, private hosts, or local addressing.

## Supported Router Profile

- router family:
  - `GL.iNet GL-MT3000`
- firmware family:
  - GL.iNet firmware on OpenWrt
- profile id:
  - `gl-mt3000-glinet`

## Supported VPS Profile

- operating system:
  - `Debian 13`
- profile id:
  - `debian-13`

## Transport Baseline

- client runtime:
  - `xray-core 26.3.27`
- transport:
  - `VLESS + Reality`
- transparent layer:
  - `redsocks`
- shared-rules sync interval:
  - `30s` by default

## User-Facing Features

- transparent browsing without client-side proxy settings
- physical router switch for `path on / off`
- web UI at `https://<router-host>/xray.html`
- SSH-first onboarding of another Debian VPS
- switching between saved VPS profiles
- local `full` and `selective` routing modes on the router
- GitHub-backed shared rules list
- domain-aware selective routing on GL through `dnsmasq -> ipset`

## Values That Must Stay Local

These belong only in local untracked files:

- router SSH target
- router management host
- VPS SSH target
- VPS host
- Xray UUID
- Reality keys
- Reality short ID
- GitHub repo URLs for shared rules

## Healthy Runtime Shape

Healthy day-to-day behavior looks like this:

- hardware switch state matches intended path state
- `xray` and `redsocks` are active when the switch is `ON`
- router UI and CGI endpoints answer at the router host
- rules sync reports `verified` once GitHub and runtime align
- no local config file still contains placeholders
