# Common Router Payload

These files are copied to supported OpenWrt-based routers and reused by more than one router profile.

- `router-rules`
  - shared-rules sync, merge, and apply tool
- `router-rules-sync.init`
  - background sync service
- `router-rules.config.template`
  - rendered config for the shared-rules tool
- `xray-diag-capture.sh`
  - rate-limited (30 min), single-instance diagnostic snapshot; preserves 5 most recent captures
