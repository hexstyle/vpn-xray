# Setup Runbook

This is the shortest supported path to a working install.

## Goal

Use a supported OpenWrt router profile as a transparent client-side wrapper around Xray, and use a supported VPS profile as the remote server side.

Current reference combination:

- router:
  - `gl-mt3000-glinet`
- VPS:
  - `debian-13`

## Prerequisites

- one supported router reachable over SSH
- one supported VPS reachable over SSH
- local shell with:
  - `bash`
  - `ssh`
  - `curl`
  - `python3`
  - `git`

## 1. Create Local Config Files

```bash
cp config/router.env.example config/router.env
cp config/vps.env.example config/vps.env
```

Edit only:

- `config/router.env`
  - `ROUTER_SSH`
- `config/vps.env`
  - `VPS_SSH`

That is the only required human input for the supported hello-world path.

## 2. Run The Full Installer

```bash
./scripts/install-stack.sh
```

This script runs, in order:

1. `scripts/init-config.sh`
2. `scripts/validate-env.sh vps`
3. `scripts/validate-env.sh router`
4. `scripts/deploy-vps-config.sh`
5. `scripts/deploy-child-router.sh`
6. `scripts/verify-child-router.sh`

## 3. Open The Router UI

- `https://<router-host>/xray.html`

From there you can:

- inspect the current VPS
- create another VPS profile
- read a reachable Debian VPS over SSH
- sync router and VPS settings
- manage selective routing rules

## Step-By-Step Entry Points

If you do not want the all-in-one installer, the supported manual sequence is:

```bash
./scripts/init-config.sh
./scripts/validate-env.sh vps
./scripts/validate-env.sh router
./scripts/deploy-vps-config.sh
./scripts/deploy-child-router.sh
./scripts/verify-child-router.sh
```

## Shared Rules Are Optional

GitHub-backed shared rules are not required for the first install.

You can leave these empty initially:

- `RULES_REPO_FETCH_URL`
- `RULES_REPO_PUSH_URL`

The basic Xray path still works without them.

## Known Runtime Behaviors

### Selective domain rule looks delayed

That usually means one of:

- the client still has a DNS cache entry
- the client kept an old TCP session open
- the client is not using router DNS

### Some sites hang while others work

Check in this order:

1. uplink quality and topology
2. VPS transport path
3. whether the site is inside or outside the selective set

### `chatgpt.com` challenge

That is usually VPS IP reputation, not a broken Xray transport path.

Use `api.openai.com`, `ifconfig.me`, and `ipinfo.io` as the health checks instead.
