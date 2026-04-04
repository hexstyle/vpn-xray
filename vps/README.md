# VPS Profiles

This folder contains supported server-side profiles.

Each profile defines:

- `profile.env`
  - OS and service defaults
- `install-vps.sh`
  - the local deploy entrypoint for that VPS profile
- `files/`
  - config templates and remote install scripts
- `README.md`
  - profile-specific expectations and notes

## Profile Contract

To add another supported VPS OS, create a new folder `vps/<profile-id>/` with the same contract:

- `profile.env`
  - must define the VPS identity and compatibility keys used by the installer and the router UI
  - expected keys include:
    - `VPS_PROFILE`
    - `VPS_PROFILE_LABEL`
    - `VPS_DEFAULT_SERVER_NAME`
    - `VPS_OS_ID`
    - `VPS_OS_VERSION_PREFIX`
    - `VPS_REQUIRED_PKG_MGR`
    - `VPS_REQUIRES_SYSTEMD`
    - `VPS_SUPPORTED_ARCH_REGEX`
    - `VPS_INSTALL_SCRIPT`
    - `VPS_SERVER_CONFIG_TEMPLATE`
    - `VPS_REMOTE_META_PATH`
    - `VPS_XRAY_BINARY`
    - `VPS_XRAY_CONFIG_DIR`
    - `VPS_XRAY_CONFIG_PATH`
    - `VPS_XRAY_LOG_DIR`
    - `VPS_XRAY_SERVICE`
- `install-vps.sh`
  - local deploy entrypoint for that profile
- `files/install-vps.remote.sh`
  - remote installer / updater executed on the VPS over SSH
- `files/xray-vps-config.template.json`
  - server config template rendered from generated or saved Xray values

If a new VPS profile follows this contract, it does not need extra router UI code.

## Supported Profiles

- `debian-13`
  - clean Debian 13 host with SSH access

During router installation, the profile bundles from this folder are copied to the router so the router UI can later provision a supported VPS directly over SSH.

The router receives only the router-consumable part of each profile:

- `profile.env`
- `README.md`
- `files/`

The local installer `install-vps.sh` stays on the operator machine. This keeps the router bundle small and keeps the profile contract clean.

Router-side discovery is directory-driven:

- each subdirectory under `vps/` that contains `profile.env` is treated as a supported VPS profile
- those bundles are copied to `/usr/share/vpn-xray/vps` on the router
- the router UI reads the available list from those bundled profiles

So adding a new `vps/<profile-id>/` folder and reinstalling the router profile is enough to make that VPS option appear in the router UI.
