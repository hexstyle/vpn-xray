# Audit

This document summarizes the final review of the device-specific work and the repository state.

## Scope Reviewed

- child-router runtime (`codex-xray`, `codex-transproxy`, `redsocks`)
- GL hardware-switch integration
- VPS-profile web UI
- shared-rules sync / merge / apply layer
- deployment scripts
- verification scripts
- tracked documentation and configuration files

## What Is Solid

- `xray-core 26.3.27` with `VLESS + Reality`, `flow=""`, and outbound `mux` is the validated transport choice for this setup
- the GL hardware switch is the source of truth for enable/disable and is enforced by `xray-switch-watchdog`
- shared rules now have one canonical operator-facing text file and two consumer backends
- GL selective routing no longer depends only on a stale resolved snapshot; domains now feed live `dnsmasq -> ipset`
- the rules UI exposes actual sync/cutover state instead of only a vague log dump
- deploy scripts now fail fast on missing or placeholder values

## Main Weak Points

### GL-specific integration

The proxy stack is portable across OpenWrt-style devices, but these parts are GL-specific:

- `switch-button` UCI handling
- `/etc/gl-switch.d/`
- physical switch polling / reconciliation

On non-GL hardware this part must be reimplemented or dropped.

### Selective mode depends on router DNS

On GL, domain rules become effective through `dnsmasq -> ipset`.

That means:

- clients must actually resolve through the router
- hardcoded DoH/DoT on the client can bypass domain learning
- already-open sessions are not retroactively reclassified

### Uplink quality can look like proxy failure

During testing, direct repeater links to a different upstream sometimes caused site stalls even when proxy logic was correct.

This means:

- not every “site hangs” symptom is a proxy bug
- upstream Wi-Fi quality and topology must be checked before blaming Xray

### Site-based IP tests can be misleading

`2ip.*` style sites are not the most reliable truth source in mixed-topology experiments.

Use:

- `ifconfig.me/ip`
- `ipinfo.io/ip`
- OpenAI API reachability

## Repo Hygiene Outcome

The repo now follows these rules:

- no tracked live `.env` files
- no tracked real router/VPS addresses
- no tracked real UUIDs / Reality keys / passwords
- all required mutable inputs come from local untracked env files
- env templates use placeholders and deploy scripts reject them until replaced

## Reproducibility Outcome

A new operator should be able to reproduce the setup with:

1. their own VPS
2. their own router IPs
3. their own Xray / Reality identifiers
4. their own GitHub shared-rules repo

without relying on any external conversation context.

## Remaining Operational Caveats

- `chatgpt.com` browser access is still not the transport success metric
- `full` vs `selective` is router-local state and is intentionally not synced to GitHub
- shared list content is synced through GitHub; local mode is not
- WAN/LAN management IP may change with topology, so scripts must be run with the current router host

## Regression Checklist

Future changes should be rejected if they reintroduce any of these:

- tracked live secrets
- tracked live IPs specific to one lab
- background UI work that blocks the page or spawns overlapping CGI jobs
- rules sync that restarts the transparent path when no runtime change is required
- selective routing that falls back to stale domain snapshots on GL
