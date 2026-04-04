# Common

This folder contains shared bootstrap and validation helpers used by:

- the advanced local installer
- router profile scripts
- VPS profile scripts

- `init-env.sh`
  - fills `install.env` from `install.env.example`
  - derives hosts from SSH targets
  - generates the Xray UUID, Reality keypair, and short ID
- `validate-env.sh`
  - verifies that the chosen router and VPS profiles exist
  - checks that the required SSH and Xray values are no longer placeholders
- `lib/`
  - small reusable shell helpers for env loading, placeholder checks, and profile resolution

These helpers mainly support the advanced local path.

The primary user-facing path is now router-first and starts from [`../bootstrap-router.sh`](../bootstrap-router.sh), but the advanced installer still reuses the same shared env logic from this folder.
