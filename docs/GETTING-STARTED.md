# Getting Started

This page is for a first install from scratch.

Current supported hello-world combination:

- router: `GL.iNet GL-MT3000`
- router profile: `gl-mt3000-glinet`
- VPS OS: `Debian 13`
- VPS profile: `debian-13`

If you want the shortest possible version, read [`../README.md`](../README.md) first and come back here only if you need more detail.

## What You Need

- one `GL.iNet GL-MT3000` router
- one VPS running `Debian 13`
- your computer on macOS, Linux, or Windows
- internet access for the router and for the VPS during install

This stack is currently `IPv4-only` end to end. Your VPS must have a usable global IPv4 address.

## Download The Repository

Choose one:

- GitHub ZIP:
  - open `https://github.com/hexstyle/vpn-xray`
  - click `Code`
  - click `Download ZIP`
  - unpack the ZIP
- Git:

```bash
git clone https://github.com/hexstyle/vpn-xray.git
cd vpn-xray
```

## Prepare Your Computer

### macOS

- open `Terminal`

### Linux

- open your normal terminal

### Windows

Install WSL once:

```powershell
wsl --install
```

Then:

1. reboot Windows
2. open `PowerShell`
3. `cd` into the unpacked repository folder

You will later run:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

SSH is the only command-line login the installer needs. The SSH checks below simply confirm that your computer can log into the router and the VPS before automation starts.
The installer keeps its own SSH host-key cache in `tmp/ssh/known_hosts`, so a stale key in your personal `~/.ssh/known_hosts` should not block the install.

## Prepare The Router

1. Factory-reset the router.
2. Connect your computer to the router by Wi-Fi or LAN.
3. Open `http://192.168.8.1`.
4. Finish the GL.iNet first-run wizard and set the admin password.
5. Test SSH:

```bash
ssh root@192.168.8.1
```

Use the same password you set in the GL.iNet web interface.
If `ssh` is not available in PowerShell on Windows, run the same command inside WSL after `wsl --install`.

If the Wi-Fi password is not shown on the sticker or in the quick card, try `goodlife`.

At this point, the only thing that must be true is:

- `ssh root@192.168.8.1` works from your computer

## Prepare The VPS

1. Create a VPS with `Debian 13`.
2. Make sure it has a public IPv4 address.
3. Verify SSH access:

```bash
ssh root@YOUR_VPS_IP
```

On Windows, you can run that check either from PowerShell or from the WSL terminal.

At this point, the only thing that must be true is:

- `ssh root@YOUR_VPS_IP` works from your computer

## Fill `install.env`

Create the file:

```bash
cp install.env.example install.env
```

Fill only these two lines for the first install:

```env
ROUTER_SSH=root@192.168.8.1
VPS_SSH=root@YOUR_VPS_IP
```

Leave the generated Xray values empty. They are created automatically.

## Run Preflight First

macOS / Linux:

```bash
PREFLIGHT_ONLY=1 ./install.sh
```

Windows:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -PreflightOnly
```

If preflight passes, run the real install.

## Run The Real Install

macOS / Linux:

```bash
./install.sh
```

Windows:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

## What To Expect After Install

1. Keep the physical router switch in the `ON` position.
2. Connect your devices to the GL router by Wi-Fi or LAN.
3. Open:

- `https://<router-host>/xray.html`

4. The default routing mode is `full`.
   That means all client traffic goes through the VPS.
5. `selective` mode is optional and can be enabled later in the web UI.

## How To Check That It Works

From a device connected to the router, open:

- `https://ifconfig.me/ip`
- `https://ipinfo.io/ip`

You should see the VPS egress IP, not your home provider IP.

## If Something Fails

- If install stops before changing anything:
  - fix the reported preflight problem and run again
- If install completes but verify says the switch is `OFF`:
  - flip the physical switch to `ON`
  - rerun `routers/gl-mt3000-glinet/verify-router.sh`
- If Google and the IP checks work, but `api.openai.com` does not:
  - the transport may still be healthy
  - the current VPS IP may be filtered by OpenAI
  - switch to another VPS later in the router UI if needed
