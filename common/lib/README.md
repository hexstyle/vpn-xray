# Common Library

This folder contains small shell helpers reused across the installer and profile-specific scripts.

- `env.sh`
  - load `install.env`
  - source profile defaults
  - reject placeholder values
  - derive hosts from SSH targets
  - resolve router and VPS profile directories
- `bootstrap-lib-a.sh`
  - SSH helpers, VPS bootstrap, temporary key management
  - sourced by `bootstrap-router-vps.sh`
- `bootstrap-lib-b.sh`
  - router staging, timing, output formatting
  - sourced by `bootstrap-router-vps.sh`
- `install-progress.sh`
  - step-plan tracking, writes `/tmp/vpn-xray-install-status.json` for the UI banner
