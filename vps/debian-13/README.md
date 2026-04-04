# Debian 13 VPS Profile

This is the main supported VPS profile.

## Assumptions

- Debian 13
- SSH access to the host
- `systemd`
- `apt-get`
- architecture matching `x86_64|aarch64`

## What This Profile Ships

- a server-side Xray config template
- a remote install/apply script
- defaults for config path, log path, service name, and Xray binary path

The same profile bundle is used in two places:

- by the local root installer during the initial setup
- by the router UI later when you provision another VPS over SSH
