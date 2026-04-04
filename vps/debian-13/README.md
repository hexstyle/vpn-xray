# Debian 13 VPS Profile

This is the main supported VPS profile.

If you are installing from scratch, start with [`../../README.md`](../../README.md) and [`../../docs/GETTING-STARTED.md`](../../docs/GETTING-STARTED.md) first.

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

- by the advanced local installer during the initial setup
- by the router UI when the router provisions another VPS over SSH

For the primary user path, the router itself uses this profile after the platform has already been bootstrapped on the GL router.
