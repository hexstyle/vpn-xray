# Common Library

This folder contains small shell helpers reused across the installer and profile-specific scripts.

- `env.sh`
  - load `install.env`
  - source profile defaults
  - reject placeholder values
  - derive hosts from SSH targets
  - resolve router and VPS profile directories
