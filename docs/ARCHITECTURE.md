# Architecture

## Product Shape

This repository is a wrapper around `Xray-core`, not a replacement for it.

The structure is intentionally split into:

- shared bootstrap helpers
- router profiles
- VPS profiles

That keeps the public install flow simple while still allowing future router firmware targets and future VPS OS profiles.

## Install Flows

There are now two supported entrypoints:

- primary path
  - [`../bootstrap-router.sh`](../bootstrap-router.sh)
  - bootstrap the platform on the router, then finish VPS setup from the router UI
- advanced path
  - [`../install.sh`](../install.sh)
  - orchestrate both router and VPS from a workstation

The primary path is intentionally router-first.
That keeps the public interface small: the operator only needs router SSH first, then VPS SSH details inside the UI.

## Shared Bootstrap Layer

[`../common/`](../common/README.md) contains:

- env loading
- placeholder rejection
- profile resolution
- auto-generation of UUID and Xray transport key values

The advanced local path only asks the operator for:

- `ROUTER_SSH`
- `VPS_SSH`

Everything else is either defaulted by the profile or generated automatically there.

## Router Profiles

Each router profile contains:

- `profile.env`
  - default values specific to that router / firmware
- `install-platform.sh`
  - router-side installer used by the primary SSH bootstrap path
- `install-router.sh`
  - advanced workstation-driven entrypoint
- `verify-router.sh`
  - verifies the installed path
- `files/`
  - payload copied to the router

The current primary profile is:

- [`gl-mt3000-glinet`](../routers/gl-mt3000-glinet/README.md)

## VPS Profiles

Each VPS profile contains:

- `profile.env`
  - OS and service defaults
- `install-vps.sh`
  - local deploy entrypoint for that profile
- `files/`
  - server config template and remote install script

The current primary profile is:

- [`debian-13`](../vps/debian-13/README.md)

## Router-Side VPS Provisioning

During router install, the supported VPS profile bundles are copied to the router under:

- `/usr/share/vpn-xray/vps`

Only the router-consumable bundle is copied there:

- `profile.env`
- `README.md`
- `files/`

Local desktop-side entrypoints such as `install-vps.sh` stay in the repository on the operator machine and are not copied to the router.

That lets the router UI provision a supported VPS directly over SSH later, without hardcoding Debian install logic into the UI layer.

Profile discovery is directory-based:

- every bundled `vps/<profile-id>/profile.env` is treated as a candidate VPS profile
- the router UI renders the selectable list from those bundled profiles
- if no saved profile explicitly names a VPS OS, the router falls back to the first bundled VPS profile instead of relying on a hardcoded Debian value

In practice:

- the operator chooses a saved VPS profile in the UI
- the profile selects one VPS OS profile
- the router reads that VPS over SSH
- the router renders the selected VPS profile payload
- the router uploads and applies it remotely

## Shared Rules Engine

The shared rules engine is OpenWrt-side and Xray-only in this repository.

It handles:

- GitHub sync
- conflict policy
- local selective/full mode
- runtime cutover state
- `dnsmasq -> ipset` domain tracking

## Physical Switch

The physical GL switch remains the source of truth for path enable / disable.

The browser page is only a control surface.
Enforcement belongs to the router services:

- `xray-switch-watchdog`
- `codex-xray`
- `codex-transproxy`

## Ready-State Gate

The router runtime now has an explicit ready marker:

- `/etc/xray/codex-xray.ready`

Why it exists:

- the router platform can be installed before any VPS is configured
- the traffic path must stay dormant until the router has one valid client profile

Effects:

- if the ready marker is absent, the watchdog will not bring the path up
- once the router successfully applies a VPS profile, the ready marker is created
- the UI exposes this as `Platform Status`
