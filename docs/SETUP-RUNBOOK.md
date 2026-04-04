# Setup Runbook

## Supported Hello-World Path

This repository currently ships one primary supported combination:

- router profile: [`gl-mt3000-glinet`](../routers/gl-mt3000-glinet/README.md)
- VPS profile: [`debian-13`](../vps/debian-13/README.md)

## What You Need Before Starting

- `root` SSH access to the router after factory reset
- `root` SSH access to the VPS
- working uplink on the router during install
- outbound internet on the VPS during install
- local `bash`, `curl`, `ssh`, `tar`, `unzip`, and `python3`

The local installer accepts first-seen SSH host keys automatically with `StrictHostKeyChecking=accept-new`, so the first connection should not hang on an interactive host-key question.

## Quickstart

1. Create your local install file:

```bash
cp install.env.example install.env
```

2. Edit only:

- `ROUTER_SSH`
- `VPS_SSH`

3. Run:

```bash
./install.sh
```

If you want to verify both ends before any change is made:

```bash
PREFLIGHT_ONLY=1 ./install.sh
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

## After Install

Open:

- `https://<router-host>/xray.html`

From there you can:

- switch between saved VPS profiles
- read a VPS over SSH
- sync router + VPS
- choose `full` or `selective` routing on the router
- manage the shared selective-rules list

## Optional Shared Rules

If you also want GitHub-backed selective routing, fill these extra values in `install.env`:

- `RULES_REPO_FETCH_URL`
- `RULES_REPO_PUSH_URL`
- `RULES_ENABLE_PUSH=1`

If they are left empty, the router/VPS transport still works, but shared-rule Git sync is inactive.
