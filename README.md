# vpn-xray

`vpn-xray` is a router-first wrapper around [Xray-core](https://github.com/XTLS/Xray-core).

It is meant for one practical job: put a small travel router between your devices and the internet, then move traffic through your own VPS without manually hand-editing Xray configs every time.

<img src="./docs/assets/gl-mt3000-router.jpg" alt="GL.iNet GL-MT3000 travel router" width="420">

The reference device in this repository is the compact `GL.iNet GL-MT3000` travel router shown above. It runs from `5V`, can be powered from a Mac over USB, and is small enough to keep in a bag. The physical switch on the front edge remains the source of truth for `path on / path off`.

The default behavior after setup is simple:

- connect devices to this router
- keep the physical switch in `ON`
- route all client traffic through your VPS in `full` mode

Later, in the router UI, you can keep `full` mode or switch to `selective` mode if you want only chosen destinations through the VPS.

## Supported Hello-World

Current primary supported combination:

- router: `GL.iNet GL-MT3000`
- router profile: [`gl-mt3000-glinet`](./routers/gl-mt3000-glinet/README.md)
- VPS OS: `Debian 13`
- VPS profile: [`debian-13`](./vps/debian-13/README.md)

This stack is currently `IPv4-only` end to end. Your VPS must have a usable global IPv4 address.

## Fastest Path

You do not need WSL, Python, Homebrew, or a local installer for the main path.

You only need:

- the router reachable over SSH at `root@192.168.8.1`
- one Debian 13 VPS reachable over `root` SSH
- any computer with an `ssh` client

If `ssh` is missing on Windows, enable the built-in `OpenSSH Client` feature first and then use the same commands.

### 1. Prepare the Router

1. Factory-reset the router.
2. Connect your computer to the router by Wi-Fi or LAN.
3. Open `http://192.168.8.1`.
4. Finish the GL.iNet first-run wizard and set the admin password.
5. Test SSH:

```sh
ssh root@192.168.8.1
```

Use the same password you set in the GL.iNet web interface.

### 2. Prepare the VPS

Before you touch this repository, make sure this already works:

```sh
ssh root@YOUR_VPS_IP
```

Requirements:

- `Debian 13`
- global IPv4
- `root` SSH access

### 3. Bootstrap the Platform on the Router

The normal path is:

```sh
./bootstrap-router-ssh.sh root@192.168.8.1
```

That helper uses only local `ssh`, keeps its own installer SSH cache, survives router factory resets, and runs the real bootstrap on the router itself. You do not need `ssh-keygen`, `wget`, or `curl` on your computer for the normal path.

What this does:

- installs the router runtime
- installs the web UI
- installs bundled VPS installer profiles on the router
- leaves the path dormant until you configure a VPS in the UI

If this step fails, the router usually tells you what to fix:

- no internet uplink on the router
- wrong system time / NTP not settled yet
- unsupported firmware or missing router features

### 4. Finish in the Router UI

Open:

```text
https://192.168.8.1/xray.html
```

Then:

1. Create or select a VPS profile.
2. Fill `VPS Host / Address`.
3. Choose SSH auth:
   - password
   - private key
   - or reuse the router-managed key later
4. Click `Sync Router + VPS`.

The router will:

- reach the VPS over SSH
- inspect the target system
- install Xray on the VPS if needed
- generate or reuse the required client/server values
- sync the VPS and the router together

### 5. Use the Router

After the first successful sync:

1. Connect your laptop, phone or other device to the GL.iNet router.
2. Put the physical switch in the `ON` position.
3. By default, `full` mode sends all client traffic through the VPS.

Good first checks from a device behind the router:

- `https://ifconfig.me/ip`
- `https://ipinfo.io/ip`
- `https://www.google.com`

If the transport is healthy, those IP checks should show the VPS egress IP, not your home provider IP.

`api.openai.com` is only an advisory check. Some VPS IPs are filtered by OpenAI even when the VPN/proxy path itself is fine.

## Why This Exists

The main use case is simple and practical:

- keep a small router in your bag
- power it from USB
- connect your work laptop or phone to it
- use your own VPS as the internet exit

That is useful when:

- you want all traffic through your own VPS
- you need `selective` mode later, so only chosen destinations go through the VPS
- you want to stay productive even if one VPS gets blocked
- you want to switch to another Debian VPS quickly from the router UI itself

If your current VPS is gone, but you still have SSH access to another Debian server, the router can provision that new VPS from the web UI without going back to manual Xray setup.

## Shared Rules and Selective Mode

`full` mode is the default and simplest path.

`selective` mode is optional.

When you switch the router to `selective`:

- literal `IPv4` / `CIDR` rules are matched directly
- domain rules are tracked live on the router through `dnsmasq -> ipset`
- the shared list can be GitHub-backed if you configure that later

See:

- [`docs/SHARED-RULES.md`](./docs/SHARED-RULES.md)
- [`docs/WEB-UI.md`](./docs/WEB-UI.md)

## Advanced Path

This repository still ships a local advanced installer:

- [`install.sh`](./install.sh)

That path is useful for developers, CI, or people who want one local command to orchestrate both the router and the VPS from their workstation.

For most users, the recommended path is still:

1. bootstrap the platform on the router over SSH
2. configure the VPS from `xray.html`

## Read Next

- Friendly first install:
  - [`docs/GETTING-STARTED.md`](./docs/GETTING-STARTED.md)
- Technical runbook:
  - [`docs/SETUP-RUNBOOK.md`](./docs/SETUP-RUNBOOK.md)
- Web UI behavior:
  - [`docs/WEB-UI.md`](./docs/WEB-UI.md)
- Shared rules:
  - [`docs/SHARED-RULES.md`](./docs/SHARED-RULES.md)
- Architecture:
  - [`docs/ARCHITECTURE.md`](./docs/ARCHITECTURE.md)

## Repository Layout

Every main folder has its own `README.md`.

- [`bootstrap-router.sh`](./bootstrap-router.sh)
  - router-side bootstrap entrypoint that runs on the router itself
- [`bootstrap-router-ssh.sh`](./bootstrap-router-ssh.sh)
  - easiest local helper for the primary path; requires only `ssh` on your computer
- [`install.sh`](./install.sh)
  - advanced local installer for developers and CI
- [`install.env.example`](./install.env.example)
  - optional input file for the advanced local installer
- [`common/`](./common/README.md)
  - shared bootstrap and validation helpers
- [`routers/`](./routers/README.md)
  - router profiles and shared router-side assets
- [`vps/`](./vps/README.md)
  - VPS profiles and server-side payloads
- [`docs/`](./docs/README.md)
  - user-facing docs, runbooks, UI behavior and architecture

## Thanks

This project stands on top of upstream work from:

- [Xray-core](https://github.com/XTLS/Xray-core)
- [OpenWrt](https://openwrt.org/)
- [GL.iNet](https://www.gl-inet.com/)

See [NOTICE.md](./NOTICE.md) for attribution and scope.
