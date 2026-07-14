# Supported State

This file describes the supported reference state without embedding personal data.

## Reference Combination

- router profile: `gl-mt3000-glinet`
- VPS profile: `debian-13`
- router UI: `https://<router-host>/xray.html`

## What Is Expected To Work

- transparent TCP forwarding for LAN clients
- `VLESS + WS+TLS` over the selected VPS
- physical switch as the source of truth for path on / off
- router-side switching between saved VPS profiles
- router-side provisioning of supported VPS profiles over SSH
- local `full` / `selective` mode
- optional GitHub-backed selective rules

## Operational Caveats

- `selective` mode depends on router-side DNS visibility for domains
- already-open client connections may continue using the old path until cutover state is resolved
- poor Wi-Fi uplink quality can look like a broken proxy even when Xray itself is healthy
- `chatgpt.com` is not a reliable smoke test because VPS IP reputation can trigger Cloudflare challenges

## Reference Checks

Use these as primary checks:

- `https://www.google.com`
- `https://ifconfig.me/ip`
- `https://ipinfo.io/ip`

Advisory only (VPS IP reputation can cause blocks even when transport is healthy):

- `https://api.openai.com/v1/models`
