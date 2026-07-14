# Common Router Files

These files are shared by OpenWrt-based router profiles in this repository.

Current shared pieces:

- `router-rules`
  - Xray-only GitHub sync, merge, apply, and status tool for shared destination rules
- `router-rules-sync.init`
  - background sync service
- `router-rules.config.template`
  - rendered router-side config for the shared-rules tool
- `files/xray-diag-capture.sh`
  - rate-limited (30 min), single-instance diagnostic snapshot; preserves 5 most recent captures
