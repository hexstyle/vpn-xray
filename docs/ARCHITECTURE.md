# Architecture

## Product Shape

This repository is a wrapper around `Xray-core`, not a replacement for it.

The structure is intentionally split into:

- shared bootstrap helpers
- router profiles
- VPS profiles

That keeps the public install flow simple while still allowing future router firmware targets and future VPS OS profiles.

## Root Install Flow

`./install.sh` is the only top-level entrypoint for the supported setup.

It does five things:

1. initialize `install.env`
2. validate the chosen router and VPS profiles
3. deploy the selected VPS profile
4. deploy the selected router profile
5. run router verification

## Shared Bootstrap Layer

[`../common/`](../common/README.md) contains:

- env loading
- placeholder rejection
- profile resolution
- auto-generation of UUID / Reality values

The quickstart only asks the operator for:

- `ROUTER_SSH`
- `VPS_SSH`

Everything else is either defaulted by the profile or generated automatically.

## Router Profiles

Each router profile contains:

- `profile.env`
  - default values specific to that router / firmware
- `install-router.sh`
  - deploys the runtime, UI, rules engine, and profile bundles
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

That lets the router UI provision a supported VPS directly over SSH later, without hardcoding Debian install logic into the UI layer.

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
