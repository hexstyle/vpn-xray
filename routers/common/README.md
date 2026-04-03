# Common Router Files

These files are shared by multiple OpenWrt-based router profiles.

Current shared pieces:

- `router-rules`
  - GitHub sync, merge, and apply tool for shared destination rules
- `router-rules-sync.init`
  - background sync service
- `router-rules.config.template`
  - rendered router-side config for the shared-rules tool
