# GL.iNet GL-MT3000

This is the main supported router profile.

## Firmware Family

- GL.iNet firmware on top of OpenWrt
- hardware switch available on the front edge of the device
- transparent TCP forwarding implemented with:
  - `xray-core`
  - `redsocks`

## What This Profile Installs

- `codex-xray`
- `codex-transproxy`
- `xray-switch-watchdog`
- standalone web UI at `https://<router-host>/xray.html`
- shared-rules consumer for:
  - `full` mode
  - `selective` mode

## First-Run Input

For the default quickstart, the operator only needs:

- `ROUTER_SSH`
- `VPS_SSH`

Everything else is generated or defaulted by the scripts unless you intentionally turn on advanced features such as Git-backed shared rules.
