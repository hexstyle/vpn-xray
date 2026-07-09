## Install Contract

The full install contract lives in [`docs/INSTALL-CONTRACT.md`](./docs/INSTALL-CONTRACT.md).
Read it before changing any install path. Key invariants:

- **Air-gap from the workstation**: the workstation reaches only the local
  router and the VPS. No public package mirrors, no `raw.githubusercontent`,
  no `codeload.github.com`, no `jsdelivr`, no `fw.gl-inet.com`. Bundle
  every artifact the workstation hands to the router/VPS in the repo.
- **Pre-install param validation**: missing or placeholder values prompt
  the operator interactively; silent failures are a regression.
- **Live step plan**: the installer prints the plan, advances `[N/total]`
  per step, and mirrors state to `/tmp/vpn-xray-install-status.json` for
  the UI.
- **UI banner persists** across page refresh while install is running or
  in a failed-but-recoverable state.
- **Selective-mode fallback to FULL** when the rules repo is unreachable;
  recovery cron retries each minute and removes itself once selective is
  re-applied.
- **No router-generated SSH keys for git**: the installer copies the
  workstation's local SSH key to the router. Auto-detected from
  `~/.ssh/id_ed25519` (then `id_ecdsa`, `id_rsa`) unless the operator
  pins `RULES_GIT_SSH_PRIVATE_KEY_FILE` explicitly.
- **End-to-end success check**: after install, probe `chatgpt.com` through
  the router proxy and surface ✓/✗ in console + UI.

## Router Verification

When changing router logic, UI, sync flow, proxy flow, firewalling, or runtime control paths, always verify internet reachability and the end-to-end routing scheme after the change.

Required verification matrix on a real router when available:
- `VPN off`: hardware/path off, clients behind the router still have direct internet access.
- `VPN on + full`: transparent path on, full-mode routing works, internet access remains usable.
- `VPN on + selective`: transparent path on, selective-mode routing works, internet access remains usable for both selected and non-selected destinations.

Verification rules:
- Management-plane reachability is part of router verification: confirm SSH or HTTPS to the router still works after reloads or topology-affecting changes.
- Wi-Fi client reconnect after reboot or radio reload is part of management-plane verification when wireless settings, boot flow, or uplink failover could affect AP stability.
- For `WAN unplug -> Wi-Fi-only` scenarios, verify that a client can reconnect to the saved SSID/BSSID without manual password re-entry after cable removal, radio reload, and reboot.
- Prefer testing from the LAN client path behind the router, not only from router-local `curl`.
- Treat router-local proxy smoke as necessary but not sufficient.
- Check both control-plane status and data-plane behavior.
- When verifying reboot recovery, record when Wi-Fi or HTTP management comes back and when `path_state=active` comes back; eventual recovery alone is not sufficient.
- If the router is reachable after reboot but `xray_running=true` and `redsocks_running=true` while `transproxy_rule=false`, treat that as a boot regression and keep investigating.
- When uplink failover or repeater mode is involved, verify that `ip route get <VPS IP>` follows the active uplink instead of a stale dead device before declaring the Xray path healthy.
- When reinstalling or resyncing from VPS-managed metadata, verify that the live VPS listener/config still matches the advertised client port before trusting it.
- If you cannot test one of the three states on real traffic, say so explicitly in the final report.
- If a change risks breaking connectivity, inspect firewall/NAT counters and active runtime processes after the change.
- If Ethernet unplug / Wi-Fi uplink / Wi-Fi client access could be affected, explicitly verify that the router stays reachable over Wi-Fi with Ethernet absent, or say that you could not test it.

Network topology guardrails:
- Treat LAN bridge, Wi-Fi, WAN, and firewall zone topology as critical management-plane state.
- IPv6 is disabled in this stack and must remain disabled. Do not enable, re-enable, or rely on IPv6 for routing, firewalling, DNS, RA, DHCPv6, management access, or client connectivity.
- Do not change `network.lan.device`, `network.lan.ifname`, `network.@device[*].ports`, Wi-Fi AP/uplink bindings, or zone attachments by default.
- Do not enable or re-enable `wireless.*.random_bssid` on management AP radios unless the task explicitly requires unstable AP identities and the user accepts the reconnect risk.
- Treat same-radio repeater uplink plus client AP service as a management-plane risk. Prefer uplink on the opposite radio from the primary management SSID when the environment allows it, or call out that the active band was not tested under reassociation.
- Preserve the existing router management path unless the task explicitly requires a topology change.
- If a topology change is necessary, add a rollback path or post-reload reachability check and verify both wired and Wi-Fi client access when available.

Boot and restore guardrails:
- Do not disable `codex-xray` or `codex-transproxy` init services as a workaround for boot ordering. If the hardware switch is on and config is ready, the path must restore during boot without waiting for watchdog polling as the primary recovery path.
- In `selective` mode, boot restoration must not block on a full DNS/rules refresh before returning the transproxy dataplane. Prefer restoring from the last resolved snapshot first, then refreshing in the background.

Git/push checks:
- If Git SSH auth is involved, verify the exact key the router uses.
- Prefer confirming both `ssh -T` auth and the actual Git transport/path the feature uses.

## Fix Scope

When asked to fix, add, or change something on the router — the fix goes into the **codebase** (repo), not just applied live on the device. The live router state must match what a clean install from the repo would produce. Specifically:
- Every fix must land in the repo source files so that the next `install-platform.sh` / `install-router.sh` deploy carries it.
- Do not patch files on the router without also updating the corresponding source in the repo.
- If a config value (UCI, dnsmasq, ipset, rules) needs to change, update the template, profile.env, or install script that sets it — not just the live value.
- After fixing, verify that a fresh deploy from the repo would produce the correct result without manual intervention.

## Verify Before Reporting

Never report a hypothesis to the user as if it were a conclusion. Before saying "the problem is X" or "try doing Y", verify it yourself first:
- If you suspect a VPN/network issue on the workstation, test it yourself (disconnect VPN, change DNS, try the request) rather than asking the user to check.
- If you say "site X works now", actually open it end-to-end from the same device/path the user would use.
- If you identify a cause, reproduce the fix and confirm the result before reporting.
- Do not send the user on diagnostic errands you can run yourself.

## Tree-Driven Repair Development

[`docs/DIAGNOSTIC-TREE.md`](./docs/DIAGNOSTIC-TREE.md) is the root artifact
for everything that installs, diagnoses, or repairs the stack. The contract:

- **Code follows the tree.** Install steps, the VPS repair pipeline, UI
  repair actions, and `install.sh --repair-vps` implement tree nodes. A repair
  behavior with no tree node is a review finding.
- **Risk classes are binding.** Every repair action is `safe`, `disruptive`,
  or `destructive` per the tree's table. `disruptive` actions (daemon
  restarts, firewall rebuilds, mode cutovers) never run synchronously inside
  a CGI request — schedule a detached background job and report its status
  file. `destructive` actions require explicit operator confirmation.
- **Breakage updates the tree first.** When a new failure mode appears in the
  field: (1) add/extend the tree node with symptom, probes, cause, repair,
  verification, risk; (2) then change the code to implement it; (3) re-verify
  the node's "Verify" line on real hardware when available. Unautomated
  findings go to the tree's Gap register.
- **Review gate.** PR review checks that repair-path changes cite the tree
  node they implement, respect its risk class, honor the meta-rules
  (timeouts, single-flight, per-step reports), and that the tree was updated
  when behavior changed.

## File Size Limit

No source file may exceed **500 lines**. This applies to shell, CGI, Python,
HTML, JS, and CSS alike.

- New files: hard limit, enforced at review.
- When touching an oversized legacy file, split it as part of the change
  (sourced shell libs under `/usr/share/vpn-xray/`, extracted JS/CSS for the
  UI) rather than growing it further.
- Splits must keep behavior identical: same entry points, same deploy targets
  (update `install-platform.sh` copy lists in **both** router profiles), and
  pass the contract tests in `tests/`.

Refactor debt register (files >500 lines at the time this rule was adopted;
shrink on touch, largest-risk first):

| File | Lines | Split plan |
| --- | --- | --- |
| `routers/*/files/xray.html` | ~3.8k | extract CSS → `xray.css`; JS → `xray-*.js` modules by card (vps / rules / admin / core) |
| `routers/common/files/router-rules` | ~3.8k | sourced libs under `/usr/share/vpn-xray/rules-lib/` (git, resolve, ipset, dataplane, status) |
| `routers/*/files/xray-vps.cgi` | ~2.3k | sourced libs under `/usr/share/vpn-xray/vps-cgi/` (ssh, profile, inspect, repair, actions) |
| `routers/*/install-platform.sh` | ~1.3k | phase libs (packages, files, uci, services) |
| `routers/*/files/xray-rules.cgi` | ~1.1k | job/status lib shared with other CGIs |
| `bootstrap-router-vps.sh` | ~1.0k | step functions → `common/lib/bootstrap/` |
| `routers/*/files/xray-admin.cgi` | ~0.8k | shared CGI lib |
| `routers/*/install-router.sh` | ~0.8k | step libs under `common/lib/` |
