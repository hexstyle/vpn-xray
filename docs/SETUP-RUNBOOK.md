# Setup Runbook

If this is your first install, start with:

- [`../README.md`](../README.md)
- [`GETTING-STARTED.md`](./GETTING-STARTED.md)

This file is the technical reference for the supported install flow and advanced options.

## Supported Hello-World Path

This repository currently ships one primary supported combination:

- router profile: [`gl-mt3000-glinet`](../routers/gl-mt3000-glinet/README.md)
- VPS profile: [`debian-13`](../vps/debian-13/README.md)

## What You Need Before Starting

- `root` SSH access to the router after factory reset
- `root` SSH access to the VPS
- a usable global IPv4 address on the VPS; this stack does not support IPv6-only servers
- working uplink on the router during install
- outbound internet on the VPS during install
- local `bash`, `curl`, `ssh`, `tar`, `unzip`, and `python3`

The local installer accepts first-seen SSH host keys automatically with `StrictHostKeyChecking=accept-new`, so the first connection should not hang on an interactive host-key question.

## Minimal Input

Only these two values are required for the first install:

- `ROUTER_SSH`
- `VPS_SSH`

Example:

```env
ROUTER_SSH=root@192.168.8.1
VPS_SSH=root@YOUR_VPS_IP
```

Create your local install file:

```bash
cp install.env.example install.env
```

## Quickstart Commands

1. Edit only:

- `ROUTER_SSH`
- `VPS_SSH`
- optionally `XRAY_PORT` if port `443` is already occupied on the VPS

2. Run:

```bash
./install.sh
```

On Windows:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

If you want to verify both ends before any change is made:

```bash
PREFLIGHT_ONLY=1 ./install.sh
```

On Windows:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -PreflightOnly
```

## What Happens Automatically

The installer fills the rest:

- `ROUTER_HOST`
- `ROUTER_LAN_IP`
- `VPS_HOST`
- `XRAY_SERVER`
- `XRAY_UUID`
- `XRAY_SERVER_NAME`
- `XRAY_SHORT_ID`
- `XRAY_PUBLIC_KEY`
- `XRAY_PRIVATE_KEY`

It then:

- runs router and VPS preflight checks before making changes
- validates the selected profiles
- deploys the VPS payload using the chosen VPS profile
- deploys the router runtime and web UI
- uploads the supported VPS profile bundles to the router
- runs a verification pass

If the physical switch on the GL.iNet router is `OFF`, deployment still finishes, but the final verification step stops with an explicit reminder to turn the switch `ON` and rerun `verify-router.sh`.

## After Install

Open:

- `https://<router-host>/xray.html`

From there you can:

- switch between saved VPS profiles
- read a VPS over SSH
- sync router + VPS
- choose `full` or `selective` routing on the router
- manage the shared selective-rules list

Behavior summary:

- `full`
  - all client traffic goes through the VPS
- `selective`
  - only listed domains / IPv4 / CIDR go through the VPS

## Optional Shared Rules

If you also want GitHub-backed selective routing, fill these extra values in `install.env`:

- `RULES_REPO_FETCH_URL`
- `RULES_REPO_PUSH_URL` only if this router should push local edits back upstream
- `RULES_ENABLE_PUSH=1` only when upstream push is intended

If `RULES_REPO_FETCH_URL` is left empty, the router/VPS transport still works, but shared-rule Git sync is inactive.
