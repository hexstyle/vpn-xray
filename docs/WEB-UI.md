# Web UI

This document describes the standalone router UI served at:

- `https://<router-host>/xray.html`

Backends:

- `/cgi-bin/xray-admin`
- `/cgi-bin/xray-vps`
- `/cgi-bin/xray-rules`

## Design Rules

- the UI is a friendly wrapper around the real Xray state
- the physical GL switch is the source of truth for path enable/disable
- switch enforcement belongs to the router service, not the browser page
- the page should auto-refresh only lightweight status
- logs stay manual

## Main Sections

### `Selected VPS`

This is the saved-profile area for the remote Xray server.

It contains:

- existing profiles
- create new profile
- label
- one combined `VPS Host / Address` field
- SSH auth method and matching auth fields
- `Read VPS And Update Profile`
- `Sync Router + VPS`

Behavior:

- `Read VPS And Update Profile`
  - reads the selected VPS over SSH
  - may adopt live VPS-side Xray values into the saved profile
- `Sync Router + VPS`
  - is the authoritative write/apply action

### `Current State`

This is the operational summary.

It shows:

- hardware switch state
- path state
- last VPS check time
- remote public IP
- sync state

Technical details should stay secondary and collapsible.

### `Selective Address Filter`

This block controls the optional shared GitHub-backed destination list.

It shows:

- current local routing mode
- shared rules textarea
- a compact sync/apply state
- last verification time
- whether runtime already matches the last checked ruleset

### `Logs`

Logs are manual:

- no auto-load on page open
- refresh button stays next to the log output

## What The Page Must Not Do

- it must not try to own switch reconciliation
- it must not auto-run VPS SSH inspection loops
- it must not auto-load logs
- it must not flood the CGI backends with overlapping requests

Switch reconciliation belongs to:

- `/etc/init.d/xray-switch-watchdog`

Rules background sync belongs to:

- `/etc/init.d/router-rules-sync`
