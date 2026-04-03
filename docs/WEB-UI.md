# Web UI

This document describes the standalone web UI served by the router.

Path:

- `https://<router-host>/xray.html`

Backends:

- `/cgi-bin/xray-admin`
- `/cgi-bin/xray-vps`
- `/cgi-bin/xray-rules`

## Design Rules

- the physical GL switch is the source of truth for path enable/disable
- switch enforcement belongs to the router service, not the browser page
- the page should auto-refresh only lightweight status
- the page must not spawn overlapping background work
- logs stay manual

## Main Sections

## `Selected VPS`

This is the editable VPS-profile area.

It contains:

- existing profiles
- create new profile
- label
- read-only profile ID
- one combined `VPS Host / Address` field
- SSH auth method
- only the auth fields relevant to the selected auth mode
- `Read VPS And Update Profile`
- `Sync Router + VPS`

Behavior:

- `Read VPS And Update Profile` is read-first, but it may adopt live VPS-side Xray values into the saved profile
- `Sync Router + VPS` is the authoritative write/apply action

## `Current State`

This is the operational summary.

It shows:

- hardware switch state
- path state
- last VPS check time
- remote public IP
- sync state

It may include expandable technical details, but those should stay secondary.

## `Logs`

Logs are manual.

Rules:

- no auto-load on page open
- refresh button stays next to the log output

## `Selective Address Filter`

This block controls the shared GitHub-backed destination list.

It shows:

- current local routing mode
- shared rules textarea
- concrete status for the current sync/apply lifecycle
- last verification time
- whether the runtime is already aligned with the checked ruleset

It should not drown the operator in trace noise by default.

Detailed diagnostics belong in a collapsed block.

## Status Semantics For Rules

The main status should answer these questions directly:

- is background checking enabled
- what phase is the router in now
- what happened last
- was GitHub already verified
- is runtime aligned or still waiting for a reset/cutover

The page may internally track checksums/signatures, but that belongs in diagnostics, not in the main operator surface.

## Automatic Behavior

The page should do only one kind of background work:

- periodic lightweight status refresh

The page should not:

- auto-run VPS SSH inspection
- auto-load logs
- try to own switch reconciliation

Switch reconciliation belongs to:

- `/etc/init.d/xray-switch-watchdog`

Rules background sync belongs to:

- `/etc/init.d/router-rules-sync`

## Historical Bugs To Avoid Reintroducing

### Blocking initial load

Earlier versions made the page unusable for too long while waiting for optional data.

Current rule:

- page becomes actionable after essential status loads

### Overlapping background requests

Earlier versions let polling and background work overlap, which caused hanging CGI requests.

Current rule:

- no overlapping status requests
- no background VPS inspect in the page

### Actions far from their results

Earlier versions separated buttons from the state they affected, which made the page read like a debug dump.

Current rule:

- action and result stay colocated
- noisy trace output stays hidden by default

## Operator Expectations

The operator should be able to answer, in one pass:

1. which VPS profile is selected
2. whether the hardware switch says the path should be on
3. whether router and VPS are in sync
4. whether shared rules are current with GitHub
5. whether a recent cutover/reset was already completed
