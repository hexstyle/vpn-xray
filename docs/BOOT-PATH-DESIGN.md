# Boot-Path & Self-Heal Design

Design-and-verify artifact for changes that touch the router's boot /
recovery path. The boot path is the highest-blast-radius surface in this
stack — a bad edit bricks the router until a manual reflash/reboot, and the
router is often only reachable through the very path being changed. This
document is written **before** implementation and must pass its own
verification checklist before any code lands. Companion to
`docs/DIAGNOSTIC-TREE.md`.

## 1. The boot / recovery environment (measured, not assumed)

Boot order (OpenWrt `START=` priority; lower starts first):

| START | Service | procd? | Role |
| --- | --- | --- | --- |
| 95 | `codex-xray` | no | Renders nothing; starts xray-core, pins egress route, IRQ/offload tuning. `start()` runs at boot. |
| 96 | `codex-transproxy` | no | redsocks + iptables transparent chains; engages failsafe while bringing the path up. |
| 97 | `xray-switch-watchdog` | yes (respawn) | **Running daemon.** Every 10 s: reads the hardware switch; if ON+ready, refreshes egress route, checks `path_active`, and runs `maybe_smoke_recover`. |
| 98 | `router-rules-sync` | yes (respawn) | Running daemon; periodic rules pull/apply. |
| 99 | `xray-health-monitor` | yes (respawn) | Running daemon; memory/crash telemetry, guard restarts. |

Failsafe (`lib-common.sh`): `xray_failsafe_enable` inserts a FORWARD REJECT
chain so clients fail closed while the path is being (re)built;
`xray_failsafe_disable` removes it; a "hold" file suppresses repeated
recovery. The watchdog owns the enable/disable cycle during recovery.

Key mechanism already present — `xray-switch-watchdog` `maybe_smoke_recover`:
- Runs `action=smoke` (via `xray-admin.cgi`) which proxies HTTP/HTTPS/egress
  through `127.0.0.1:1083/1084` → xray → VPS.
- `https_ok`/`egress_ok` are 0 when the xray→VPS dial fails.
- On `SEVERE_FAILURE_THRESHOLD` (2) consecutive severe failures, past a
  `HEAL_COOLDOWN` (90 s), it enables failsafe and `restart_runtime`.

## 2. Problem this design solves

**Cert-pin drift** (DIAGNOSTIC-TREE G10/G11): the VPS regenerates its
self-signed TLS cert (reprovision, renewal); the router still pins the old
cert at `/etc/xray/server.crt`; every xray→VPS dial fails
`x509: certificate signed by unknown authority`. Because VLESS here is
`encryption:none`, TLS *is* the encryption — verification cannot be
disabled, so the pin must be corrected.

Today this manifests as `egress_ok=0` → the watchdog restarts the runtime —
but a restart **cannot** fix it: the pinned cert file is still wrong, so it
restart-loops forever and never recovers. Reboot does not help. This is the
exact "reboot doesn't fix it" failure the operator hit.

## 3. Design decision: where the fix goes (and does NOT go)

**Does NOT touch `codex-xray.init` `start()` / boot path.** No new work at
boot. If the VPS is unreachable at boot, xray starts exactly as today.

**Hooks into the EXISTING recovery the watchdog already runs**, at the one
moment it is warranted: a *severe smoke failure that is about to trigger a
restart anyway*. Cert re-pin is a recoverable cause of "path up but egress
fails" that a plain restart can't fix, so we attempt it **before** the
restart the watchdog was already going to do. On a healthy path this code
never runs (no smoke failure → no re-pin). Zero cost in the common case.

**Implementation shape** (chosen for minimal blast radius):
- A standalone helper `/usr/bin/vpn-xray-repin-cert` (deployed by
  `install-platform.sh` from `routers/*/files/vpn-xray-repin-cert`).
  - Reads VPS `address`/`port`/`serverName` from `/etc/xray/codex-xray.json`.
  - Fetches the leaf cert the VPS serves via `openssl s_client` (bounded).
  - If it differs from `/etc/xray/server.crt`, replaces it and exits 10
    ("changed"); if same, exits 0 ("no change"); on any error exits 1.
  - **Does NOT restart** anything — the caller owns restart.
- The watchdog calls it in the severe-failure branch, *before*
  `restart_runtime`. `restart_runtime` then reloads the corrected cert.
- `codex-xray.init` is **untouched**. The only boot-adjacent file edited is
  the watchdog, and only its recovery branch (not its loop structure).

Rationale for a standalone helper over inlining in the watchdog: the
watchdog daemon is a single giant `sh -c '...'` procd string; inlining
multi-line logic there is quote-fragile and hard to test. A helper is
independently testable (`sh -n`, run by hand) before it is ever wired in.

## 4. The helper contract (bounded, best-effort, idempotent)

```
vpn-xray-repin-cert
  reads:   /etc/xray/codex-xray.json (address, port, serverName)
  probes:  openssl s_client -connect addr:port -servername sni  (timeout ≤8s)
  writes:  /etc/xray/server.crt  ONLY when the fetched cert differs
  exits:   0  = no change (already correct, or could not decide safely)
           10 = cert re-pinned (caller should restart to reload it)
           1  = hard error (openssl missing, no config) — caller ignores
  never:   restarts a service, blocks > ~10s, deletes anything,
           acts on an empty/failed fetch (keeps the existing cert)
```

Guards:
- No config / no address → exit 0 (nothing to do; never guess).
- `openssl` missing → exit 1 (caller treats as "could not help").
- Fetch empty (VPS down / unreachable) → exit 0, keep existing cert (never
  blank the pin — a wrong-but-present cert is recoverable, an empty one is
  not).
- `cmp -s` exact match → exit 0, no write, no restart.
- Bounded: `openssl s_client` under a `timeout`; total runtime ≤ ~10 s so
  the watchdog's 10 s loop is not starved.

## 5. Failure-mode & blast-radius analysis

| Scenario | Behavior | Safe? |
| --- | --- | --- |
| Healthy path | Smoke ok → recovery branch never entered → helper never runs | ✅ no cost |
| VPS down at recovery time | `s_client` fails → helper exit 0, keeps cert → watchdog restarts as before | ✅ same as today |
| `openssl` absent | helper exit 1 → watchdog ignores, restarts as before | ✅ same as today |
| Cert genuinely drifted | helper re-pins (exit 10) → watchdog restart reloads correct cert → path recovers | ✅ fixes the loop |
| Helper has a bug / missing file | watchdog call fails → `|| true` → restart proceeds as before | ✅ degrades to today |
| Man-in-the-middle serves a different cert | helper would pin the attacker cert (TOFU against our own VPS over the router uplink) | ⚠️ accepted: same trust model as install-time fetch; the uplink to our VPS is the existing trust boundary |
| Boot with VPS unreachable | boot path untouched; watchdog enters recovery only when switch ON and smoke fails; helper no-ops on unreachable | ✅ |

Blast radius of a bad edit:
- Helper file broken → `sh -n` catches pre-deploy; at runtime the watchdog's
  `|| true` isolates it. Boot unaffected (helper isn't in boot path).
- Watchdog edit broken → **this is the real risk.** Mitigation: edit ONLY
  the severe-failure branch, keep the loop/quoting intact, validate with
  `sh -n` on the router BEFORE swapping the file, and keep the previous
  file as `.bak` for one-command rollback. codex-xray/transproxy unaffected,
  so even a broken watchdog leaves the base path up (watchdog only adds
  recovery, it is not required for the path to run).

## 6. Boot-scenario walkthrough (must all hold)

1. **Cold boot, VPS up, cert in sync**: xray(95)→transproxy(96) bring the
   path up; watchdog(97) sees smoke ok → never touches the cert. Unchanged.
2. **Cold boot, VPS up, cert drifted**: path comes up but egress fails;
   watchdog hits severe threshold after ~2 cycles, re-pins the cert,
   restarts, recovers — *without operator action*. This is the win.
3. **Cold boot, VPS down**: path can't reach VPS; watchdog re-pin no-ops
   (fetch fails), restarts (as today); when VPS returns, next cycle
   recovers. No worse than today.
4. **Switch OFF**: watchdog clears health state, disables failsafe, never
   enters recovery → helper never runs. Unchanged.

## 7. Test plan (execute before declaring done)

Pre-deploy:
- [ ] `sh -n` the helper and the watchdog locally.
- [ ] Run the helper by hand on the router in the **healthy** state → must
      exit 0, make NO change (cert already matches), NOT restart.
- [ ] Break the cert deliberately (pin a wrong cert), run the helper → must
      exit 10 and restore the correct cert; then a manual xray restart
      recovers egress. Restore.

Deploy:
- [ ] Copy watchdog to `.new`, `sh -n` it **on the router**, only then swap;
      keep `.bak`.
- [ ] Restart the watchdog service; confirm it is running (`procd`), logs
      clean, path still healthy (egress = VPS IP).

Post-deploy (the real proof):
- [ ] With the path healthy, confirm the watchdog does NOT churn the cert
      (no repeated re-pin log lines) over several minutes.
- [ ] Deliberately drift the cert (pin wrong), confirm the watchdog detects
      severe smoke failure, re-pins, restarts, and egress recovers on its
      own within a couple of cooldown cycles — with NO manual step.
- [ ] Reboot the router; confirm the path comes back and, if drifted,
      self-heals; confirm boot is not slowed and the router stays reachable.

Rollback: `mv /etc/init.d/xray-switch-watchdog.bak /etc/init.d/xray-switch-watchdog && /etc/init.d/xray-switch-watchdog restart`.

## 8. Verification results (executed 2026-07-10)

Running the §7 plan surfaced a **pre-existing bug the design depended on**:
the `xray-switch-watchdog` daemon **was never actually running**. Its procd
command is one big `sh -c '<script>'`, but two lines used *literal single
quotes* inside it — `xray_failsafe_enable 'watchdog restarting Xray runtime'`
and `'watchdog detected inactive Xray path while switch is on'`. Those inner
`'` characters closed the outer `'`, so procd received a **truncated** script
(cut off mid-function) plus stray argv words; `sh -c` failed to parse it and
exited immediately, procd respawn-looped, and `ubus` reported
`running: false`. The original (pre-change) file had the same bug — the
watchdog had silently never come up, so its whole recovery layer (and, once
added, the cert self-heal) was dead. The self-heal test's first run "failed"
for this reason, not because of the design — which is exactly what §7 was for.

Fix: the two literal `'…'` strings → `"…"` (the text has no `$`/backtick, so
double quotes are exactly equivalent). All other single quotes in the daemon
body are the correct `"'"$VAR"'"` injection pattern and were left untouched.

Verified after the fix:
- **Daemon runs & is stable**: `procd running: YES`, instance PID stable over
  12 s (no respawn flap), `last-smoke` counter written (proof the loop reaches
  `maybe_smoke_recover`) — where before the fix every counter was permanently
  empty.
- **Healthy path, no churn**: over 90 s the pinned cert did not change, zero
  `re-pinned` log events, `severe-failures` stayed empty, egress = VPS IP. The
  helper is never invoked while the path is healthy.
- **Cert drift, unattended self-heal**: deliberately pinned a wrong cert and
  restarted xray so egress genuinely failed; the watchdog reached
  `severe-failures=2` at ~80 s and the logs show, in order,
  `failsafe: enabled reason=severe smoke failure` (https_ok=false,
  egress_ok=false) → `re-pinned drifted VPS cert before restart` →
  `attempting runtime restart` → egress recovered to the VPS IP with **no
  manual step**.
- **Helper unit behavior**: drift → exit 10 + restore to the served cert;
  already-correct → exit 0, no write, no restart; idempotent on re-run.
- **Boot path untouched**: `codex-xray.init` unchanged; deploy validated with
  `sh -n` on the router before every swap; a `.bak` kept for one-command
  rollback during the change.

Net: the boot/recovery environment is now genuinely functional (the watchdog
runs for the first time), and cert-pin drift — the "reboot doesn't fix it"
class — self-heals unattended.

## 9. Explicitly out of scope (deferred, not silently dropped)

- **G2 kmwan tethering recovery hotplug**: cannot be tested without the Yota
  tether present; hotplug is boot-adjacent. Deferred until testable on the
  real device.
- **Periodic (cron) cert re-sync**: rejected in favor of the watchdog hook —
  the watchdog already runs, already detects the exact failure, and only
  acts when the path is actually broken; a blind periodic poll adds load and
  a second code path for no extra coverage.
- **G6 RSA→ed25519 managed key**: separate from the path; not boot-related.
