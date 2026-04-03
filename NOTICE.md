# Third-Party Notice

This repository is an independent convenience wrapper around upstream software. It is not affiliated with or endorsed by:

- Xray-core / XTLS
- GL.iNet
- OpenWrt

## Upstream Projects Referenced Here

- Xray-core:
  - official project: <https://github.com/XTLS/Xray-core>
  - upstream license applies to Xray itself
- OpenWrt:
  - official project: <https://openwrt.org/>
  - upstream licenses apply to OpenWrt itself and to packages provided by that ecosystem
- GL.iNet:
  - official site: <https://www.gl-inet.com/>
  - device firmware, UI components, and trademarks remain the property of their respective owners

## What This Repository Does

- ships its own scripts, templates, and router-side helper files
- downloads Xray from the official upstream release channel configured in the profile
- deploys configuration onto a user-owned router and VPS over SSH
- licenses its own repository contents under the terms in [LICENSE](./LICENSE)

## What This Repository Does Not Do

- it does not redistribute GL.iNet firmware images
- it does not claim ownership of upstream trademarks
- it does not change or replace upstream software licenses

Before redistributing or packaging third-party binaries together with this repository, review the upstream license terms directly.
