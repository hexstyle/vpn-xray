# Router Profiles

This folder contains supported router profiles.

Each profile describes one router or firmware family and ships:

- `profile.env`
  - default values for that router / firmware
- `install-router.sh`
  - installs the runtime, UI, and shared-rules engine on the router
- `verify-router.sh`
  - verifies the deployed path
- `files/`
  - scripts, templates, and UI files copied to the router
- `README.md`
  - profile-specific notes

## Profile Contract

To add another router or firmware target, create `routers/<profile-id>/` with the same contract:

- `profile.env`
  - router-specific defaults, package URLs, checksums, ports, runtime toggles, and preflight expectations
- `install-router.sh`
  - installs or updates the router runtime for that profile
- `verify-router.sh`
  - verifies the installed path for that profile
- `files/`
  - payload copied to the router itself
- `README.md`
  - profile-specific setup notes

Router profiles may reuse shared OpenWrt-side assets from [`common/`](./common/README.md), but the top-level installer only needs the profile directory and its `profile.env` to resolve the target.

For OpenWrt-based router profiles, `profile.env` is also the place to declare preflight expectations such as:

- expected hardware / firmware identifier
- required base commands on the target
- whether `dnsmasq` must expose `ipset` support

## Supported Profiles

- `gl-mt3000-glinet`
  - GL.iNet GL-MT3000 on GL.iNet OpenWrt firmware

## Shared Router Files

[`common/`](./common/README.md) contains assets reused by OpenWrt-based router profiles.
