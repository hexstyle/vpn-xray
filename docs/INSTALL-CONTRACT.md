# Install Contract

This document fixes the contracts for vpn-xray installation. It applies to
agent work as well as human operators. Violating any item below counts as a
regression.

## Air-Gap Constraint (mandatory)

The installer runs in a closed environment. The workstation can reach **only**:

- the local router (LAN)
- the VPS (SSH)

The workstation **must not** rely on:

- public package mirrors (`downloads.openwrt.org`, `fw.gl-inet.com`,
  `apt.debian.org`, `pypi.org`, …)
- code hosting (`raw.githubusercontent.com`, `codeload.github.com`,
  `raw.jsdelivr.net`)
- any other external host

The router itself **may** reach the public internet at runtime — that is
needed for the rules-repo git sync and for fetching external IP lists. That
is a router-side capability, not a workstation-side one.

The VPS install path may need to fetch Xray once. When the workstation has
no public internet, pre-stage the Xray archive on the workstation (bundled
in the repo) and `scp` it to the VPS instead of curling from GitHub.

## Required Pre-Install Inputs

The installer must check, **before touching anything**, that all required
parameters are filled. If any is missing or still a placeholder, prompt the
operator to fill it interactively and write the answer back to
`install.env`. Required:

- `ROUTER_SSH` — `user@host` for the router
- `VPS_SSH` — `user@host` for the VPS
- `XRAY_SERVER`, `XRAY_PORT`, `XRAY_UUID`, `XRAY_SERVER_NAME`,
  `XRAY_PUBLIC_KEY`, `XRAY_PRIVATE_KEY`, `XRAY_SHORT_ID` — auto-generated
  on first run, but their *presence* must be verified before deploy
- `RULES_REPO_FETCH_URL` — required when `XRAY_RULES_MODE=selective`
- `RULES_GIT_AUTH_MODE` — auto by default; when SSH, the local SSH key
  must be readable so it can be copied to the router

Silent failures are not acceptable. If a parameter is missing and the
operator declines to fill it, abort with a clear message naming the
parameter and what it controls.

## Step Plan and Live Progress

The installer has a fixed plan. It must:

1. Print the plan once at start, e.g.
   ```
   Install plan (12 steps):
     1. Validate parameters
     2. Preflight router model & ipset support
     3. Install bundled packages (offline)
     4. Deploy router files
     ...
   ```
2. Before entering each step, print `[N/12] <step name>`.
3. Write the same step state to `/tmp/vpn-xray-install-status.json` on the
   router so the UI can read it.
4. On step failure: print `[N/12] FAILED: <reason>` plus a `Fix:` line that
   tells the operator what to change. Set `state: failed` in the JSON file.
5. On success: print `Install complete: <N>/<N> steps OK` and clear the
   JSON file.

The status JSON has shape:

```json
{
  "schema": 1,
  "state": "running" | "failed" | "complete",
  "step_index": 4,
  "step_total": 12,
  "step_name": "Deploy router files",
  "step_started_at": 1778071000,
  "error_cause": "",
  "error_fix": "",
  "history": [
    { "index": 1, "name": "...", "status": "ok" },
    { "index": 2, "name": "...", "status": "ok" }
  ]
}
```

## UI Banner

`xray.html` reads the install status JSON via the existing `xray-rules`
CGI status path. While `state == running`, render a red top banner:
`Install in progress — step 4/12: Deploy router files`. While
`state == failed`, render a red banner with cause + fix that **persists
across page refresh**.

The banner cannot be dismissed by the user; it goes away only when:
- `state` flips back to `complete`, **or**
- the recovery cron job below confirms the failure condition is resolved.

## Recovery Cron

When the installer fails on a recoverable step (e.g. github unreachable,
git rules sync failed), it schedules a router-side recheck every minute.
The recheck retries the failed step. On success, it:

1. Updates the install status JSON to `state: complete`.
2. **Removes its own cron entry.**

No persistent cron entries from a successful install. If the cron entry is
present, the install is in a known-failed-but-recoverable state.

## Selective-Mode Fallback

When `XRAY_RULES_MODE=selective`:

1. After router platform install completes, attempt the first git rules
   sync from the configured `repo_fetch_url`.
2. If the sync succeeds and applies a non-empty ruleset, leave selective
   mode active. Done.
3. If the sync fails (DNS, network, auth), apply **FULL** mode as a
   temporary fallback so the user still has working internet.
4. Schedule the recovery cron to retry the sync. On retry success, switch
   from FULL to selective and apply ruleset, then clear the cron.
5. While the fallback is active, the UI banner reads:
   `Selective mode pending: rules sync failed. Currently routing in FULL
   mode. Cause: <…>. Fix: <…>.`

When `XRAY_RULES_MODE=full`:
- Just apply FULL. No retry needed.

## Success Verification

After install, run an end-to-end probe from the workstation through the
router proxy: `curl --proxy http://<router>:1083 https://chatgpt.com -I`.
If the response is HTTP 2xx/3xx, print
`✓ Working: chatgpt.com reachable through router`. If not, print
`✗ Failed: chatgpt.com unreachable. <last log lines>` and surface the same
in the UI banner.

## Idempotence and Speed

- Re-running the installer with no source changes must complete under 60s.
- Each step must short-circuit when its target state is already in place.
- The packages/deps/services progress markers exist for this. Any new step
  must declare its short-circuit predicate.

## Local SSH Key

When the operator has not specified `RULES_GIT_SSH_PRIVATE_KEY` or
`RULES_GIT_SSH_PRIVATE_KEY_FILE`, the installer auto-detects the local
workstation key (`~/.ssh/id_ed25519` first, then `id_ecdsa`, `id_rsa`)
and copies it to `/etc/router-rules/ssh/routerRules_ed25519` on the router.
The router does **not** generate its own key in this mode — that would
require a separate deploy-key dance on GitHub.

When the local key is auto-detected, `git_auth_mode` defaults to `ssh` so
both fetch and push use the SSH key. Setting `RULES_GIT_AUTH_MODE`
explicitly still wins.

## Agent Workflow

For agents working on this codebase:

- **Before touching install scripts**: re-read this contract.
- **No external URLs**: when adding a new install step, verify it does
  not introduce a public-internet dependency.
- **Step plan is part of the API**: changes to the step plan must update
  this document and the UI banner code.
- **Verify with a fresh deploy**: never claim "installer works" until a
  full install completes against a real router from a clean state.
- **Status JSON is the source of truth** for UI; do not duplicate state.
