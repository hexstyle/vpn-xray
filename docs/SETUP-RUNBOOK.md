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
- [`../bootstrap-router-vps.sh`](../bootstrap-router-vps.sh)

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

### One-Shot Router-First Local Command

Use this path when:

- you want one local command, but only local SSH to the router
- you want the router to provision the VPS itself by password and then switch to its managed key
- you want to install from the current local checkout instead of waiting for GitHub bootstrap content
- if you change installer scripts, commit and push those changes before testing the script flow on the router

Minimal command:

```sh
VPS_PASSWORD='YOUR_VPS_ROOT_PASSWORD' ./bootstrap-router-vps.sh root@192.168.8.1 38.180.250.9
```

Predictable first-run command:

```sh
ROUTER_PASSWORD='ROUTER_ADMIN_PASSWORD' VPS_PASSWORD='YOUR_VPS_ROOT_PASSWORD' ./bootstrap-router-vps.sh root@192.168.8.1 38.180.250.9
```

Run it from the repository root. This path installs from the current local checkout, not from GitHub bootstrap content.

Local requirements:

- `bash`
- `ssh`
- `ssh-keygen`
- `tar`
- `python3`
- `curl`

Parameter matrix:

| Name | Required? | Default | Used by | Relationship |
| --- | --- | --- | --- | --- |
| `router-ssh` | optional | `root@192.168.8.1` | workstation | First positional argument. Overrides `ROUTER_SSH`. |
| `ROUTER_SSH` | optional | `root@192.168.8.1` | workstation | Used only when `router-ssh` positional argument is omitted. |
| `vps-host` | required unless `VPS_HOST` is set | none | workstation and router | Second positional argument. Overrides `VPS_HOST`. This becomes the router profile's `ssh_host`. |
| `VPS_HOST` | required unless `vps-host` is passed | none | workstation and router | Central host value. Also becomes the default for `XRAY_SERVER`. |
| `ROUTER_PASSWORD` | optional | unset | workstation | Only for workstation -> router login via `SSH_ASKPASS`. It is not sent to the VPS. |
| `VPS_PASSWORD` | recommended for first run; required in password mode | unset | workstation and router | Required when `VPS_AUTH_MODE=password`. In `auto`, keep it set even if workstation key SSH already works, because the router may still need password fallback if it cannot use the temporary key. |
| `VPS_SSH_USER` | optional | `root` | workstation and router | Same SSH username is used for workstation preflight and saved router profile. |
| `VPS_SSH_PORT` | optional | `22` | workstation and router | Same SSH port is used for workstation preflight and saved router profile. |
| `VPS_SSH_HOST` | optional | `VPS_HOST` | workstation | Used only by the workstation during bootstrap key seeding and validation. It does not change the router profile's saved `ssh_host`. |
| `XRAY_SERVER` | optional | `VPS_HOST` | router runtime and verification | Public Xray address written into the router profile. It does not change SSH destination selection. |
| `XRAY_SERVER_NAME` | optional | selected VPS profile default | router and VPS config rendering | TLS `serverName`. If unset, the profile default is used. |
| `XRAY_PORT` | optional | `443` | router and VPS config rendering | Xray transport port. Independent from `VPS_SSH_PORT`. |
| `VPS_AUTH_MODE` | optional | `auto` | workstation and router payload | `auto` tries workstation key access first, then falls back when needed. `password` requires `VPS_PASSWORD`. `private_key` still benefits from `VPS_PASSWORD` as fallback. |
| `PROFILE_ID` | optional | derived from `VPS_HOST` | router profile storage | Stable profile key on the router. Useful when reusing the same profile name across reruns. |
| `PROFILE_LABEL` | optional | `VPS $VPS_HOST` | router UI | Display label for the router UI. |
| `ROUTER_PROFILE` | optional advanced | `gl-mt3000-glinet` | local installer | Change only when testing another supported router profile. |
| `VPS_PROFILE` | optional advanced | `debian-13` | router payload and rendering | Change only when testing another supported VPS profile. |
| `PROXY_PORT` | optional advanced | `1083` | final verification | Local HTTP proxy port that the script waits for and tests at the end. |

Interrelations that matter:

- `VPS_HOST` is the router's future SSH host. If the router should later SSH to `38.180.250.9`, that value must be `VPS_HOST`, even if the workstation temporarily uses another address during bootstrap.
- `VPS_SSH_HOST` exists only for workstation-side preflight. Use it when the workstation must reach the VPS through a different address than the router will store and use later.
- `XRAY_SERVER` controls the public transport address. Keep it equal to `VPS_HOST` unless the Xray/Reality endpoint must differ from the saved SSH host.
- positional arguments override environment variables for `router-ssh` / `ROUTER_SSH` and `vps-host` / `VPS_HOST`.
- if local workstation SSH to the router is already established, `ROUTER_PASSWORD` can stay unset.
- if you want the least surprising first run, keep `VPS_PASSWORD` set even when workstation key-based SSH to the VPS already works.

Examples:

Minimal:

```sh
VPS_PASSWORD='YOUR_VPS_ROOT_PASSWORD' ./bootstrap-router-vps.sh root@192.168.8.1 38.180.250.9
```

Non-interactive router login:

```sh
ROUTER_PASSWORD='ROUTER_ADMIN_PASSWORD' VPS_PASSWORD='YOUR_VPS_ROOT_PASSWORD' ./bootstrap-router-vps.sh root@192.168.8.1 38.180.250.9
```

Use environment variables instead of positional arguments:

```sh
ROUTER_PASSWORD='ROUTER_ADMIN_PASSWORD' VPS_PASSWORD='YOUR_VPS_ROOT_PASSWORD' VPS_HOST='38.180.250.9' ./bootstrap-router-vps.sh
```

Different public Xray endpoint, but the same VPS SSH host:

```sh
VPS_PASSWORD='YOUR_VPS_ROOT_PASSWORD' XRAY_SERVER='vpn.example.com' XRAY_SERVER_NAME='www.microsoft.com' ./bootstrap-router-vps.sh root@192.168.8.1 38.180.250.9
```

Different workstation-side preflight host, but the router still saves and uses the public VPS address:

```sh
VPS_PASSWORD='YOUR_VPS_ROOT_PASSWORD' VPS_SSH_HOST='10.0.0.5' ./bootstrap-router-vps.sh root@192.168.8.1 38.180.250.9
```

One-command quick start with shared selective rules pulled from Git over SSH:

```sh
ROUTER_PASSWORD='ROUTER_ADMIN_PASSWORD' \
VPS_PASSWORD='YOUR_VPS_ROOT_PASSWORD' \
RULES_GIT_SYNC_ENABLED='1' \
RULES_REPO_FETCH_URL='git@github.com:hexstyle/routerRules.git' \
RULES_REPO_BRANCH='main' \
RULES_GIT_AUTH_MODE='ssh' \
RULES_GIT_SSH_PRIVATE_KEY_FILE="$HOME/.ssh/id_ed25519" \
./bootstrap-router-vps.sh root@192.168.8.1 38.180.250.9
```

Verification behavior:

- the script waits for the router proxy on the configured HTTP port
- it checks `https://www.google.com` through that proxy
- it compares the proxy egress IP with `XRAY_SERVER` when that value is an IPv4 address
- when `RULES_GIT_SYNC_ENABLED=1`, it also verifies shared-rules sync; if the immediate SSH probe cannot confirm status right after restart, the script warns and the live state remains visible in `xray.html`
- if the GL.iNet physical switch is `OFF`, the script stops after install and tells you to turn it `ON`

## Shared Rules

Shared Git-backed selective rules are optional.

If you want them, use these advanced variables:

- `RULES_GIT_SYNC_ENABLED=1` to explicitly enable background Git sync
- `RULES_REPO_FETCH_URL`
- `RULES_REPO_PUSH_URL`
- `RULES_GIT_AUTH_MODE=ssh|https|auto`
- `RULES_GIT_HTTP_USERNAME`
- `RULES_GIT_HTTP_PASSWORD`
- `RULES_GIT_SSH_PRIVATE_KEY`
- `RULES_ENABLE_PUSH=1` only when the router is allowed to push upstream

If `RULES_REPO_FETCH_URL` is empty:

- the transport still works
- `full` and local `selective` still work
- Git-backed rules sync stays disabled

Runtime behavior:

- shared addresses are applied only when the GL.iNet physical VPN switch is `ON`
- shared addresses affect routing only when the router Routing Mode is `selective`
- `full` mode ignores the shared rules list by design

UI behavior in `xray.html`:

- `Shared Rules Git Sync` is a separate toggle
- when that toggle is `OFF`, the router uses only the local text list and never contacts Git
- when that toggle is `ON`, the router expects `lists/shared-targets.txt` to exist in the configured repository
- if that file is missing or Git auth fails, the Git sync check fails and the router falls back to local-only mode

## Recovery — If Installation Fails Mid-Way

- **SSH dropped during WAN bounce (step 7)** — config was applied but SSH lost. Wait 30s, then re-run the installer. It is idempotent and will pick up where it left off.

- **Xray config fails validation (step 5)** — the previous config is preserved. Fix `install.env` (keys/address), then re-run.

- **VPS SSH registration failed (step 6)** — admin panel VPS sync will not work until the key is registered. Re-run the full installer to retry (step 6 is idempotent).

- **Router SSH unreachable after deploy (step 8)** — power-cycle the router, then re-run the installer. The installer uses its own known_hosts cache (`tmp/ssh/known_hosts`), not `~/.ssh/known_hosts`.

- **Redsocks/xray left stopped after an interrupted install** — the health monitor Guard 6 will auto-restart redsocks within 90s; xray-switch-watchdog recovers xray in under 30s. To recover manually:

  ```sh
  ssh root@<router> '/etc/init.d/codex-transproxy start && /etc/init.d/codex-xray start'
  ```

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
