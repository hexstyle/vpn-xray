# VPS Profiles

This folder contains supported server-side profiles.

Each profile defines:

- the expected operating system family
- the Xray config template
- default deploy paths and service names

## Supported Profiles

- `debian-13`
  - primary supported server profile
  - clean Debian 13 host with SSH access and Xray installed

More server profiles can be added later without changing the top-level quickstart: the deploy scripts resolve everything from `VPS_PROFILE`.
