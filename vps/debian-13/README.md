# Debian 13 VPS Profile

This is the main supported server profile.

## Assumptions

- Debian 13
- SSH access as `root` or an equivalent account already handled through your SSH config
- `xray` installed at `/usr/local/bin/xray`
- systemd service name `xray`

## What The Deploy Script Does

- renders the server-side Xray config
- uploads it to the VPS
- runs `xray run -test`
- backs up the previous config if present
- installs the new config
- restarts the `xray` systemd service
