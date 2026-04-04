# Setup Runbook

If this is your first install, start with:

- [`../README.md`](../README.md)
- [`GETTING-STARTED.md`](./GETTING-STARTED.md)

This file is the technical reference for the supported setup paths.

## Supported Hello-World Path

Current supported combination:

- router profile: [`gl-mt3000-glinet`](../routers/gl-mt3000-glinet/README.md)
- VPS profile: [`debian-13`](../vps/debian-13/README.md)

## Primary Install Path: Router-First

The primary path does not depend on a local Bash or Python environment.

It assumes only:

- you can SSH into the router
- the router itself has internet access
- you can later enter VPS SSH details in the web UI

### Operator Preconditions

- `ssh root@192.168.8.1` already works
- the router can reach GitHub/package feeds
- the VPS has `Debian 13`, `root` SSH and global IPv4

### Commands

1. Recommended path:

```sh
./bootstrap-router-ssh.sh root@192.168.8.1
```

That helper is the intended user-facing entrypoint. It isolates installer host keys from the operator's personal SSH config and handles the real bootstrap on the router.

2. Manual fallback only if you are debugging or do not have the helper locally. SSH into the router:

```sh
ssh root@192.168.8.1
```

3. Then run the router bootstrap on the router itself:

```sh
sh -c "$(wget -qO- https://raw.githubusercontent.com/hexstyle/vpn-xray/main/bootstrap-router.sh)" || \
sh -c "$(curl -fsSL https://raw.githubusercontent.com/hexstyle/vpn-xray/main/bootstrap-router.sh)"
```

4. Open:

```text
https://192.168.8.1/xray.html
```

5. In the web UI, create/select a VPS and click `Sync Router + VPS`.

### What the Router Bootstrap Installs

- `codex-xray`
- `codex-transproxy`
- `xray-switch-watchdog`
- `router-rules-sync`
- `xray.html`
- `xray-admin`, `xray-vps`, `xray-rules`
- bundled VPS installer profiles under `/usr/share/vpn-xray/vps`

The router platform is installed in a dormant state until a VPS profile is successfully applied.

That dormant state is tracked by:

- `/etc/xray/codex-xray.ready`

If the file is absent:

- the watchdog will not bring the path up
- the UI reports that the router is still waiting for the first VPS apply

## Advanced Install Path: Local Orchestration

The repository still ships a local advanced path:

- [`../install.sh`](../install.sh)

Use it when:

- you want one local command to configure both router and VPS
- you want CI or reproducible workstation-driven installs
- you want to pre-generate Xray values before touching the router UI

### Advanced Path Requirements

- local `bash`
- local `ssh`
- local `ssh-keygen`
- local `tar`
- local `python3`
- `root` SSH to the router
- `root` SSH to the VPS

### Minimal Advanced Input

Create:

```sh
cp install.env.example install.env
```

Fill:

```env
ROUTER_SSH=root@192.168.8.1
VPS_SSH=root@YOUR_VPS_IP
```

Optional:

- `XRAY_PORT` if port `443` is already occupied on the VPS

### Advanced Commands

Dry run:

```sh
PREFLIGHT_ONLY=1 ./install.sh
```

Real install:

```sh
./install.sh
```

## Shared Rules

Shared Git-backed selective rules are optional.

If you want them, use these advanced variables:

- `RULES_REPO_FETCH_URL`
- `RULES_REPO_PUSH_URL`
- `RULES_ENABLE_PUSH=1` only when the router is allowed to push upstream

If `RULES_REPO_FETCH_URL` is empty:

- the transport still works
- `full` and local `selective` still work
- GitHub-backed rules sync stays disabled

## Verification Notes

The physical GL.iNet switch is still the source of truth.

Important outcomes:

- switch `OFF`
  - deployment may still complete
  - runtime stays intentionally down
- platform installed, but no ready profile yet
  - the UI shows `waiting for VPS`
  - `verify-router.sh` exits with a nonfatal guidance code

Useful checks after a successful first sync:

- `https://ifconfig.me/ip`
- `https://ipinfo.io/ip`
- `https://www.google.com`

`api.openai.com` remains advisory only.
