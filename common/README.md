# Common

This folder contains shared bootstrap and validation helpers used by the root installer and by profile-specific scripts.

- `init-env.sh`
  - fills `install.env` from `install.env.example`
  - derives hosts from SSH targets
  - generates the Xray UUID, Reality keypair, and short ID
- `validate-env.sh`
  - verifies that the chosen router and VPS profiles exist
  - checks that the required SSH and Xray values are no longer placeholders
- `lib/`
  - small reusable shell helpers for env loading, placeholder checks, and profile resolution
