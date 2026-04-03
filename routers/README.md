# Routers

This folder contains supported router profiles.

Each profile describes one router or firmware family and ships:

- `profile.env`
  - default values for that profile
- `files/`
  - scripts, templates, and UI files copied to the router
- `README.md`
  - what is supported and what to expect

## Supported Profiles

- `gl-mt3000-glinet`
  - primary supported router profile
  - GL.iNet GL-MT3000 on GL.iNet OpenWrt firmware

## Secondary / Future Profiles

- `openwrt-shadowsocks-libev`
  - shared-rules consumer for routers that use `shadowsocks-libev`
  - not part of the main hello-world install path

## Shared Router Files

`common/` contains assets reused by multiple OpenWrt-based router profiles.
