# Scripts Folder

This folder contains the supported entrypoints for installation and maintenance.

Main scripts:

- `init-config.sh`
  - copies or updates local env files with generated Xray identity values
  - synchronizes `UUID`, `Reality keypair`, `short id`, and default `server name`
- `validate-env.sh`
  - checks that required values are present and placeholders were replaced
- `deploy-vps-config.sh`
  - renders and deploys the VPS `xray` server config
- `deploy-child-router.sh`
  - deploys the GL router runtime, UI, and shared-rules consumer
- `verify-child-router.sh`
  - smoke-tests the router proxy path
- `deploy-asus-rules.sh`
  - deploys the ASUS shared-rules consumer
- `register-router-rules-deploy-key.sh`
  - registers the router deploy key for the shared-rules GitHub repo

Helper code lives in:

- [`lib/`](./lib)
