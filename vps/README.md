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

## Supported Profiles

- `debian-13`
  - clean Debian 13 host with SSH access

During router installation, the profile bundles from this folder are copied to the router so the router UI can later provision a supported VPS directly over SSH.
