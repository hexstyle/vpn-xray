# Web UI

This document describes the standalone router UI served at:

- `https://<router-host>/xray.html`

Backends:

- `/cgi-bin/xray-admin`
- `/cgi-bin/xray-vps`
- `/cgi-bin/xray-rules`

## Design Rules

- the UI is a friendly wrapper around the real Xray state
- the physical GL switch is the source of truth for path enable / disable
- switch enforcement belongs to the router service, not the browser page
- the page should auto-refresh lightweight status only
- logs stay manual

## Main Sections

### `Selected VPS`

This is the saved-profile area for the remote Xray server.

It contains:

- existing profiles
- create new profile
- VPS OS profile selector
- one combined `VPS Host / Address` field
- SSH auth method and matching auth fields
- `Save VPS Access`
- `Check & Configure VPS`
- `Apply Profile to Router`

Behavior:

- all three controls stay immediately below the SSH fields; none is hidden in a
  status panel or dependent on a path-tree action
- `Save VPS Access`
  - persists only the label, VPS OS profile and SSH access coordinates
  - never stores the one-shot password or treats displayed Xray identity as
    local input
- `Check & Configure VPS`
  - runs as a detached router job and exposes progress by polling
  - verifies SSH, installs the router-managed key using the one-shot password,
    inspects the live VPS, then installs or repairs Xray when required
- `Apply Profile to Router`
  - becomes available only after the selected profile matches a successfully
    inspected VPS and differs from the live router target
  - runs a detached cutover, validates the VPS certificate, egress IP and
    ChatGPT, and restores the previous config and certificate on failure
- every successful VPS inspection refreshes the read-only Xray values from the
  live VPS; only an empty VPS receives newly generated material
- `Check & Configure VPS` uses that VPS-authoritative identity for remote repair;
  `Apply Profile to Router` is the separate explicit disruptive operation

### `Live State`

This is the operational summary.

It shows:

- hardware switch state
- path state
- last VPS check time
- remote public IP
- sync state

`Profile` is the selected saved profile. `Target` is read from the router's
currently loaded Xray config, so they intentionally differ until the profile
has been explicitly applied and verified.

Technical details stay secondary and collapsible.

### `Selective Address Filter`

This block controls the optional GitHub-backed destination list.

It shows:

- current local routing mode
- shared rules textarea
- compact GitHub sync / runtime status
- whether the router runtime already matches the latest verified ruleset

### `Logs`

Logs are manual:

- no auto-load on page open
- refresh button stays next to the log output

## What The Page Must Not Do

- it must not try to own switch reconciliation
- it must not run heavy VPS SSH loops in the background
- it must not auto-load logs
- it must not flood the CGI backends with overlapping requests

Switch reconciliation belongs to:

- `/etc/init.d/xray-switch-watchdog`

Rules background sync belongs to:

- `/etc/init.d/router-rules-sync`
