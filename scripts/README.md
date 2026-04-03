# Scripts

This folder contains the supported entrypoints.

## Recommended Entry Point

- `install-stack.sh`
  - full hello-world install for the main supported combination

## Step-By-Step Entry Points

- `init-config.sh`
  - creates or updates local env files
  - derives hosts from SSH targets
  - generates the Xray UUID, Reality keys, short ID, and default server name
- `validate-env.sh`
  - checks that required values exist after bootstrap
- `deploy-vps-config.sh`
  - deploys the selected VPS profile
- `deploy-child-router.sh`
  - deploys the selected router profile
- `verify-child-router.sh`
  - smoke-tests the router-side proxy path

## Secondary Scripts

- `deploy-asus-rules.sh`
  - deploys the secondary `openwrt-shadowsocks-libev` rules consumer
- `register-router-rules-deploy-key.sh`
  - registers the router deploy key for the shared-rules GitHub repo

## Helpers

- [`lib/`](./lib/README.md)
