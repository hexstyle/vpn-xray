# Current Implementation State

This file summarizes the implemented feature set and the expected runtime shape.

Live addresses, keys, and credentials belong in local env files, not in this document.

## Current Baseline

- child router family:
  - `GL.iNet GL-MT3000`
- firmware family:
  - GL.iNet / OpenWrt SDK4 style environment
- router client runtime:
  - `xray-core 26.3.27`
- transport:
  - `VLESS + Reality`
- transparent layer:
  - `redsocks`
- shared-rules sync loop:
  - `30s` default interval

## Current User-Facing Capabilities

- transparent browsing without proxy settings on client devices
- hardware toggle for `proxy path on / off`
- web UI at `https://<router-host>/xray.html`
- SSH-first setup of a new Debian VPS from the router UI
- switching between saved VPS profiles
- shared selective-rules list synced through GitHub
- local `full` / `selective` mode on the GL router
- live domain-based selective routing on GL through `dnsmasq -> ipset`
- ASUS consumer based on resolved IPv4 snapshots for `shadowsocks-libev`

## Live Values Are Not Tracked Here

These always come from local untracked env files:

- router management host
- router LAN address
- admin/home subnet
- VPS host
- Xray UUID
- Reality public/private keys
- Reality short ID
- operator-owned GitHub repo URLs for shared rules

## How To Use It Day To Day

Runtime-specific values come from:

- `config/router.env`
- `config/vps.env`
- `config/asus-router.env` if used
- live router status
- live VPS inspection result

## Stable Endpoint Pattern

The UI and diagnostics endpoints are always shaped like:

- `https://<router-host>/xray.html`
- `https://<router-host>/cgi-bin/xray-admin`
- `https://<router-host>/cgi-bin/xray-vps`
- `https://<router-host>/cgi-bin/xray-rules`
- `http://<router-host>:<proxy-port>`

## Expected Runtime Behavior

Healthy state should look like:

- hardware switch state matches intended path state
- `xray` runtime is active when switch is `ON`
- `redsocks` runtime is active when switch is `ON`
- shared-rules background sync reports `verified` after successful checks
- no live placeholders remain in local env files

## Snapshot Discipline

If someone needs a new real-world snapshot, it should be written to local notes or operational docs outside the public repo unless it is first stripped of live secrets and private addressing.
