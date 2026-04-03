# Architecture

This document is the compact system map for future agents. It explains what runs where, which component is authoritative for each concern, and which assumptions are safe to make.

## Goal

The child router should transparently forward client TCP traffic to a remote VPS over `VLESS + Reality`, without client-side proxy settings.

## Topology

There are three layers:

1. Client devices behind the child router
2. Child router runtime and management UI
3. Remote VPS running `xray`

The intended traffic path is:

`client LAN tcp -> iptables REDIRECT -> redsocks -> local SOCKS inbound -> xray-core client -> VLESS + Reality -> VPS xray server -> internet`

## Source Of Truth

Authority is intentionally split:

- Physical enable/disable:
  - hardware switch on the router body
- Switch enforcement:
  - `/etc/init.d/xray-switch-watchdog`
- Router runtime config:
  - `/etc/xray/codex-xray.json`
- Saved VPS profiles for the web UI:
  - `/etc/config/xray_vps`
- Remote VPS inspection cache:
  - `/etc/xray/vps-inspect/`
- Current VPS server config:
  - VPS-side `/usr/local/etc/xray/config.json`

The web page is not the source of truth for switch state.

## Shared Rules Layer

There is a second control plane for destination selection:

- canonical remote repo:
  - operator-owned GitHub repo configured in local env files
- router-side sync and apply tool:
  - `/usr/bin/router-rules`

Authority split here is:

- GitHub repo:
  - shared operator-facing rules
- router local generated files:
  - domain/literal split
  - resolved IPv4 snapshot and mapping
- consumer runtime:
  - `xray` selective `dnsmasq -> ipset` on GL
  - `shadowsocks-libev dst_ips_forward` on ASUS

This layer is intentionally separate from the main router/VPS profile UI.

## Router Components

## `codex-xray`

File:

- `/etc/init.d/codex-xray`

Responsibility:

- runs local `xray-core`
- exposes local HTTP and SOCKS proxy ports
- keeps `net.mptcp.enabled=0` while the proxy path is active
- recreates `/var/log/xray` on startup because this path may live on tmpfs

Important:

- do not remove the log directory bootstrap from the init script
- previous failures happened because `/var/log/xray` disappeared after reboot or tmpfs recreation

## `codex-transproxy`

File:

- `/etc/init.d/codex-transproxy`

Responsibility:

- owns the transparent `iptables` rules
- redirects LAN TCP traffic into `redsocks`
- bypasses the VPS IP itself to avoid loops
- keeps the LAN path stable for clients with no proxy settings

Important:

- the VPS bypass target must track the current router config, not a stale hardcoded IP

## `redsocks`

Config source:

- `/etc/redsocks.conf`

Responsibility:

- accepts redirected TCP
- forwards it to the local SOCKS port served by `codex-xray`

## `xray-switch-watchdog`

File:

- `/etc/init.d/xray-switch-watchdog`

Responsibility:

- polls the physical GL.iNet switch every 10 seconds
- if switch is `on` and the path is not active, it calls `/etc/gl-switch.d/xray.sh on`
- if switch is `off` and the path is active, it calls `/etc/gl-switch.d/xray.sh off`

Important:

- switch reconciliation belongs here, not in the browser UI
- the page only displays switch state and path state

## GL.iNet Integration

Files:

- `/etc/gl-switch.d/xray.sh`
- `switch-button` UCI config

Semantics:

- `ON` means the VPS path should be active
- `OFF` means the VPS path should be inactive

This integration is GL.iNet-specific and must be reworked on non-GL.iNet hardware.

## Web UI Components

Files:

- `/www/xray.html`
- `/www/cgi-bin/xray-admin`
- `/www/cgi-bin/xray-vps`

Split of responsibility:

- `xray-admin.cgi`
  - live runtime status
  - smoke tests
  - log reads
- `xray-vps.cgi`
  - saved VPS profiles
  - SSH-first workflow
  - remote VPS inspection
  - router/VPS sync
- `xray-rules.cgi`
  - shared GitHub-backed filter list
  - selective/full mode control for GL
  - status for resolved snapshot, live ipset state and sync health

Important:

- UI polling should stay lightweight
- the page should not run background VPS inspect loops
- the page should not auto-load logs

Current design rule:

- auto refresh only `status`
- load logs on demand
- inspect VPS only when user explicitly asks

## Router UI Flow

The intended happy path is:

1. Choose or create a saved VPS profile
2. Enter SSH access for that VPS
3. Press `Read VPS And Update Profile`
4. Review live state and drift
5. Press `Sync Router + VPS`

What this means:

- `Read VPS And Update Profile` is not a no-op check
- it reads the live VPS and may adopt live VPS-side Xray values into the saved profile
- `Sync Router + VPS` is the only action that should push state to both router and VPS

## Profile Model

A saved profile contains:

- human label
- stable profile id
- SSH connectivity information
- current Xray/Reality values
- generated or cached router-managed SSH key metadata
- latest remote inspection cache

Behavior rules:

- `VPS Host / Address` is used for both SSH and Xray server address
- `Profile ID` is an internal identifier and should remain read-only in the UI
- advanced Xray values are read-mostly in the page

## Current Technical Choices

These were chosen because earlier alternatives failed in this environment:

- router client runtime:
  - `xray-core 26.3.27`
- transport:
  - `VLESS + Reality`
- flow:
  - empty string
- mux:
  - enabled on router outbound
- transparent proxy:
  - `redsocks`
- DNS:
  - local `dnsmasq`
  - in `selective` mode client `:53` is redirected to the router to feed `dnsmasq -> ipset`
- IPv6:
  - disabled on LAN to avoid bypass paths

Important failed variants:

- `xtls-rprx-vision` caused intermittent hangs on this router/VPS pair
- `sing-box` variants tested earlier were not stable enough here for the same path

## Home Management Vs Travel Use

The home parent router is only a management and uplink environment.

At home:

- the child router may be reachable at a WAN-side parent-subnet IP supplied by whatever parent network it is attached to

In travel mode:

- the child router may use a totally different uplink
- the LAN-side address and local UI path can stay stable even when the parent network changes

Do not assume the current home parent exists in future deployments.

## Dangerous Topologies

Do not run the child router with both of these to the same parent network at once:

- `LAN-LAN`
- `Wi-Fi repeater`

That produced unstable layer-2 behavior and made management unreliable.

## What A Future Agent Should Not Relearn From Scratch

- switch state belongs to the router service layer, not the UI
- background inspect in the page was a mistake
- background log loading in the page was a mistake
- `Read VPS And Update Profile` needed cache-aware behavior because repeated SSH reads were flaky
- the UI became more stable only after request timeouts and anti-overlap guards were added
