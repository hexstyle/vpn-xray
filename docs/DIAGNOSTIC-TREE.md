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
| `safe` | Read-only or idempotent state write against a **validated, bounded** target (a specific UCI key, a file at a known absolute path, a cache refresh). No traffic interruption. | Anywhere: CGI request path, installer, background. |
| `disruptive` | Restarts a daemon, rebuilds firewall chains, flushes conntrack, cuts live sessions. | Installer steps; **deferred background job** from UI. **Never synchronously inside a CGI request** — the request may be traversing the very path being cut, which hangs the router until reboot (observed 2026-07-09). |
| `destructive` | Deletes or reassigns state that cannot be regenerated locally (profile store, keys, rules history) — **including a recursive `chown`/`chmod`/`rm` whose target path is computed and not validated**. | Only with explicit operator confirmation naming what is destroyed. |

A file `chown` is only `safe` when the path is proven absolute and inside
an expected root. `chown -R "$u:$g" "$(dirname "$X")"` with an empty or
relative `$X` resolves to `.` — the process CWD — and is `destructive`:
that exact line reassigned `/root` to `xray:xray` over an SSH-as-root
session and broke key auth on every repair run (2026-07-09, node 5.1b /
render node R). Validate the path *before* the operation, not after.

Meta-rules (enforced by review):

1. Any repair step that can block must run under a hard `timeout`.
2. Any repair entry point callable from the UI must be single-flight
   (lock; concurrent invocation returns `busy` immediately).
3. Every repair emits a per-step machine-readable report
   (`{"id","status":"ok|fixed|skipped|failed","message"[,"details"]}`)
   plus a raw log the operator can expand. Silence is a defect.
4. `skipped` is for "cannot act safely and existing state is serviceable";
   `failed` is only for "the stack is actually broken here".
5. A repair never regresses a working layer to fix a broken one.
   A requested selected-profile Apply or Repair may replace stale router config
   through node 8.2; an identical healthy local runtime is not restarted.
6. A recursive filesystem op (`chown -R`, `rm -rf`, `chmod -R`) must first
   assert its target is a non-empty absolute path under the expected root;
   otherwise skip and report, never act on the fallback (`.` / `/`).
7. A rendered artifact that still contains a `${PLACEHOLDER}` is a defect,
   not input to act on. Every renderer substitutes every placeholder; every
   consumer of a render rejects a leftover placeholder (node R).
8. Never simulate `VPN off` on a live vanilla-OpenWrt router by stopping its
   dataplane. On platforms such as ASUS without a hardware switch,
   `current_switch_state()` intentionally always returns `on`; watchdogs then
   classify the stop as a real outage, enable fail-safe and restart the path.
   Mark the hardware-off matrix row **not applicable / not tested** there.
   Exercise it only on hardware that exposes a real off state, while still
   verifying direct internet and management reachability from a LAN client.

---

<!-- BEGIN generated node table (common/lib/diag/gen-tree-doc.py) -->
*Generated from `routers/common/files/diag/nodes.manifest` — do not edit by hand.*

| id | layer | title | side | risk | repair | auto | gap |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 1 | Workstation reaches router | xstation | safe | local_route | none | — |
| 2 | 2 | Router platform files installed | router | disruptive | install | none | — |
| 3 | 3 | Router uplink has internet | router | disruptive | uplink_reselect | hotplug | G2 |
| 4 | 4 | Router Xray runtime up | router | disruptive | restart_runtime | watchdog | — |
| 4.1 | 4 | Transparent proxy (redsocks + nat) | router | disruptive | transproxy_restart | watchdog | — |
| 4.1a | 4 | Transparent UDP (QUIC/WebRTC/calls) | router | disruptive | apply_profile | none | — |
| 4.9 | 4 | Software OFF (direct WAN, no redirection) | router | disruptive | mode_off | none | — |
| 4.10 | 4 | Fast routing-mode cutover (5-10s budget) | router | disruptive | mode_cutover | none | — |
| 4.11 | 4 | Rules-lock FD and long-resolve contention | router | disruptive | mode_cutover | none | — |
| 5 | 5 | Router to VPS transport (WS+TLS) | router | disruptive | repin_render | watchdog+repin | — |
| 5.6 | 5 | SSH control plane penalties / external-IP exemption | vps | safe | install | none | — |
| 5.7 | 5 | SSH control rides the Xray tunnel | router | safe | apply_profile | none | — |
| 6 | 6 | VPS Xray runtime | vps | disruptive | repair_pipeline | none | — |
| 7 | 7 | End-to-end: LAN client to internet via VPS | router | disruptive | walk | none | — |
| 8 | 8 | Config coherence (profile = router = VPS) | router | disruptive | apply_profile | none | — |
| 8.5 | 8 | Transport matches VPS | router | disruptive | rerender | none | — |
| R | R | Template rendering (build-time) | build | safe | fix_renderer | none | — |
| 9 | 9 | Install pipeline | xstation | disruptive | reinstall | none | — |
<!-- END generated node table -->

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
├─ 8. Config coherence (profile ↔ router config ↔ VPS config)
└─ R. Template rendering (cross-cutting: feeds nodes 6 and 8)
```

Node **R** is cross-cutting rather than a layer: a render defect surfaces
as a symptom in another layer (a broken VPS config, a corrupted `/root`),
so diagnosis lands elsewhere first. It has its own node because two
separate outages traced back to the same render-correctness class, and the
fix belongs at the renderer, not the layer where the symptom appeared.

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

**Probes**: `ls /usr/bin/router-rules /www/cgi-bin/xray-vps
/etc/init.d/codex-xray /usr/share/vpn-xray/diag/nodes.manifest`;
compare file dates to repo. The platform is incomplete if the CGI exists but
its manifest or the self-hosted `/usr/share/vpn-xray/vps/` installer payload
is missing.

**Repair**: re-run `./install.sh` (full platform sync from local checkout;
air-gapped, offline package bundle). `disruptive` (restarts services).

**Verify**: install step plan completes; `verify-router.sh` passes; the UI tree
endpoint reads its manifest without stderr, and the router-side VPS repair can
install Xray from the bundled archive without a public download.

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
  the same destination get `Connection refused`/`Operation timed out` from the
  repeater while a single connect succeeds (observed on apcli0, 2026-07-09).
  Environmental constraint, not a fault. Mitigate in code: bound the retry
  storm — `ConnectTimeout=6`, one connect attempt, and at most two read-only
  RPC attempts with a 1 s gap (node 3.4a). This caps latency so a rate-limited
  uplink cannot push a request past the UI timeout, while still absorbing a
  single burst rejection. Note: SSH `ControlMaster` multiplexing was tried and
  **reverted** — it left stale control sockets under `/tmp` on the router that
  accumulated and were worse than the burst itself; do not reintroduce it as a
  mitigation. Do **not** diagnose "VPS down" from a burst-context refusal —
  verify with a single isolated probe after a pause first (node 5.2).

- 3.4a **Established control SSH stalls while the managed tunnel works**:
  R8 Repair spent 81 s on an inspection timeout; another run executed the
  server pipeline but exhausted its 170 s deadline during re-inspection.
  The stalled remote shell waited in `pipe_read`, while a fresh SSH flow showed
  retransmits/cwnd=1; this does not identify a provider or filtering cause.
  Native control SSH uses ServerAliveInterval=5/ServerAliveCountMax=2, preserving
  legitimate quiet commands whose SSH peer responds. Read-only auth, inspection
  and certificate RPCs get at most two attempts, only on classified transport
  loss, with separate output per attempt and unchanged global deadline.
  Inspection has a 35 s attempt cap (including its two bounded HTTP inventory
  probes); auth/certificate reads use 15 s. Command timeout, authentication and
  host-key errors are distinct, not reasons to prompt for a password on loss.
  Require successful SSH exit and a final inspection-complete marker before
  publishing/adopting a cache. Mutating upload/install/key operations never
  replay after uncertain execution or a lost report, even if stdout is empty.
  Risk: read-only transport repair is `safe`; provisioning keeps its existing
  disruptive owner. Verify a quiet command, transport-failed then complete
  inspection, no partial adoption, authentication refusal, and exactly one
  mutating pipeline call after response loss. Then repeat only failed Repair.
  Password key bootstrap uses the same keepalive/classification owner, exactly
  once; a preceding key refusal must not turn its later transport/host-key
  failure into a password prompt. Exit 255 can also be the remote command's
  exit status; sshpass likewise passes through child exits 5/6/7. Neither those
  codes nor auth-looking remote stderr prove pre-execution authentication
  refusal. Separate native OpenSSH client diagnostics with `-E` (ERROR level)
  from remote stderr. Only its terminal `user@host: Permission denied (...)`
  diagnostic permits identity fallback; remote/disconnect outcomes never do.
  Verify an executed payload returning auth-looking stderr and 255, loss after
  execution, password child 5/6/7, and genuine refusal followed by one execution
  through the bootstrap identity. Preserve stdin, closed lock FDs and log cleanup.
  With password + keyboard-interactive enabled, sshpass can reject a second
  password prompt (exit 5) before OpenSSH's terminal refusal. For password RPCs,
  native DEBUG2 authentication phases distinguish that pre-auth prompt from
  successful authentication followed by child exit 5/6/7. Require the complete
  prompt phase and a readable/writable private diagnostic file; missing,
  incomplete or failed logging is not proof of bad credentials. Keep debug
  command/key details out of the bounded public raw log. Verify the genuine
  early exit through the existing stdio protocol fixture, emitter and UI, with
  remote-child and uncertain-log cases alongside it. No extra SSH connection.
  Keep the combined diagnostic log through
  post-provision inspection and serialize its actual failure at the terminal.
  Validate every pipeline JSONL row (including an incomplete final row) before
  embedding it in a response; malformed/truncated reports are explicit failures,
  with bounded escaped raw diagnostics and no mutation replay. Validate the
  worker's complete JSON response before publishing it for polling.
  Stage the public/private inspection cache together, check every write and
  publication, and restore the previous pair on publication failure before
  allowing adoption/freshness. Verify these errors through the actual worker
  and polling consumer with controlled SSH/filesystem leaves, under set +e.

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
- 4.1a **Selected UDP destinations are blackholed** (2026-11-26). Symptom:
  TCP browsing still works, but QUIC/WebRTC and call media to selectively
  routed destinations stall or fall back to TCP; `/proc/net/snmp` shows
  `Udp: ... NoPorts` growing; `nft list chain inet vpn_xray_dynamic
  udp_prerouting` and `iptables -t mangle -S CODEX_TPROXY` both TPROXY to
  `127.0.0.1:1086`, while `netstat -lnup | grep 1086` is empty and the
  effective `/etc/xray/codex-xray.json` has only the 1083/1084 inbounds.
  Cause: the selected-profile renderer (`render_router_config`) emitted the
  HTTP and SOCKS inbounds but dropped the legacy template's
  `dokodemo-door` `transparent-udp` inbound, so every selected UDP datagram
  was delivered to a closed local port. Repair: render the UDP inbound with
  the UCI tproxy port (default 1086) and `sockopt.tproxy=tproxy`, then apply
  the selected profile (disruptive, detached). Verify: 1086 is listening,
  the rendered JSON contains the inbound, a LAN UDP probe to a selected
  destination is relayed (NoPorts stops growing), and the TCP path still
  returns the VPS egress IP. `disruptive` (Xray restart).
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
- 4.5a **A domain is present in selective rules but its current traffic
  bypasses Xray.** Compare the client's/router-dnsmasq A records with
  `resolution_map.tsv` and `ipset test xray_selective_dst <current-ip>`.
  Geo-distributed CDNs can return different edges from Google DoH versus the
  resolvers configured for dnsmasq. The old resolver stopped after the first
  successful DoH answer, so the periodic refresh remained internally fresh
  but never contained the addresses actually handed to LAN clients. This is
  especially visible with `chatgpt.com`: the snapshot can contain Lumen
  `8.6.112.6`/`8.47.69.6` while dnsmasq returns Cloudflare
  `104.18.32.47`/`172.64.155.209`. On firmware whose dnsmasq reports
  `no-ipset`, a static snapshot alone cannot close the mismatch: the same
  resolver can rotate between both pools on consecutive requests, and exact
  base-domain pre-resolution cannot learn a newly requested subdomain.
  Repair: when dnsmasq has `nftset`, populate a dedicated native nftables set
  from every real LAN DNS answer and route that set through supplemental TCP
  REDIRECT and UDP TPROXY hooks. Keep the pre-resolved legacy ipset as the
  cold-boot fallback; build it by unioning answers from **all configured
  dnsmasq resolvers**. Query DoH and other fallback resolvers only when every
  configured resolver returns nothing; a slow or geo-different fallback must
  not delay or override the DNS view actually used by LAN clients. Resolver
  probes must explicitly request only A records: waiting for AAAA answers is
  both unnecessary and contrary to this stack's IPv4-only invariant. Verify
  the current A records in either the legacy or dynamic set, then make a real
  LAN request and confirm the selective REDIRECT/TPROXY counters and Xray
  access log advance. Rebuilding the hooks is `disruptive`; schedule it
  outside CGI request handling.
- 4.6 **error.log shows `use of closed network connection` in bulk +
  websocket dial refused** → VPS side down, go to node 6; do not restart the
  router runtime for a VPS-side failure (meta-rule 5).
- 4.7 **Watchdog restart storm from uncorrelated single-metric smoke noise**
  (2026-08-31). Symptom: `xray-switch-watchdog` restarts the runtime every
  ~90-180 s around the clock; `logread` shows `runtime smoke failed` with a
  *different* one of `https_ok`/`egress_ok`/`openai_ok` false each cycle,
  never all together; LAN clients feel constant micro-outages on the
  selectively-routed domains. The path itself is not broken: 15 sequential
  and 30 parallel **completed** TCP handshakes to the VPS all succeeded
  instantly (0% loss); `mtr --tcp` showing 47-57% "loss" to the VPS on port
  443 **and** identically on port 22 was a red herring — that is an
  anti-scan artifact of mtr's half-open SYN-then-immediate-RST probing
  pattern being penalized upstream, not loss of real traffic (real,
  completed connections are unaffected, and the effect is not port-443/VPN
  specific since SSH shows the same number). Root cause: xray's client mux
  (`concurrency: 8`) occasionally head-of-line-blocks a single smoke stream
  behind genuine concurrent LAN traffic for a few seconds — a transient
  application-layer contention blip, not a network or firewall fault. The
  old watchdog counted *any one* core check failing on 2 consecutive
  ~45-90s-apart probes as `severe` even when it was a different metric each
  time (the signature of noise — a real outage fails every check, every
  probe) → restart → the restart itself re-opens dozens of mux/LAN streams
  at once, which is exactly the load that trips the next flaky check ~90 s
  later. Self-sustaining, self-inflicted loop.
  **Repair**: (a) `smoke_json` (`xray-admin-status.sh`) retries each core
  check once immediately on a transient `curl:` failure before recording
  it, absorbing a single in-probe blip; (b) the watchdog only counts a probe
  as `severe` (fast 2-strike restart) when **two or more** core checks fail
  *together in the same probe* — the correlated signature of a real
  outage; an isolated single-metric miss instead increments the existing
  lenient counter (renamed `PARTIAL_FAILURE_THRESHOLD`, was
  `OPENAI_FAILURE_THRESHOLD`), which still requires 4 consecutive misses
  before restarting. `safe` (source-only; a genuine outage still restarts
  within 2 probes, ~90 s — only the false positives stop).
- 4.7a **Healthy WS traffic but watchdog repeatedly reports `smoke probe
  unavailable`.** Verify the router-local HTTP/SOCKS probes first, then run
  `command -v timeout` and the watchdog's exact CGI command. Some OpenWrt
  images do not ship a standalone `timeout`; an unconditional invocation is
  suppressed by `2>/dev/null`, produces an empty result, and increments the
  severe counter even though Xray is healthy. Repair: invoke the CGI through
  the shared bounded-run helper, which uses `timeout` when installed and a
  portable TERM/KILL watchdog otherwise. Verify the CGI returns status `ok`,
  the severe counter clears on the next cycle, and no Xray PID changes. This
  watchdog-only repair is `safe`; it must not restart the dataplane.
- 4.8 **Some HTTPS destinations hang while other traffic through the same VPS
  works** (2026-09-29). Symptom: the proxy reports the correct VPS egress IP,
  direct HTTPS from the VPS succeeds, but repeated TLS handshakes to
  `chatgpt.com` intermittently time out. A temporary client using the same
  VPS profile reproduces the fault with outbound VLESS Mux enabled and
  completes 5/5 probes with only Mux disabled. Cause: WebSocket transport's
  shared Mux connection head-of-line-blocks otherwise independent browser
  TLS streams. Probe: repeat both the hostname request and a forced-IP
  request through a profile-specific temporary SOCKS listener; do not accept
  a successful direct VPS curl as proof of the tunnel. Repair: render
  `"mux":{"enabled":false}` in every router config path (install template,
  VPS-profile renderer, admin probe and revive helper). Verify: repeated
  `chatgpt.com` requests through the temporary profile and then the normal
  router proxy complete, and the observed egress IP is the VPS. `disruptive`
  when applied to the live router because Xray must restart; source/template
  changes alone are `safe`.

- 4.9 **Software OFF: an operator wants direct routing without touching the
  physical switch** (2026-11-26). Symptom: the UI must offer a third routing
  state; a hand-stopped path is resurrected by the watchdog/health monitor and
  the repair/verify path treats the intentional outage as a failure. Cause:
  the stack only had `full` and `selective`, and every guard keyed on the
  hardware switch alone. Repair: `xray_mode=off` is a first-class state.
  `path_requested()` returns false in off even when the switch is ON;
  watchdog, health monitor and the switch helper keep the path down and never
  enable fail-safe; `codex-transproxy apply_mode` removes NAT/mangle/nft and
  stops redsocks; `codex-xray` and its tunnel stay stopped; VPS Apply/Repair
  continue over direct SSH and report `path_health=not_checked`. Selective
  ipset and DNS snapshots stay warm so leaving OFF is local. `disruptive`
  (stops the dataplane) but executed from the detached mode job. Verify:
  `xray_mode=off`, switch ON, no `CODEX_TRANSPROXY`/`CODEX_TPROXY` rules, no
  1083/1084/12345 listeners, LAN internet works directly, and two watchdog /
  health cycles do not bring the path back.
- 4.10 **A routing-mode change takes minutes** (2026-11-26). Symptom: moving
  the Full/Selective control runs a full cutover — Git, a complete DNS
  resolve, Xray restart, redsocks restart and dnsmasq restart — and can hold
  the shared rules lock for a minute or more; LAN sessions drop. Cause:
  `set-mode-cutover` called `hard_cutover_xray_internal`, which is the
  sync/apply path, not a dataplane-only switch. Repair: `set-mode-cutover`
  now persists the mode and calls `codex-transproxy apply_mode`, which
  replaces only the firewall rules in place, starts a missing daemon only
  when leaving OFF, and never restarts a healthy one. `full` keeps the
  selective ipset/DNS snapshot warm; `selective` restores it from the last
  resolved snapshot (or warms in a detached job when no snapshot exists).
  Lock wait is 8s, job timeout 25s, UI confirmation 45s. The SSH tunnel
  handshake is not part of the switch budget: Xray binds its local listeners
  immediately and retries the WS dial while the tunnel connects; a genuinely
  dead transport is still surfaced by the watchdog smoke. `disruptive`
  (firewall rebuild) in the detached mode job. Verify: mode changes complete
  in a few seconds without Xray/redsocks PID changes, and the selected
  dataplane works immediately after each switch.

- 4.11 **Every later apply/switch reports `router-rules lock timeout`**
  (2026-11-26). Symptom: the first mode change succeeds, then all later
  `Apply`/mode switches wait for the full lock budget and fail; `ps` shows a
  stale `router-rules set-mode-cutover` or `build-xray-ipset` process and
  `lsof`/`/proc/*/fd` shows Xray, redsocks, dnsmasq or a detached warm job
  holding `/tmp/router-rules.flock`; a background DNS resolve can hold the
  same lock for a minute. Causes: (a) a daemon or detached subshell inherits
  the `flock` FD9 from the process that started it, so it keeps the lock for
  its lifetime; (b) `build-xray-ipset` performs the long DNS resolve while
  holding the main rules lock. Repair: close FD9 (`9>&-`, or `exec 9>&-` in a
  detached subshell) for every process that starts a daemon or a detached
  job; resolve under a separate `/tmp/router-rules-resolve.flock` and take
  the main lock only for the fast ipset/DNS-conf build; publish
  domains/literals/resolved/map snapshots atomically (sibling temp + `mv`);
  make background drift use the cached snapshot so it cannot hold the main
  lock for a DNS refresh. Verify: start `router-rules build-xray-ipset` on a
  stale snapshot, then switch Full/Selective/Off/Selective through the UI
  while it runs; every switch completes in 5-10s, the main lock is free
  except for the brief build, and no daemon or warm job remains a lock
  holder afterwards.

**Verify** (in order): local proxy probe returns VPS IP → LAN client probe
returns VPS IP → all three switch states behave per AGENTS.md matrix.
For 4.7 specifically: `tests/test_xray_runtime_contract.sh` asserts the
renamed threshold; on hardware, watchdog restarts should drop to near zero
under steady real LAN load while a real full outage (VPS stopped) still
restarts within ~90 s. For 4.8, the same test asserts that every config
generator explicitly disables Mux.

---

## 5. Router → VPS transport

**Symptom**: router runtime healthy but cannot reach the VPS.

**Probes** (control plane, then data plane):
```
ssh -i /etc/xray/ssh-keys/default_ed25519 root@<VPS> 'echo ok'   # control
python3 socket connect <VPS>:443                                  # data
```

**Causes / Repair**:
- 5.1 **SSH key auth broken after reprovision.** Two distinct root causes,
  and telling them apart is the whole point — re-appending the key fixes
  only the first:
  - 5.1a **Key absent from `authorized_keys`** → collect the root password
    **once**, append the managed key, never store the password. `safe`
  - 5.1b **Home/`.ssh`/`authorized_keys` owned by the wrong user.**
    With `StrictModes yes` (sshd default) an `authorized_keys` the login
    user does not own is **silently ignored** — the key is present but
    every attempt returns `Permission denied`. Re-appending can never fix
    this. Repair: in the same password session that installs the key,
    `chown <user>:<group> $HOME $HOME/.ssh $HOME/.ssh/authorized_keys` and
    re-assert `chmod 700 .ssh / 600 authorized_keys`. Implemented in
    `install_managed_key_with_password`. `safe`
    - **True origin (2026-07-09):** the drift was *not* an external
      snapshot artifact — **our own repair pipeline caused it** via the
      certs-step `chown -R` on a relative path (node R / node 6.5). The
      repair fixed key auth with the password, then the same run
      re-corrupted `/root`, so it looked like an unfixable loop. The
      lesson is dual: 5.1b is the *symptom*; node R is the *cause*. Always
      ask "what wrote this ownership?" before assuming the environment did.
  - Diagnostic tell: key **is** in `authorized_keys` (grep match) yet
    `ssh -v` shows `Offering public key ... Permission denied` → suspect
    5.1b, check `stat` ownership of the home chain, not the key list.
  - 5.1c **Key algorithm rejected by the server.** The managed key is RSA
    (`ssh-rsa`). OpenSSH 10 on the VPS drops SHA-1 `ssh-rsa` and accepts
    only `rsa-sha2-256/512`; an RSA key still authenticates via rsa-sha2,
    but if a hardened `PubkeyAcceptedAlgorithms` also excludes those, the
    key fails regardless of ownership. Tell: `ssh -v` server
    `server-sig-algs` list lacks `rsa-sha2-*`. Fix is out of band (relax
    sshd, or switch the managed key to ed25519). `safe` to diagnose,
    profile change needed to fix. (Gap G6.)
- 5.2 **SSH refused/timed out in burst context** → node 3.4 first; a single
  isolated probe after a pause decides. Do not read a burst-context
  `Operation timed out` as auth failure. Also inspect the VPS firewall before
  declaring the listener dead: an `ufw limit 22/tcp` rule uses a shared
  `xt_recent` bucket, so unrelated Internet scans plus the router's inspection
  burst can return an immediate `Connection refused` even while `sshd` is
  healthy and listening. If the VPS already exposes a separately allowed SSH
  listener, save that port as the profile's local access coordinate and repeat
  the real inspection; do not weaken the public port-22 firewall merely to make
  the UI retry faster. The workstation installer must add that saved
  `VPS_SSH_PORT` to **every** direct VPS SSH operation (metadata read, runtime
  probe, and managed-key registration); reading the variable but silently
  dialing port 22 reproduces stale-profile installs. `safe`
- 5.3 **:443 closed but SSH works** → VPS xray down, node 6.
- 5.4 **Both closed** → VPS is down/rebuilding or its provider firewall
  changed; nothing the router can repair. Surface reachability + last-known
  state to the operator. `safe`
- 5.6 **SSH control plane locks itself out after timeouts** (2026-11-26).
  Symptom: `Apply`, `Repair` and the UI inspection fail with `SSH` exit
  255 after ~17 s, while the router's proxy/tunnel data plane stays healthy;
  the VPS sshd journal shows `Accepted publickey` for the router's external
  IP but the session never returns. OpenSSH >=9.8 enables
  `PerSourcePenalties`; bounded control sessions that hit their timeout are
  counted as `grace-exceeded`/`noauth` and later connections are delayed or
  dropped. Probes: `sshd -T | grep -i persource`, the sshd journal for the
  router's external IP, and a direct `ssh` from the router (it prints the
  first command output, then stalls). Cause: penalties configured without
  an exempt list, plus password authentication left enabled (the same
  journal shows `Failed password` brute force). Repair: the VPS installer
  derives the router's external IP from `SSH_CLIENT` (never the VPS's own IP)
  and writes `PerSourcePenaltyExemptList <client-ip>` together with
  `PasswordAuthentication no`, `KbdInteractiveAuthentication no`,
  `PermitRootLogin prohibit-password`; validate with `sshd -t` and reload.
  `safe`. Verify: `sshd -T` shows the dynamic exempt and password auth off;
  a fresh router control command returns its full output; Apply/Repair pass.
- 5.7 **External SSH session stalls after authentication** (2026-11-26).
  Symptom: with the tunnel healthy, a new external SSH command from the
  router returns its first line and then hangs; the same command through
  the Xray tunnel's VPS-localhost path works. Cause: the ISP/VPS path
  throttles or stalls new external interactive SSH sessions, while the
  established tunnel is unaffected. Repair: when `dial_mode=ssh_tunnel`,
  `ssh_cmd`/`ssh_stdin_cmd` use `xray-ssh-connect.py` as the SSH
  `ProxyCommand` (HTTP CONNECT via the router's Xray proxy to the VPS's
  `127.0.0.1:22`) so control/inspection reuse the tunnel; keep the direct
  path as a fallback when the tunnel/Xray proxy is down. `safe`. Verify:
  the router's inspection/Apply completes through the tunnel-localhost path
  and the VPS journal records the session from `127.0.0.1`.
- 5.5 **TCP :443 opens but TLS stalls only for selected SNI values.** Tell:
  plaintext sent to `:443` receives the server's HTTP-on-HTTPS rejection and
  TLS without SNI (or with a neutral control SNI) completes, while the
  configured camouflage SNI times out; the VPS journal records `TLS handshake
  ... i/o timeout` from the router's public IP. This is SNI-aware filtering on
  the network path, not a dead listener, certificate drift, or an Xray process
  failure. Repair: explicitly rotate the SNI on the **VPS first**, regenerate
  its certificate for the new name, verify a real TLS handshake from the
  router, then let the router re-read the VPS metadata and render its client
  config from that remote state. Never change only the router's SNI. The
  rotation restarts the VPS daemon and the router apply cuts sessions, so both
  phases are `disruptive` and require rollback backups.
- 5.6 **The listener and small/spaced probes are healthy, but response bodies
  stall through Xray.** Tell: VPS destination sockets accumulate `Recv-Q`, the
  corresponding outer VPS→router socket accumulates `Send-Q`, and `ss -tin`
  reports repeated retransmits, `cwnd:1` and exponential RTO backoff while
  direct requests from the VPS stay fast. A port change can appear healthy in
  one short run and fail in the next, so it does not by itself prove port
  filtering. Confirm protocol-specific path interference by transferring a
  response body over the profile's managed SSH connection: if SSH carries it
  while direct WS+TLS and raw/REALITY both stall, VPS capacity, destination
  blocking, Xray transport choice, Mux and profile drift are excluded. Also
  test a smaller `tcpMaxSeg`; do not keep it when loss is unchanged.
  Repair for this confirmed case: set `XRAY_DIAL_MODE=ssh_tunnel` in the
  authoritative VPS metadata, re-inspect/adopt it, and have a supervised
  router SSH local-forward carry only the Xray server hop. The rendered Xray
  client dials loopback while status/coherence continue to report the VPS
  endpoint. The tunnel uses the profile's managed key, starts before Xray,
  respawns, and is removed automatically for direct profiles. Verify the
  live path through that same hop after validated application (node 8.2);
  an isolated candidate is an optional diagnostic. A client config
  cutover remains `disruptive`; never change the uplink MTU or LAN bridge as a
  shortcut.
  A similar failure on 2026-11-19 also affected SSH: the selected
  38.180.11.240 VPS served complete responses locally, but direct candidate
  responses stalled after HTTP 200 with growing VPS send queues and TCP
  retransmissions. The SSH candidate also failed. This does **not** establish
  protocol-specific filtering or justify an automatic SSH fallback. Compare
  bounded bulk transfers over the actual router and workstation LAN paths,
  including per-connection MSS, before choosing a repair; never change LAN or
  uplink MTU based only on a partial response.
  If a listener-port move is still required, change it on the **VPS first**,
  update managed metadata and host firewall in the same transaction, verify
  local TLS, then re-inspect/adopt it on the router with a rollback backup.

**Noise trap — repeated failed probes self-inflict a lockout.** Each failed
key attempt counts against sshd `MaxAuthTries` (default 6), and a fail2ban
`sshd` jail bans the source IP after enough failures. Symptom: after a burst
of diagnosis attempts, even a *known-good* password starts returning
`Permission denied, please try again` or `Connection closed`, from the same
IP, transiently. Do not conclude "password is wrong" — pause, verify from a
different IP or after the ban window, and space attempts. The repair path's
bounded retries (3.4) exist partly to stay under these limits.

**Distinguish for the operator** (the credentials form must say which):
`Connection refused/timed out` = reachability problem, password will not
help; `Permission denied` with the key present = ownership/algorithm
(5.1b/5.1c), password re-install fixes ownership; `Permission denied` with
the key absent = 5.1a, password re-install fixes it.

---

## 6. VPS Xray runtime

This is the layer rebuilt by the **repair pipeline**
(`vps/debian-13/files/install-vps.remote.sh`), the single implementation used
by installer, UI, and `install.sh --repair-vps`. Steps run in dependency
order; all steps always run (report completeness beats fail-fast).

| # | Step id | Checks | Fixes | Notes |
| --- | --- | --- | --- | --- |
| 6.1 | `binary` | `$XRAY_BIN` runnable | install from bundled zip; network installer as last resort | air-gap first; the UI repair tar must include the VPS-architecture archive from `/usr/share/vpn-xray/vps/<profile>/packages/` as `/tmp/xray-bundled.zip` — staging only config/meta/script makes a clean VPS depend on blocked public installers |
| 6.2 | `service_unit` | unit file exists | write minimal unit; `daemon-reload` | drop-ins (User=xray) still apply |
| 6.3 | `directories` | config+log dirs exist, owned by service user | `install -d` + `chown` | |
| 6.4 | `permissions` | every log file owned by service user; user can actually append | `chown`/`chmod 640`; probe with `runuser` | uid-drift after reprovision (`nobody:nogroup` log files) makes xray exit status 23 under `RestartPreventExitStatus=23` so it stays down. **One** of two causes of the 2026-07-09 outage — the other, and the recurring one, was 6.5 below. |
| 6.5 | `certs` | cert+key present **at a validated absolute path** | generate self-signed for `$TLS_CN` | **THE recurring corruptor of the 2026-07-09 outage.** `chown -R "$u:$g" "$(dirname "$TLS_CERT_PATH")"` ran with `TLS_CERT_PATH` empty (render never substituted it, node R) → `dirname` = `.` → recursive chown of the SSH CWD `/root` → key auth broke every run (5.1b). Guard: refuse any non-absolute cert path, report `skipped`, touch nothing. Also `skipped` when CN unknown — never generate a `CN=` empty cert. |
| 6.6 | `config` | staged config has **no unsubstituted `${…}`** AND passes `xray -test`; else existing config passes | install staged (backup old) | Two guards: (a) reject a staged render still holding a `${PLACEHOLDER}` — it passes `xray -test` (a placeholder is a valid string) but silently breaks the tunnel, e.g. WS path = literal `${XRAY_WS_PATH}` (node R); (b) `skipped` when staged invalid but live config valid — never overwrite a working config with a broken render. |
| 6.7 | `firewall` | ufw allows `$XRAY_PORT` | `ufw allow` | inactive ufw = `ok`; **no-ufw host = `ok` unconditionally, which is a blind spot** (Gap G5) — an nftables-only host with 443 closed is reported healthy |
| 6.8 | `runtime` | unit active AND port bound ≤15s | `reset-failed` + `enable` + `restart` | `reset-failed` is mandatory: a unit failed with `RestartPreventExitStatus` silently ignores plain restart |
| 6.9 | `tcp_capacity` | kernel log has no recent `TCP: out of memory`; TCP memory watermarks are sane for the host | install bounded TCP memory sysctls derived from RAM and reload them | A live listener and successful one-shot probe can hide intermittent WebSocket/TLS failures when the kernel refuses new TCP allocations. Tell: repeated real proxy requests lose individual connections while `journalctl -k` records `TCP: out of memory` and ordinary userspace RAM is still available. Diagnose socket/slab counts and `net.ipv4.tcp_mem`; do not treat this as Xray config drift. The rendered VPS config also sets an explicit level-0 `connIdle` timeout so abandoned destination sockets cannot accumulate indefinitely. Repair is `safe` when only raising an abnormally low TCP budget within a RAM-bounded ceiling; applying the config remains `disruptive` under 6.8 because it restarts Xray. Verify with a repeated router-proxy request set, bounded socket count, and a clean post-repair kernel log. |

Node 6.9 also owns native BBR availability, runtime selection and boot persistence.
On 2026-11-19, the actual 38.180.11.240:443 managed SSH-tunnel path with BBR
completed three router-origin ChatGPT bodies (739300/738603/738523 bytes), with
matching VPS egress. Direct ports 443/8443/80, CS1 marking, and direct BBR did
not restore complete transfers. Earlier Cubic SSH had one complete response
followed by truncation; the evidence supports the working combination, not BBR
as a proven sole cause or attribution to a provider/filter.
Probe the native available algorithms; load the already-installed `tcp_bbr`
module if needed, then verify availability. Never fetch a kernel/package or
claim success for an unavailable algorithm. BBR is optional: if native support
is unavailable, preserve the current algorithm, repair memory watermarks, and
explicitly report BBR skipped/unavailable. This alone must not block profile
application; strict live-path health still decides connectivity. When BBR is
available, persistence, application or readback errors remain failures.
Preserve nondecreasing RAM-derived memory watermarks, persist the selected
settings and native module loading, and verify runtime values, file contents
and ownership even when runtime already uses BBR. TCP staging cleanup removes
only its two known files and its own empty directory, never recursively.
Changing the default for new TCP connections is `disruptive`: only the existing
detached repair/install owner performs it; existing qdisc, routes, TOS, MTU,
IPv6 and SSH management settings stay unchanged. Verify persistence via the
assembled pipeline and repeat complete router-proxy responses; source tests do
not prove a reboot or fresh VPS provision.
The VPS installer remains one self-contained rendered script. Both renderers
concatenate the declared source parts before placeholder substitution; missing
parts or unresolved placeholders fail before upload, while JSON rendering stays
on its existing path.

Whole pipeline runs under `timeout 90` from the caller (meta-rule 1).

The detached router recovery job repairs the VPS, re-inspects authoritative
identity, then calls the same router apply owner as Apply/settings (node 8.2).
Server success alone is not path success. The accepted profile and action are
fixed for the job, with one shared nonblocking mutation lock. Server repair,
application, and complete-response health have separate results. The existing
170-second job budget includes SSH and checks (remote pipeline at most 90s,
UI wait 180s); reserve 120s for bounded transport/runtime/rollback before
changing files. A slow server repair may therefore refuse a cutover with an
actionable budget error; an identical healthy local config needs no cutover.

**Verify**: `runtime ok` + TLS probe from router (`curl --resolve <SNI>:443:<VPS_IP>`).
Steps are ordered so a config/cert defect cannot mask a runtime failure, but
note the **inter-step hazard**: 6.5/6.6 write files as root over SSH, so a bug
there (bad `chown -R`, bad overwrite) can break the very transport the later
steps and the *next* run depend on. Every step that writes must be bounded to
its own target — see meta-rules 6 and 7.

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
- 8.1 **VPS authoritative** (fresh install, reprovision-adopt, or the
  operator pointed the UI's IP/user/password form at a VPS this profile
  never provisioned — e.g. reusing another profile's already-managed VPS):
  copy the VPS's own identity into the profile — `adopt_remote_into_profile`.
-  UCI-only, `safe`, may run synchronously. This is the default for **every
  successful VPS inspection** in the detached `Check & Configure VPS` job.
  `Save VPS Access` performs no network operation. The UI persists only SSH
  access fields, never submits the
  displayed Xray identity as editable local state, and `refresh_remote_cache`
  immediately adopts every non-empty remote identity field before any render
  or write. A genuinely empty VPS
  (`remote_uuid` empty — never configured, or only the xray binary present)
  has nothing to adopt; only then may the provisioning path generate missing
  material, write it to the VPS, re-inspect, and consume the resulting VPS
  metadata. This prevents stale form values from becoming an accidental
  second source of truth. An already-synced profile remains a no-op.
  Deliberately replacing a VPS's existing identity instead of adopting it is
  out of scope for this path. The legacy `apply_profile` action may provision
  missing VPS material, but its router cutover is now scheduled through the
  same detached, verified job as the UI's explicit `Apply Profile to Router`
  action (8.2); neither path may cut traffic synchronously in a CGI request.
- 8.1a **Saving an existing profile creates a near-duplicate ID** (for
  example `default` becomes `defallt`) and leaves the selected profile
  unchanged: BusyBox `tr` does not implement the combined
  `tr '[:upper:] ' '[:lower:]_'` expression portably and treats characters
  from the class name as input data. Repair: sanitize with explicit ASCII
  ranges in separate translations (`A-Z` to `a-z`, then space to underscore),
  reject everything outside the existing ID alphabet, and exercise the real
  CGI save response against the requested ID. UCI-only, `safe`.
- 8.1b **The new-profile form has no visible save control** even though the
  backend supports `save_profile`: the button was created only by the final
  JavaScript chunk, so a stale/missing chunk left static HTML with `New VPS`
  alone. Repair: render `Save VPS Access` in the profile form HTML and let JS
  only attach its click handler. Verify the rendered DOM in a real browser,
  create a profile, save its SSH coordinates, and confirm the resulting UCI
  profile without contacting the VPS. UI-only plus UCI writes, `safe`.
- 8.1c **A newly created profile saves but its first VPS inspection always
  fails**: the old combined save+inspect action selected password auth without
  a usable password for that inspection. Reusing the active profile's key was
  a temporary workaround but coupled otherwise independent VPS profiles. The
  final repair is 8.1d's explicit two-step workflow: a new profile gets its own
  managed keypair and starts in password-bootstrap mode; saving is local-only,
  and the separate configure job uses the one-shot password to authorize that
  profile's public key. Verify `last_inspect_status=ok` after configuration and
  confirm the password is absent from UCI. Key generation/UCI writes are `safe`.
- 8.1d **The profile form does not expose a usable two-step workflow**: the
  save control is below the entire repair panel, while the VPS repair control
  is hidden and reachable only indirectly from the global path tree. Saving
  also starts an SSH inspection, so the operator cannot distinguish “stored
  access coordinates” from “server verified/configured”. Repair: keep two
  permanently visible controls immediately after the SSH fields: `Save VPS
  Access` performs UCI-only persistence (`safe`), then `Check & Configure VPS`
  starts the existing inspect/provision/repair pipeline as a detached job and
  polls its result (`disruptive`; never run synchronously in the CGI request).
  The password remains one-shot browser input and is removed from the job
  payload as soon as the detached process starts. Verify both buttons in a real
  browser against a new VPS: save must return without SSH, then configure must
  install the router-managed key, adopt or create VPS-owned Xray metadata, and
  apply the selected configuration through node 8.2 and render the per-step report.
- 8.2 **Profile authoritative, router stale**: Apply/settings and Repair must
  apply the accepted selected profile via `apply_profile_to_router_internal`
  in their detached worker (`disruptive`). The former candidate network gate
  could preserve the old VPS indefinitely even when the selected identity and
  local configuration were valid. Probe the actual endpoint before/after the
  supported HTTP action, not just the selected profile label.
  Re-inspect the VPS, require matching live/meta identity and listener port,
  validate required endpoint/SNI/UUID/port, rendered config and certificate
  before writing. Never generate identity to fill an invalid Apply input.
  Check backups and writes. Preserve mode/switch intent, management and failsafe.
  Roll back config/cert/transport only for write or local runtime failure;
  claim `rolled_back` only after checked restoration, otherwise `unknown`.
  External network failure alone leaves a valid selected configuration applied.
  Report `router_apply=applied|unchanged|rolled_back|unknown` separately from
  `path_health=ok|failed|not_checked|unknown`; applied/unhealthy is `ok:false`.
  Verify egress and ChatGPT using complete curl bodies: HTTP200 plus timeout
  is failure. Keep bounded per-request exit/status/bytes/error diagnostics.
  The isolated candidate remains an optional diagnostic, never a write gate.
  Serialize settings, Apply and Repair using the same transaction lock; do not
  nest jobs. Close the transaction FD before daemon creation. Snapshot profile
  and origin at acceptance, reject concurrent edits, report interrupted jobs
  as unknown, and release lock/password/temp resources for retry. An identical
  config/cert/transport with healthy local runtime must not restart services.
  UI shows application versus health and real working state, with versioned
  assets. Selection/save alone do not apply; Apply/settings and Repair do.
  Review regressions: timeout must stop its owned process tree and reap its
  direct child, with transaction FDs closed in commands; never signal a shared
  process group. Adopt the inspected WS path before rendering both sides.
  Skip the bundled binary only when the exact provisioning executable ran
  successfully. Preserve server step reports in Apply/settings results. Clear
  one-shot credentials independently of external health. A retried scheduling
  request with the same request ID rejoins its existing job/result after a lost
  response; a different request receives busy with the active job reference.
  A busy request can briefly own the transaction lock during scheduler-to-worker
  handoff. Both accepted workers retry that lock for at most five seconds within
  the original job deadline and scheduled grace period; request guards remain
  nonblocking. Launch/acquisition failure records a terminal result and removes
  the one-shot request. Verify the actual guard/worker interleave for both jobs,
  exactly-once execution, bounded failure cleanup and unchanged deadline.
  Late writers must own an accepted generation, independently of optional UI
  request IDs. Apply uses the existing job directory store; its current-status
  pointer is published under the transaction lock. Workers and failure writers
  atomically claim that generation's request before executing or terminating it;
  neither may write/delete the next generation's files. Poll the accepted job ID.
  Verify delayed launch/acquire failures after a new acceptance, for both jobs,
  and a late launcher failure after its worker has already claimed execution.
  Verify both public HTTP paths, old-target drift, idempotent retry, incomplete
  HTTP200, invalid inputs, checked rollback, busy and interrupted-job results.
- 8.3a **Desktop redeploy drops authoritative transport fields**: adoption
  omitted `XRAY_DIAL_MODE`/`XRAY_WS_PATH`, and desktop staged metadata erased
  them when the pipeline installed the config. Later inspection defaulted the
  missing mode to direct. Preserve both fields through desktop adoption and
  metadata rendering; decode values as data, never evaluate remote metadata.
  Legacy absent mode means direct; absent path adopts the live WS path when
  available, otherwise /cdn. Reject invalid modes explicitly before writes.
  Quote paths safely in local env, staged metadata and both server/client JSON.
  Raw insertion in the final client renderer can turn a backslash into a JSON
  escape or make a quoted path invalid despite successful server provisioning.
  Use the shared JSON escaping helper and verify the parsed client path too.
  Risk: adoption is
  `safe`; applying the resulting config retains node 6.8's `disruptive` owner.
  Verify stale local direct,/cdn against remote ssh_tunnel,/server-owned through
  the actual desktop caller, full assembled pipeline and router inspection/
  adoption and actual client rendering; assert both parsed paths equal the
  original for plain, backslash, quote and shell-metacharacter inputs. Include
  legacy defaults.
- 8.2a **Initial VPS status returns HTTP200 with truncated JSON**: the UI's
  300-character preview hides the actual boundary. Capture the complete GET
  `xray-vps?action=status` body/headers/curl exit from the router and parse it.
  Observed 363-byte EOF after `router_apply_job:` with CGI exit1: the optional
  `/tmp/xray-vps-repair-apply.status` was absent, and an unguarded `sed`
  assignment aborted the CGI under `set -e`. Missing history is idle, not
  evidence that the active router/VPS configuration failed. Read the status
  snapshot once with checked failure handling; report unreadable, empty,
  malformed or interrupted history as failed/unknown without deleting it.
  Escape status fields and validate embedded step JSON before serialization;
  corrupt steps must produce an explicit diagnostic, not an invented success.
  Review fixtures additionally exposed incomplete `done` snapshots turning green
  in Apply UI, and `[null]` steps crashing the report renderer (separate from the
  original EOF). Terminal outcomes/health must be present and consistent:
  `done` permits applied/unchanged with ok/not_checked and its terminal message,
  as emitted by the worker (not_checked must not become the UI verified fallback).
  Validate step objects and their display fields with native jsonfilter before
  publication. Verify full CGI polling responses through the actual Apply/report
  UI consumers, including unchanged success, switch-off not_checked and retained
  applied-but-unhealthy failures; absent legacy step reports remain optional.
  Verify the complete CGI status and accepted-job polling with absent/dangling,
  empty, completed, active, stale and corrupt fixtures, preserving profile and
  runtime values. Risk: `safe` read/serialization fix; no daemon restart.
- 8.3 **Profile authoritative, VPS stale**: `config` step of the repair
  pipeline installs the staged render (6.6). Guarded: never replaces a valid
  live config with an invalid render.
- 8.4 **Both diverged** (operator edited both sides): do not auto-resolve.
  Surface the diff; operator picks direction. Auto-picking is how working
  identities get silently destroyed. `destructive` if forced.
- 8.5 **Transport mismatch** (router dials one transport, VPS serves another).
  `router_diff`/`remote_diff` compare identity fields (uuid, keys, port) and
  can read **empty/in-sync while the transports disagree** — e.g. the live
  router config had drifted to `raw`/Reality while the VPS served VLESS+WS+TLS
  (2026-07-09). Symptom: SSH + `:443` both healthy, identities match, yet the
  tunnel fails with TLS/handshake errors. Tell: compare
  `outbounds[0].streamSettings.network` + `security` on the router against
  `inbounds[0].streamSettings` on the VPS, not just the identity fields.
  Repair: re-render **both** sides from the one source of truth (`install.sh`
  from the same `.env`); do not hand-patch one side. `disruptive`.

**Verify**: `router_diff` and `remote_diff` empty in status JSON; **and** the
router↔VPS transport (network+security) matches; router error log free of dial
errors to stale endpoints; a proxy probe returns the VPS IP.

---

## R. Template rendering (cross-cutting)

**Symptom**: never seen directly — always surfaces as a downstream failure
(a broken VPS config in node 6/8, a corrupted `/root` in node 5.1b, an
installer crash). Two production outages traced to this class, which is why
it is its own node.

**Failure modes**:
- R.1 **Unsubstituted placeholder reaches a consumer.** A renderer omits a
  key, so `${XRAY_WS_PATH}` (or similar) ships literally. It passes
  `xray -test` because it is a syntactically valid string, then silently
  breaks the tunnel (server expects a path of exactly `${XRAY_WS_PATH}`).
  Cause: the CGI `render_vps_profile_template` `sed` list was missing the
  key. Fix: the renderer substitutes **every** placeholder the template
  contains, defaulting from `profile.env` so a missing profile field still
  yields a real value; the consumer (config step 6.6) **rejects** any
  artifact still containing `${…}`.
- R.2 **Placeholder resolves to empty → downstream path collapse.** An
  unsubstituted or empty path var fed to `dirname` yields `.`; fed to a
  recursive `chown`/`rm` it hits the CWD. This is how node 6.5 corrupted
  `/root`. Fix: substitute + default the path (never empty), and the
  consumer validates absolute before any recursive FS op (meta-rules 6, 7).
- R.3 **Two renderers, one template family, divergent substitution sets.**
  `render_vps_profile_template` (CGI) and `render_template` (installer,
  Python) must cover the same variables for the same templates, or the two
  install paths produce different artifacts. Also: a literal `${VAR}` in a
  **comment** of a templated script is still substituted by the naive
  installer renderer and crashes on an unknown key (`KeyError: PLACEHOLDER`,
  2026-07-09). Do not write `${...}` tokens in comments of rendered files.
- R.4 **Empty TLS serverName → cert validated against the IP.** A router/VPS
  config rendered with an empty `serverName` makes xray fall back to the
  dial address (the IP) as the TLS reference name; the cert (CN=a hostname,
  no IP SAN) then fails validation and every dial dies. Passes `xray -test`.
  Guard at the producer: refuse to render/apply when serverName would be
  empty (node 8.2 guard). There are **three** router-config generators —
  the `codex-xray.json.template` (install path), `render_router_config`
  (xray-vps.cgi), and `build_config_file` (xray-admin.cgi) — and two of the
  three had drifted to `raw`/`reality` while the template + VPS were
  `ws`/`tls`; applying either broke the tunnel (node 8.5). All three now
  emit WS+TLS and `test_xray_runtime_contract.sh` enforces transport parity
  across all three. Rule: any new router-config generator must match the
  template's transport, and the contract test must include it.

**Probes**: `grep -n '\${[A-Z_][A-Z0-9_]*}' <rendered-output>` must return
nothing; diff the substitution key sets of the two renderers against the
union of placeholders in the shared templates.

**Repair**: fix at the renderer; add the missing key to both renderers; add
the rejecting guard at the consumer. Never "fix" by editing the rendered
artifact on the device. `safe` (source edits + redeploy).

**Verify**: rendered config on the VPS has no `${…}`; both install paths
(installer and UI repair) produce byte-identical configs for the same input.

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
  implemented as the `apply_router` job (`XRAY_VPS_JOB=apply_router`); no
  watchdog if the job dies mid-cutover (router recovers via failsafe, but the
  UI shows stale "running").
- **G4**: node 7 client-path probes are manual (AGENTS.md matrix); no
  automated LAN-client harness.
- **G5**: VPS-side `nftables`-managed hosts (no ufw) — firewall step (6.7)
  only knows ufw; a no-ufw host reports `ok` unconditionally even if 443 is
  blocked. No detection of the actual listener reachability from outside.
- **G6**: key-algorithm rejection (5.1c) is diagnose-only; the managed key is
  RSA. No automated switch to ed25519, and no probe that checks the server's
  `PubkeyAcceptedAlgorithms` before blaming ownership/credentials.
- **G7**: **profile parity. CLOSED.** The `asus-tuf-ax4200-openwrt`
  `xray-vps.cgi`, `xray.html`, and `xray-admin.cgi` are now byte-identical
  to `gl-mt3000-glinet` (the CGIs and UI are profile-independent — no
  hardcoded paths, ports, or names differ). asus now carries `diagnose_repair`,
  the render/ownership/transport fixes, and the progress UI. Re-diff on any
  future gl change to keep them in sync (a `diff -q` check would be a cheap
  CI guard — see G12).
- **G8**: transport mismatch (8.5) detector — **CLOSED.** The remote
  inspection now reads the VPS inbound `streamSettings.network`+`security`
  (`REMOTE_TRANSPORT_NET/SEC`), `router_current_json` exposes the router's
  outbound transport, and the UI's Live State compares them and shows a red
  "transport mismatch: router X/Y vs VPS A/B" the moment they diverge —
  before the operator notices no internet. Identity-diff can read "in sync"
  while the transport silently disagrees, so this is a separate, louder
  signal.
- **G9**: no test asserts the two renderers (`render_vps_profile_template`
  CGI, `render_template` installer) cover the same placeholder set for the
  shared templates, nor that a rendered artifact is placeholder-free. R.1/R.3
  regressions would pass CI today. A contract test should render both and
  `grep` for residual `${…}` and diff the key sets. **(closed by
  `test_vps_render_placeholder_contract.sh`.)**
- **G10**: cert served ≠ cert on disk. The VPS can regenerate
  `/usr/local/etc/xray/certs/server.crt` while a running xray keeps serving
  the cert it loaded at start (observed 2026-07-10: disk 65:9D…, served
  93:FE…). Recovery scripts re-pin from what the VPS *serves* (openssl
  s_client), so they are immune to this; the repair runtime step (6.8)
  restarts xray which reconciles served=disk. Remaining sharp edge: a bare
  cert regen on the VPS without an xray restart there leaves the VPS serving
  a stale cert — an operator VPS-side concern, not the router's.
- **G11**: automatic router cert re-sync — **CLOSED (self-healing).** Cert-pin
  drift presents as a severe smoke failure (path up, egress dead), which the
  `xray-switch-watchdog` already detects. `vpn-xray-repin-cert` (a bounded,
  best-effort, idempotent helper; see `docs/BOOT-PATH-DESIGN.md`) is invoked
  by the watchdog in its severe-failure branch, *before* the restart it was
  already going to do, so the restart reloads the corrected cert. Chosen over
  a periodic cron because the watchdog already runs and only acts when the
  path is actually broken. **The boot path (`codex-xray.init`) is NOT
  touched.** Uncovered and fixed a pre-existing bug along the way: the
  watchdog daemon had never actually run (literal single quotes truncated its
  procd `sh -c` command); it runs now. Verified end-to-end: a deliberately
  drifted cert self-heals in ~80 s with no manual step; healthy path shows no
  churn.
- **G12**: profile-parity is maintained by hand. `xray-vps.cgi`,
  `xray-admin.cgi`, and `xray.html` are identical across the two router
  profiles but nothing enforces it — a future edit to one profile silently
  diverges the other (which is how G7 opened). `test_profile_parity.sh`
  now diffs the shared, profile-independent files; keep new such files in
  its list.
- **G13 — CLOSED**: `apply_everything_action`/`apply_profile_to_router_action`
  (CGI actions `apply_profile` and `apply_router`, `xray-vps-setup.sh` /
  `xray-vps-actions.sh`) previously called
  `apply_profile_to_router_internal` — a hard cutover of the transparent
  path — **synchronously inside the CGI request**, the exact anti-pattern
  meta-rule 2 forbids and that hung the router on 2026-07-09 (node 8.2).
  Before the repair, a
  `schedule_router_apply_job`/`run_router_apply_job` pair already existed
  in `xray-vps-setup.sh` (status file `ROUTER_APPLY_STATUS_FILE`, an
  `XRAY_VPS_JOB=apply_router` re-exec mode already wired into
  `xray-vps.cgi`) but is dead code — nothing calls
  `schedule_router_apply_job`, and `status_json` never exposes
  `ROUTER_APPLY_STATUS_FILE` for the UI to poll. Both actions were migrated
  before UI wiring: they schedule
  `schedule_router_apply_job`, `run_router_apply_job` owns the guarded
  backup/apply/verify/rollback sequence, and `status_json` exposes
  `ROUTER_APPLY_STATUS_FILE`. The detached launcher closes CGI stdio and the
  scheduler flock descriptor, so neither the HTTP response nor single-flight
  lock leaks into the job/runtime. The UI now polls that state from the explicit
  `Apply Profile to Router` button. Verified on real hardware by cutting to a
  separately configured VPS and checking its egress IP plus ChatGPT from the
  LAN-client path. `disruptive`.
