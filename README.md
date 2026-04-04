# vpn-xray

`vpn-xray` is a simple installer and web UI around [Xray-core](https://github.com/XTLS/Xray-core) for supported router and VPS profiles.

<img src="./docs/assets/gl-mt3000-router.jpg" alt="GL.iNet GL-MT3000 travel router" width="420">

The reference device in this repository is the compact `GL.iNet GL-MT3000` travel router shown above. It runs from `5V`, can be powered from a Mac over USB, and is easy to keep in a bag as a personal network edge. The physical switch on the front edge is the source of truth for `path on / path off`.

The default mode after install is simple: connect your devices to this router and send all traffic through your own VPS. Later, in the router UI, you can keep that `full` mode or switch to `selective` mode if you want only chosen destinations to go through the VPS.

## Start Here

If you have just bought the router and a VPS, read this section first.
If you want the more guided version with extra explanations for SSH and Windows, open [`docs/GETTING-STARTED.md`](./docs/GETTING-STARTED.md).

### 1. Download This Repository

Choose one:

- GitHub ZIP: download and unpack this repository from `https://github.com/hexstyle/vpn-xray`
- Git:

```bash
git clone https://github.com/hexstyle/vpn-xray.git
cd vpn-xray
```

### 2. Prepare the Router

For the current supported router profile:

- device: `GL.iNet GL-MT3000`
- factory-reset management address: `http://192.168.8.1`
- SSH target after first setup: usually `root@192.168.8.1`

Recommended first-run steps:

1. Factory-reset the router.
2. Connect your computer to the router by Wi-Fi or LAN.
3. Open `http://192.168.8.1`.
4. Set the router admin password in the GL.iNet setup wizard.
5. Test SSH access:

```bash
ssh root@192.168.8.1
```

Use the same admin password you just set in the GL.iNet web panel.

### 3. Prepare the VPS

For the current supported VPS profile:

- OS: `Debian 13`
- access: `root` SSH
- network: a usable global `IPv4` address

Before running the installer, verify that this works:

```bash
ssh root@YOUR_VPS_IP
```

If your provider gives you an SSH key instead of a password, that is fine. The only requirement is that `ssh root@...` already works from your computer before you start.

### 4. Open a Terminal on Your Computer

- macOS: open `Terminal`
- Linux: open your usual terminal
- Windows:
  - install WSL once:

```powershell
wsl --install
```

  - reboot Windows
  - open `PowerShell` in the repository folder

### 5. Fill Two Values

Create your local install file:

```bash
cp install.env.example install.env
```

Then edit only these two values:

```env
ROUTER_SSH=root@192.168.8.1
VPS_SSH=root@YOUR_VPS_IP
```

Format:

- `ROUTER_SSH=user@host`
- `VPS_SSH=user@host`

For the first install, leave the generated Xray values empty. They are created automatically.

### 6. Run the Installer

On macOS or Linux:

```bash
./install.sh
```

On Windows:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

If you want a dry run before any change is made:

- macOS / Linux:

```bash
PREFLIGHT_ONLY=1 ./install.sh
```

- Windows:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -PreflightOnly
```

## What Happens Automatically

The installer will:

- run router and VPS preflight checks before making changes
- generate `XRAY_UUID`, `XRAY_SERVER_NAME`, `XRAY_SHORT_ID`, `XRAY_PUBLIC_KEY`, and `XRAY_PRIVATE_KEY`
- install and configure Xray on the VPS
- install the router runtime, watchdog, web UI, and bundled VPS profiles
- run a final verification pass

Important:

- keep the physical router switch in the `ON` position before the final verification pass
- if the switch is `OFF`, deployment still completes, but verification pauses and asks you to turn it `ON`
- if port `443` is already busy on the VPS, set `XRAY_PORT` in `install.env` before the real install

## After Install

1. Connect your phone, laptop, or other device to the GL.iNet router by Wi-Fi or LAN.
2. Put the physical switch in the `ON` position.
3. Open:

- `https://<router-host>/xray.html`

4. By default the router starts in `full` mode:
   all client traffic goes through the VPS.
5. If you want only some destinations through the VPS, change the router to `selective` mode later in the web UI.

Good first checks:

- `https://www.google.com`
- `https://ifconfig.me/ip`
- `https://ipinfo.io/ip`

`api.openai.com/v1/models` is only an advisory check. Some VPS IPs can be filtered by OpenAI even when the proxy path itself is healthy.

## Supported Profiles

Current supported combinations are explicit:

- Router profiles:
  - [`gl-mt3000-glinet`](./routers/gl-mt3000-glinet/README.md)
- VPS profiles:
  - [`debian-13`](./vps/debian-13/README.md)

The repository is structured so more router firmware profiles and more VPS OS profiles can be added later under [`routers/`](./routers/README.md) and [`vps/`](./vps/README.md) without changing the top-level install flow.

## Need More Detail?

- User-friendly first-run guide:
  - [`docs/GETTING-STARTED.md`](./docs/GETTING-STARTED.md)
- Technical install reference:
  - [`docs/SETUP-RUNBOOK.md`](./docs/SETUP-RUNBOOK.md)
- Web UI behavior:
  - [`docs/WEB-UI.md`](./docs/WEB-UI.md)
- Shared selective rules:
  - [`docs/SHARED-RULES.md`](./docs/SHARED-RULES.md)
- Architecture:
  - [`docs/ARCHITECTURE.md`](./docs/ARCHITECTURE.md)

## Repository Layout

Every main folder has its own `README.md`.

- [`install.env.example`](./install.env.example)
  - the only file you copy for a fresh setup
- [`install.sh`](./install.sh)
  - macOS / Linux installer entrypoint
- [`install.ps1`](./install.ps1)
  - Windows launcher that runs the installer through WSL
- [`common/`](./common/README.md)
  - shared bootstrap and validation helpers
- [`routers/`](./routers/README.md)
  - router profiles and shared OpenWrt-side assets
- [`vps/`](./vps/README.md)
  - VPS profiles and server-side payloads
- [`docs/`](./docs/README.md)
  - getting started, runbooks, UI behavior, shared rules, and architecture

## Thanks

This project stands on top of upstream work from:

- [Xray-core](https://github.com/XTLS/Xray-core)
- [OpenWrt](https://openwrt.org/)
- [GL.iNet](https://www.gl-inet.com/)

See [NOTICE.md](./NOTICE.md) for attribution and scope.
