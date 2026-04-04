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

## Supported Profiles

- `gl-mt3000-glinet`
  - GL.iNet GL-MT3000 on GL.iNet OpenWrt firmware

## Shared Router Files

[`common/`](./common/README.md) contains assets reused by OpenWrt-based router profiles.
