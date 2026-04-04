# Getting Started

This page is the human-first guide for a clean install from scratch.

Current supported hello-world combination:

- router: `GL.iNet GL-MT3000`
- router profile: `gl-mt3000-glinet`
- VPS OS: `Debian 13`
- VPS profile: `debian-13`

If you only want the shortest version, start with [`../README.md`](../README.md).

## What You Need

- one `GL.iNet GL-MT3000` router
- one VPS with `Debian 13`
- internet uplink on the router during bootstrap
- outbound internet on the VPS during setup
- a usable global IPv4 address on the VPS
- any computer with an `ssh` client

You do not need WSL, Docker, Python, or a local installer for the main path.

If `ssh` is missing on Windows, enable the built-in `OpenSSH Client` optional feature first and then continue with the same commands.

## Before You Start

### Router

1. Factory-reset the router.
2. Connect your computer to it by Wi-Fi or LAN.
3. Open `http://192.168.8.1`.
4. Finish the GL.iNet wizard.
5. Set the admin password.
6. Test SSH:

```sh
ssh root@192.168.8.1
```

Use the same password you set in the GL.iNet web panel.

If you see `REMOTE HOST IDENTIFICATION HAS CHANGED` after a factory reset, remove the old SSH host key once:

```sh
ssh-keygen -R 192.168.8.1
```

What must be true before you continue:

- `ssh root@192.168.8.1` works

### VPS

Create a VPS with:

- `Debian 13`
- public IPv4
- `root` SSH

Test it:

```sh
ssh root@YOUR_VPS_IP
```

What must be true before you continue:

- `ssh root@YOUR_VPS_IP` works

## Bootstrap the Router Platform

If you downloaded or cloned this repository locally, use the helper:

```sh
./bootstrap-router-ssh.sh root@192.168.8.1
```

That helper needs only local `ssh`. It does not depend on your personal `~/.ssh/known_hosts`, and it runs the actual bootstrap on the router.

If you do not have the repository locally, use the manual two-step path.

First SSH into the router:

```sh
ssh root@192.168.8.1
```

Then run the bootstrap command on the router:

```sh
sh -c "$(wget -qO- https://raw.githubusercontent.com/hexstyle/vpn-xray/main/bootstrap-router.sh)" || \
sh -c "$(curl -fsSL https://raw.githubusercontent.com/hexstyle/vpn-xray/main/bootstrap-router.sh)"
```

This installs the router-side platform only:

- runtime
- watchdog
- web UI
- bundled VPS profiles

At this stage the router is ready, but no VPS path is active yet.

## Configure the VPS in the Router UI

Open:

```text
https://192.168.8.1/xray.html
```

Then:

1. Click `New VPS` or select an existing profile.
2. Fill `VPS Host / Address`.
3. Choose the SSH auth method.
4. Fill:
   - `SSH User`
   - `SSH Password`
   - or a bootstrap private key
5. Click `Sync Router + VPS`.

What happens next:

- the router checks SSH access to the VPS
- the router reads the target system
- the router installs Xray on the VPS if needed
- the router generates or reuses client/server values
- the router syncs the VPS and the local router profile

## Start Using It

After the first successful sync:

1. Connect your devices to the router.
2. Put the physical switch in the `ON` position.
3. Keep the router in `full` mode unless you specifically need selective routing.

Default behavior:

- `full`
  - all client traffic goes through the VPS
- `selective`
  - only chosen destinations go through the VPS

## First Checks

From a device connected behind the router, open:

- `https://ifconfig.me/ip`
- `https://ipinfo.io/ip`

You should see the VPS IP.

Useful extra checks:

- `https://www.google.com`
- `https://example.com`

`api.openai.com` is advisory only. A VPS IP can be filtered by OpenAI even when the transport itself is healthy.

## If Something Fails

### Bootstrap on the Router Fails

Common causes:

- the router has no internet uplink yet
- router time/NTP is not settled
- package feeds are temporarily unreachable
- the firmware does not match the supported router profile

What to do:

- confirm the router itself can browse out
- wait a minute after the uplink comes up and retry
- rerun the same bootstrap command

### UI Says the Platform Is Waiting for a VPS

That is not an error.

It means:

- the router platform is installed
- but you still need one successful `Sync Router + VPS`

### `Sync Router + VPS` Fails

Read the message literally:

- SSH problem
  - fix `VPS Host / Address`, `SSH User`, password or key
- unsupported OS
  - use the supported VPS profile for now
- port problem
  - if port `443` is busy on the VPS, use another `XRAY_PORT` only in the advanced installer path

## Advanced Path

If you want one local command from a workstation to orchestrate both sides, that still exists:

- [`../install.sh`](../install.sh)

That is the advanced path now, not the primary one.
