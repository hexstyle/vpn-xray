# Config

This folder contains the local `.env` templates used by the supported quickstart.

## Main Files

- `router.env.example`
  - copy to `router.env`
  - fill only `ROUTER_SSH` for the first install
- `vps.env.example`
  - copy to `vps.env`
  - fill only `VPS_SSH` for the first install

## What Gets Generated Automatically

After you run:

```bash
./scripts/init-config.sh
```

the scripts will generate and synchronize:

- `XRAY_UUID`
- `XRAY_SERVER_NAME`
- `XRAY_SHORT_ID`
- `XRAY_PRIVATE_KEY`
- `XRAY_PUBLIC_KEY`
- derived `ROUTER_HOST`
- derived `VPS_HOST`
- derived `XRAY_SERVER`

## Secondary Profiles

Profile-specific examples that are not part of the main hello-world flow live next to the profile itself. For example:

- `routers/openwrt-shadowsocks-libev/asus-router.env.example`

## Important

Tracked example files stay generic. Your real values belong only in local untracked files such as:

- `config/router.env`
- `config/vps.env`
