# Common Router Files

These files are shared by OpenWrt-based router profiles in this repository.

Current shared pieces:

- `router-rules`
  - Xray-only GitHub sync, merge, apply, and status tool for shared destination rules
- `router-rules-sync.init`
  - background sync service
- `router-rules.config.template`
  - rendered router-side config for the shared-rules tool
