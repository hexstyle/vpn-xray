# Diagnostic Decision Tree

This document is the **root artifact** for install, diagnostics, repair, and
review in this repository. Code that installs, diagnoses, or repairs the stack
is written *against this tree*; review and quality gates verify changes
*against this tree*; when a new breakage is found in the field, the tree is
updated **first**, then the code. See `AGENTS.md` → "Tree-driven repair
development" for the process contract.

Every node states: **Symptom → Probes → Causes → Repair → Verify → Risk**.

Risk classes:

| Class | Meaning | Allowed execution context |
| --- | --- | --- |
| `safe` | Read-only or idempotent state write (UCI value, file chown, cache refresh). No traffic interruption. | Anywhere: CGI request path, installer, background. |
| `disruptive` | Restarts a daemon, rebuilds firewall chains, flushes conntrack, cuts live sessions. | Installer steps; **deferred background job** from UI. **Never synchronously inside a CGI request** — the request may be traversing the very path being cut, which hangs the router until reboot (observed 2026-07-09). |
| `destructive` | Deletes state that cannot be regenerated locally (profile store, keys, rules history). | Only with explicit operator confirmation naming what is destroyed. |

Meta-rules (enforced by review):

1. Any repair step that can block must run under a hard `timeout`.
2. Any repair entry point callable from the UI must be single-flight
   (lock; concurrent invocation returns `busy` immediately).
3. Every repair emits a per-step machine-readable report
   (`{"id","status":"ok|fixed|skipped|failed","message"[,"details"]}`)
   plus a raw log the operator can expand. Silence is a defect.
4. `skipped` is for "cannot act safely and existing state is serviceable";
   `failed` is only for "the stack is actually broken here".
5. A repair never regresses a working layer to fix a broken one
   (e.g. never restarts the router dataplane to fix a VPS-side issue).

---

## 0. Entry: "The path does not work"

Order of layers. Diagnose top-down; repair bottom-up (fix the deepest broken
layer first, then re-verify upper layers, which often self-heal).

```
0. Operator-visible symptom
├─ 1. Workstation → router reachability
├─ 2. Router platform (files, services installed)
├─ 3. Router uplink (WAN/repeater/tethering)
├─ 4. Router Xray runtime (codex-xray, redsocks, iptables)
├─ 5. Router → VPS transport (SSH control plane, TCP 443 data plane)
├─ 6. VPS Xray runtime (binary, unit, perms, certs, config, firewall, listener)
├─ 7. End-to-end data plane (LAN client → internet via VPS)
└─ 8. Config coherence (profile ↔ router config ↔ VPS config)
```

---

## 1. Workstation → router

**Symptom**: SSH/HTTP to router times out.

**Probes**: `ping <router>`, `ssh -o ConnectTimeout=5`, check workstation
default route/interface (VPN on the workstation often hijacks the route).

**Causes / Repair**:
- Workstation moved networks or a workstation VPN (Citrix etc.) claims the
  route → fix locally (`--interface`/route), not on the router. `safe`
- Router rebooting / hung → wait; if hung repeatedly, see node 4.4. `safe`
- SSH key changed after reset → installer uses its own known_hosts cache at
  `tmp/ssh/known_hosts`; refresh entry. `safe`

**Verify**: `ssh <router> true` returns 0.

---

## 2. Router platform

**Symptom**: `/usr/bin/router-rules`, CGIs, or init scripts missing/stale.

**Probes**: `ls /usr/bin/router-rules /www/cgi-bin/xray-vps /etc/init.d/codex-xray`;
compare file dates to repo.

**Repair**: re-run `./install.sh` (full platform sync from local checkout;
air-gapped, offline package bundle). `disruptive` (restarts services).

**Verify**: install step plan completes; `verify-router.sh` passes.

---

## 3. Router uplink

**Symptom**: router has no internet; all upper layers appear broken.

**Probes**:
```
ip -4 route show            # default route(s), metric order
ubus call network.interface.wan/wwan/tethering status
cat /sys/class/net/<dev>/carrier
ping -I <dev> 8.8.8.8
ip route get <VPS_IP>       # which uplink the VPS pin follows
```

**Causes / Repair**:
- 3.1 **Preferred uplink up-but-dead** (WiFi repeater associated, gateway
  gone): netifd says `up`, packets die. `preferred_uplink_iface()` requires
  carrier **and** gateway (commit `ec062e0`); if the gateway probe passes but
  traffic still dies, force reselection: `/etc/init.d/codex-xray
  refresh_egress_route`. `safe`
- 3.2 **USB tether (Yota) re-enumerates**: dmesg shows `USB disconnect` +
  `rndis_host register`, kmwan deletes the `tethering` node and does not
  restore it. Repair: `ifdown tethering; ifup tethering` (hotplug now listens
  to `tethering` events). `safe` for the tether, does not touch other uplinks.
- 3.3 **VPS route pinned to dead uplink**: `ip route get <VPS_IP>` shows a
  dead device. Repair: `refresh_egress_route`. `safe`
- 3.4 **Repeater-side SYN burst rate-limit**: rapid sequential TCP connects to
  the same destination get `Connection refused` from the repeater while a
  single connect succeeds (observed on apcli0, 2026-07-09). This is an
  environmental constraint, not a fault. Mitigate in code: reuse one SSH
  session where possible, space retries ≥3s, `ConnectionAttempts=3`. Do
  **not** diagnose "VPS down" from a burst-context refusal — verify with a
  single isolated probe first.

**Verify**: `curl --interface <dev> https://api.ipify.org` from the router.

---

## 4. Router Xray runtime

**Symptom**: LAN clients have no internet or bypass the tunnel; path state
`degraded`.

**Probes**:
```
pgrep -af codex-xray-core; pgrep -af redsocks
netstat -ltn | grep -E ':(1083|1084|1086|12345) '
iptables -t nat -S CODEX_TRANSPROXY; iptables -t nat -S PREROUTING | head
iptables -t mangle -S CODEX_TPROXY
[ -f /var/run/codex-xray-failsafe ] && cat it
uci get router_rules.global.xray_mode
tail -30 /var/log/xray/codex-xray-error.log
curl -m 8 -x http://127.0.0.1:1083 https://api.ipify.org   # expect VPS IP
```

**Causes / Repair**:
- 4.1 **xray-core down / not listening** → `/etc/init.d/codex-xray restart`.
  `disruptive`
- 4.2 **transproxy chains missing** (`CODEX_TRANSPROXY` absent from
  PREROUTING) → `/etc/init.d/codex-transproxy restart`. `disruptive`
- 4.3 **Failsafe stuck on** (`/var/run/codex-xray-failsafe` exists, clients
  blocked) → find *why* it engaged (log line `codex-xray-failsafe: enabled
  reason=...`) before disabling; then `router-rules cutover-xray`. `disruptive`
- 4.4 **Full-mode dataplane errors** (DNS swallowed, UDP rejected): verify the
  three invariants — DNS :53 REDIRECT present in both modes; `CODEX_TRANSPROXY`
  has `--dport 53 RETURN` before the blanket TCP REDIRECT; `CODEX_TPROXY` has
  `--dport 53 RETURN` before the blanket UDP TPROXY (commits `30f83f1`,
  `13c3954`). Repair: redeploy `codex-transproxy.init` + mode cutover.
  `disruptive`
- 4.5 **Wrong upstream identity** (router dials old VPS port/SNI, log shows
  `connection refused` to a port the VPS no longer listens on) → node 8.
- 4.6 **error.log shows `use of closed network connection` in bulk +
  websocket dial refused** → VPS side down, go to node 6; do not restart the
  router runtime for a VPS-side failure (meta-rule 5).

**Verify** (in order): local proxy probe returns VPS IP → LAN client probe
returns VPS IP → all three switch states behave per AGENTS.md matrix.

---

## 5. Router → VPS transport

**Symptom**: router runtime healthy but cannot reach the VPS.

**Probes** (control plane, then data plane):
```
ssh -i /etc/xray/ssh-keys/default_ed25519 root@<VPS> 'echo ok'   # control
python3 socket connect <VPS>:443                                  # data
```

**Causes / Repair**:
- 5.1 **SSH auth broken** (key not in authorized_keys after reprovision) →
  UI collects the root password **once**, re-installs the managed key
  (`install_managed_key_with_password`), never stores the password. `safe`
- 5.2 **SSH refused in burst context** → node 3.4 first; a single isolated
  probe decides.
- 5.3 **:443 closed but SSH works** → VPS xray down, node 6.
- 5.4 **Both closed** → VPS is down/rebuilding or its provider firewall
  changed; nothing the router can repair. Surface reachability + last-known
  state to the operator. `safe`

**Distinguish for the operator** (the credentials form must say which):
`Connection refused/timed out` = reachability problem, password will not
help; `Permission denied` = credentials problem, password will help.

---

## 6. VPS Xray runtime

This is the layer rebuilt by the **repair pipeline**
(`vps/debian-13/files/install-vps.remote.sh`), the single implementation used
by installer, UI, and `install.sh --repair-vps`. Steps run in dependency
order; all steps always run (report completeness beats fail-fast).

| # | Step id | Checks | Fixes | Notes |
| --- | --- | --- | --- | --- |
| 6.1 | `binary` | `$XRAY_BIN` runnable | install from bundled zip; network installer as last resort | air-gap first |
| 6.2 | `service_unit` | unit file exists | write minimal unit; `daemon-reload` | drop-ins (User=xray) still apply |
| 6.3 | `directories` | config+log dirs exist, owned by service user | `install -d` + `chown` | |
| 6.4 | `permissions` | every log file owned by service user; user can actually append | `chown`/`chmod 640`; probe with `runuser` | **uid-drift after reprovision** (`nobody:nogroup` files) — root cause of the 2026-07-09 outage; xray exits status 23 with `RestartPreventExitStatus=23`, so it stays down |
| 6.5 | `certs` | cert+key present | generate self-signed for `$TLS_CN` | `skipped` when CN unknown and cert exists elsewhere — never generate a `CN=` empty cert |
| 6.6 | `config` | staged config passes `xray -test`; else existing config passes | install staged (backup old) | `skipped` when staged invalid but live config valid — never overwrite working config with a broken render |
| 6.7 | `firewall` | ufw allows `$XRAY_PORT` | `ufw allow` | inactive ufw = `ok`, nothing to do |
| 6.8 | `runtime` | unit active AND port bound ≤15s | `reset-failed` + `enable` + `restart` | `reset-failed` is mandatory: a unit failed with `RestartPreventExitStatus` silently ignores plain restart |

Whole pipeline runs under `timeout 90` from the caller (meta-rule 1).

**Verify**: `runtime ok` + TLS probe from router (`curl --resolve <SNI>:443:<VPS_IP>`).

---

## 7. End-to-end data plane

**Symptom**: everything above reports healthy but a LAN client fails.

**Probes**: from a LAN client (not the router): `curl https://api.ipify.org`
(expect VPS IP in full mode), DNS resolution via router, HTTP/3 site if UDP
path matters.

**Causes**: stale conntrack after a mode change (flush via cutover),
client-side DNS cache, source-bypass rule matching the client. All repairs
`disruptive` (cutover) — run via rules workflow, not the VPS repair button.

---

## 8. Config coherence (profile ↔ router ↔ VPS)

**Symptom**: UI shows `Sync State: needs sync`, `router_diff`/`remote_diff`
non-empty; or router dials wrong port/SNI (4.5).

**States and transitions**:
- 8.1 **Profile empty, VPS authoritative** (fresh install, reprovision-adopt):
  copy VPS identity into profile — `adopt_remote_into_profile`. UCI-only,
  `safe`, may run synchronously after a successful repair.
- 8.2 **Profile authoritative, router stale**: rendering
  `/etc/xray/codex-xray.json` + runtime restart —
  `apply_profile_to_router_internal`. **`disruptive`** (hard cutover of the
  transparent path). From the UI this must run as a **deferred background
  job**: the CGI schedules it detached (`start-stop-daemon`/`nohup` + status
  file), returns immediately, and the UI polls the status file. Running it
  synchronously inside the CGI request hung the router on 2026-07-09
  (the request rode the path being cut; fcgiwrap worker never returned).
- 8.3 **Profile authoritative, VPS stale**: `config` step of the repair
  pipeline installs the staged render (6.6). Guarded: never replaces a valid
  live config with an invalid render.
- 8.4 **Both diverged** (operator edited both sides): do not auto-resolve.
  Surface the diff; operator picks direction. Auto-picking is how working
  identities get silently destroyed. `destructive` if forced.

**Verify**: `router_diff` and `remote_diff` empty in status JSON; router
error log free of dial errors to stale endpoints.

---

## 9. Install pipeline (10 steps) failure map

| Step | Typical failure | Node |
| --- | --- | --- |
| 1-2 resolve/render | placeholder or missing env values | validate-env prompts (`safe`) |
| 3 stage bundle | router SSH flaps during upload | 1 / 3.4; installer retries transient SSH errors incl. macOS `Operation timed out`, `Connection closed` (commit `13c3954`) |
| 4 platform install | opkg/files | 2 |
| 5 validate+apply runtime | SSH drop while services restart | retry; treat as transient (same commit) |
| 6 VPS profile provision | VPS SSH auth | 5.1; `install.sh` prompts for password on tty |
| 7 network reload | expected SSH drop | installer waits for recovery, never runs SSH after reload in the same step |
| 8 management plane | UI/CGI not reachable | 2 |
| 9 selective health | rules repo unreachable | falls back to FULL + recovery cron (install contract) |
| 10 e2e probe | any of 3-8 | walk the tree from node 3; **the probe failing does not identify the layer — do not "fix" step 10 itself** |

Stale `install-status.json` after an old failure keeps a red banner in the UI
even when the stack is healthy — clearing it is `safe`; the banner must not be
trusted over live probes.

---

## Gap register

Known gaps — tree entries without full automation yet. When one fires in the
field: implement, then move it up into the tree body.

- **G1**: WiFi repeater rate-limit (3.4) has no automated detector; diagnosis
  is manual (isolated probe vs burst probe).
- **G2**: kmwan `tethering` node loss (3.2) auto-recovery hotplug not written;
  manual `ifdown/ifup`.
- **G3**: deferred router-apply job (8.2) — status file + UI polling
  implemented as `repair_apply` job; no watchdog if the job dies mid-cutover
  (router recovers via failsafe, but the UI shows stale "running").
- **G4**: node 7 client-path probes are manual (AGENTS.md matrix); no
  automated LAN-client harness.
- **G5**: VPS-side `nftables`-managed hosts (no ufw) — firewall step only
  knows ufw; others report `ok` unconditionally.
