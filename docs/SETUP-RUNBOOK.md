# Setup Runbook

This runbook is the shortest supported path to reproduce the setup from scratch.

## Goal

Make a GL.iNet child router transparently forward client TCP traffic through a VPS over `VLESS + Reality`, with no proxy settings on client devices.

## Prerequisites

- GL.iNet router compatible with the current scripts
- reachable Linux VPS with `root` SSH access
- operator-owned GitHub repo for shared rules
- local shell with `bash`, `ssh`, `curl`, `python3`, `git`

## 1. Prepare Local Config Files

Create untracked local env files:

```bash
cp config/vps.env.example config/vps.env
cp config/router.env.example config/router.env
# optional
cp config/asus-router.env.example config/asus-router.env
```

For a minimal first install, edit only:

- `config/router.env`
  - `ROUTER_HOST`
- `config/vps.env`
  - `VPS_HOST`

Then generate the Xray-side values automatically:

```bash
./scripts/init-config.sh
```

If you also use the ASUS shared-rules consumer, fill `config/asus-router.env` separately.

Validate before deploy:

```bash
./scripts/validate-env.sh vps
./scripts/validate-env.sh router
# optional
./scripts/validate-env.sh asus
```

## 2. Deploy The VPS

```bash
./scripts/deploy-vps-config.sh
```

This script:

- renders `server-files/xray-vps-config.template.json`
- uploads it to the VPS
- runs `xray run -test`
- backs up the existing server config
- installs the rendered config and restarts `xray`

## 3. Deploy The GL Router

```bash
./scripts/deploy-child-router.sh
```

If the current management IP differs from the value in `config/router.env`, override it from the shell instead of editing the file for a one-off session:

```bash
ROUTER_HOST=<current-router-host> ROUTER_LAN_IP=<current-lan-host> ./scripts/deploy-child-router.sh
```

This deploy:

- installs `xray-core`, `redsocks`, and router init scripts
- installs the standalone web UI and CGI backends
- installs the shared-rules tool and background sync service
- binds the GL hardware switch to the VPS path
- keeps `eth1` in `br-lan` by default unless explicitly isolated

## 4. Verify The GL Router

```bash
./scripts/verify-child-router.sh
```

Expected:

- `google.com` via explicit proxy returns `200`
- `ifconfig.me/ip` via explicit proxy returns the VPS egress IP
- `ipinfo.io/ip` via explicit proxy returns the VPS egress IP
- `api.openai.com/v1/models` returns `401`

Then verify from a real client behind the router with no proxy settings:

- `https://www.google.com`
- `https://ifconfig.me/ip`
- `https://ipinfo.io/ip`

## 5. Optional ASUS Shared-Rules Consumer

If you also want the ASUS `shadowsocks-libev` side to consume the same rules repo:

```bash
./scripts/deploy-asus-rules.sh
```

## 6. Optional Router Deploy Key Registration

If the GL router must push back to the shared-rules GitHub repo:

```bash
./scripts/register-router-rules-deploy-key.sh
```

The script can derive the GitHub `owner/repo` slug from the local router env file if the repo URLs are already set there.

## Web UI Flow

Main page:

- `https://<router-host>/xray.html`

Supported operator flow:

1. choose or create a VPS profile
2. fill SSH access for that profile
3. `Read VPS And Update Profile`
4. review the current state and drift
5. `Sync Router + VPS`
6. use `Selective Address Filter` for shared GitHub-backed rules

Notes:

- the page does not own path enable/disable; the hardware switch does
- the page only auto-refreshes lightweight status
- log loading is manual
- background rules sync is system-side, not page-side

## Known Failure Modes

### Some sites hang, others work

Check in order:

1. upstream topology and Wi-Fi quality
2. VPS transport settings
3. shared-rules mode and recent cutover state

Do not assume every stall is a proxy bug.

### Browser `chatgpt.com` challenge

That is usually VPS IP reputation, not a broken transport path.

Use OpenAI API and neutral egress-IP checks instead.

### Selective domain rule appears delayed

This is usually one of:

- client DNS cache
- already-open TCP session
- client not using router DNS

## Minimal Live Checks

Useful commands:

```bash
ssh root@$ROUTER_HOST '/usr/bin/router-rules status-json'
ssh root@$ROUTER_HOST '/etc/init.d/codex-xray status || true'
ssh root@$ROUTER_HOST 'iptables -t nat -S CODEX_TRANSPROXY'
ssh root@$ROUTER_HOST "netstat -tn 2>/dev/null | grep ${XRAY_SERVER:-REPLACE_WITH_VPS_HOST}:${XRAY_PORT:-443} || true"
```

## Rollback

On the router:

```bash
ssh root@$ROUTER_HOST '/etc/init.d/codex-transproxy stop; /etc/init.d/codex-xray stop'
```

On the VPS:

- restore the latest `config.json.bak.*`
- run `xray run -test`
- restart `xray`
