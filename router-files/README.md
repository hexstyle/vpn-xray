# Router Files

This folder contains the files that get copied to the router.

Main groups:

- init scripts:
  - `codex-xray.init`
  - `codex-transproxy.init`
  - `xray-switch-watchdog.init`
  - `router-rules-sync.init`
  - `ss-domain-filter.init`
- templates:
  - `codex-xray.json.template`
  - `redsocks.conf.template`
  - `router-rules.config.template`
- web UI:
  - `xray.html`
  - `xray-admin.cgi`
  - `xray-vps.cgi`
  - `xray-rules.cgi`
- shared-rules tool:
  - `router-rules`
- GL switch handler:
  - `gl-switch-xray.sh`

If you want to understand what is deployed to the router, start here together with [scripts/README.md](../scripts/README.md).
