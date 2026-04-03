# Config Folder

This folder contains only configuration templates.

Copy the examples to local untracked files before use:

- `router.env.example` -> `router.env`
- `vps.env.example` -> `vps.env`
- `asus-router.env.example` -> `asus-router.env`

For a minimal first setup, edit only:

- `config/router.env`
  - `ROUTER_HOST`
- `config/vps.env`
  - `VPS_HOST`

Then auto-fill the Xray identity fields:

```bash
./scripts/init-config.sh
```

This generates and synchronizes:

- `XRAY_UUID`
- `XRAY_SERVER_NAME`
- `XRAY_SHORT_ID`
- `XRAY_PRIVATE_KEY`
- `XRAY_PUBLIC_KEY`

Most other values have defaults in the deploy scripts and do not need to be touched for a normal first install.

These local `.env` files are intentionally ignored by git because they contain installation-specific values:

- router addresses
- VPS host
- UUIDs
- Reality keys
- GitHub repo URLs

Use:

```bash
./scripts/init-config.sh
./scripts/validate-env.sh router
./scripts/validate-env.sh vps
./scripts/validate-env.sh asus
```

to make sure placeholders were replaced before deploy.
