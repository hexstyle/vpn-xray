# UI Extensibility Notes

This note captures what is realistically extendable in the GL.iNet admin UI on the tested firmware and what is not.

## Firmware Shape

Observed on the tested router:

- `OpenWrt 21.02-SNAPSHOT`
- GL.iNet SDK4 packages installed
- main web root: `/www`
- main SPA entrypoint: `/www/gl_home.html`
- main JS bundle: `/www/js/app.73f13df2.js.gz`
- feature bundles: `/www/views/gl-sdk4-ui-*.common.js.gz`
- menu definitions: `/usr/share/oui/menu.d/*.json`
- backend RPC modules: `/usr/lib/oui-httpd/rpc/*`
- HTTP gateway binary: `/www/cgi-bin/glc`

Important finding:

- the GL.iNet admin UI is a compiled vendor SPA
- feature pages are modular, but the modules themselves are already built and minified
- backend RPC modules are stored as compiled Lua bytecode or binary modules, not as readable source

## What the Existing UI Tells Us

### Menu system is modular

Example menu entries live under `/usr/share/oui/menu.d/`.

Observed structure:

```json
{
  "index": 40,
  "view": "wgclient",
  "level": 2,
  "parent": "vpn",
  "parent_icon": "vpn",
  "parent_index": 40
}
```

This strongly suggests:

- the SPA dynamically loads pages by `view` name
- the expected bundle naming pattern is `gl-sdk4-ui-<view>.common.js.gz`
- adding a new top-level or second-level page is conceptually possible

### The "Plugins" page is not a generic page-plugin API

The installed packages:

- `gl-sdk4-plugins`
- `gl-sdk4-ui-plugins`

look promising, but inspection shows that this is package/repository management:

- package sources
- install/uninstall
- update repository
- package info

This is a package marketplace UI, not a generic "drop your own page plugin here" framework.

So:

- yes, GL.iNet has a plugin/package subsystem
- no, it is not the same as a stable documented UI-extension SDK

### Button Settings integration is hard-coded

The Button Settings frontend bundle contains hard-coded labels and function handling for:

- `vpn`
- `vpn_client`
- `tor`
- `adguardhome`
- `led`
- `wifi`
- `cellular`
- `repeater`

This means:

- adding `xray` to the existing button-settings page is not just a backend change
- it also requires patching or rebuilding the compiled frontend bundle for `btnsettings`

## Practical Extension Paths

## 1. Native GL.iNet-style page module

This is the most integrated path.

What it would require:

- a menu file:
  - `/usr/share/oui/menu.d/xray.json`
- a frontend bundle:
  - `/www/views/gl-sdk4-ui-xray.common.js.gz`
- optional i18n files:
  - `/www/i18n/gl-sdk4-ui-xray.*.json`
- a backend RPC module:
  - `/usr/lib/oui-httpd/rpc/xray`
  - or `/usr/lib/oui-httpd/rpc/xray.so`

Pros:

- looks native in the GL.iNet UI
- can appear in the menu
- can use the same RPC transport as built-in pages

Cons:

- requires building a compatible frontend bundle for this exact vendor UI stack
- backend RPC contract is not documented in this repo and is not stored as plain source on the router
- patching existing built bundles directly on-device is brittle

Recommendation:

- only choose this path if you are willing to build an IPK outside the router
- do not hand-edit the existing minified `.common.js.gz` bundles on the device

## 2. Standalone admin page served from `/www`

This is the most practical custom path.

What it would require:

- add your own page, for example:
  - `/www/xray/index.html`
  - `/www/xray/app.js`
- add backend handlers via:
  - `/www/cgi-bin/...`
  - and/or a custom RPC module under `/usr/lib/oui-httpd/rpc/`

Pros:

- low risk
- does not require rebuilding the whole GL.iNet SPA
- easy to prototype and debug
- portable to other OpenWrt-based devices

Cons:

- not automatically integrated into the native left-nav menu
- likely accessed by direct URL unless a wrapper menu module is added later

Recommendation:

- this is the best first implementation path for an `xray` control panel
- once stable, it can later be wrapped by a native GL menu module

Current state in this repo:

- implemented as:
  - `/www/xray.html`
  - `/www/cgi-bin/xray-admin`
  - `/www/cgi-bin/xray-vps`
  - `/www/cgi-bin/xray-rules`
- the page intentionally talks to the already-tested shell/init layer instead of duplicating proxy logic in JavaScript
- current page scope:
  - live runtime status
  - VPS profile management and SSH-first sync
  - shared-rules sync and status
  - logs and smoke checks

## 3. LuCI app

In theory this is a familiar OpenWrt path.

But on the tested firmware:

- `/usr/lib/lua/luci` is absent
- vendor package feeds do not expose standard `luci-*` packages

So:

- LuCI is not a first-class extension target on this firmware image
- adding it means bringing in upstream OpenWrt packages or building custom packages yourself

Pros:

- good developer ergonomics if you already have LuCI tooling

Cons:

- not vendor-native
- higher compatibility risk on GL.iNet firmware
- extra package/feed management burden

Recommendation:

- do not choose this as the first path on this specific firmware

## Recommended Path For This Repo

For this router family and this firmware style, the safest order is:

1. Build a standalone `/www/xray/` page first.
2. Expose backend state and actions with a small custom RPC or CGI layer.
3. Keep the current shell/init/UCI logic as the source of truth.
4. Only after that, decide whether the page should be wrapped into a native GL.iNet menu module.

Why:

- the transport/proxy logic already exists and is stable
- the unstable part is UI integration, not backend control
- standalone web UI isolates that risk

## What Would A Minimal Xray Web UI Need

Backend actions:

- get current service status
- get current hardware switch state
- get current router/VPS connection parameters
- start proxy path
- stop proxy path
- restart proxy path
- run a smoke test
- show recent logs

A simple UI can therefore be built around existing shell/service operations first.

## Recommended Boundaries

Do not put business logic into the frontend bundle.

Keep logic in:

- `/etc/init.d/codex-xray`
- `/etc/init.d/codex-transproxy`
- `/etc/gl-switch.d/xray.sh`

Expose only thin control/status APIs to the UI.

## Bottom Line

There are three realistic statements here:

- modifying the GL.iNet admin UI is possible
- adding a native-looking page is possible
- doing it cleanly requires package-style integration, not one-off edits to vendor bundles

For a practical implementation, a standalone page is the best first step.
