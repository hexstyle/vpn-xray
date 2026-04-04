# Router Profiles

This folder contains supported router profiles.

Each profile describes one router or firmware family and ships:

- `profile.env`
  - default values for that router / firmware
- `install-platform.sh`
  - router-side installer used by the primary SSH bootstrap path
- `install-router.sh`
  - advanced local entrypoint that still reuses the same router-side platform install path
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
- `install-platform.sh`
  - router-side platform installer
  - safe to run on the router itself after the repository bundle is unpacked there
- `install-router.sh`
  - optional workstation-driven entrypoint for advanced use
- `verify-router.sh`
  - verifies the installed path for that profile
- `files/`
  - payload copied to the router itself
- `README.md`
  - profile-specific setup notes

Router profiles may reuse shared OpenWrt-side assets from [`common/`](./common/README.md).

The intended product shape is:

- primary path
  - SSH into the router
  - run the profile's `install-platform.sh` through [`../bootstrap-router.sh`](../bootstrap-router.sh)
- advanced path
  - use `install-router.sh` from a workstation when you want local orchestration

For OpenWrt-based router profiles, `profile.env` is also the place to declare preflight expectations such as:

- expected hardware / firmware identifier
- bootstrap auto-detect identifier
- required base commands on the target
- whether `dnsmasq` must expose `ipset` support

## Supported Profiles

- `gl-mt3000-glinet`
  - GL.iNet GL-MT3000 on GL.iNet OpenWrt firmware

## Shared Router Files

[`common/`](./common/README.md) contains assets reused by OpenWrt-based router profiles.
