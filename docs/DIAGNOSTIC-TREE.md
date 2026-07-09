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
5. A repair never regresses a working layer to fix a broken one
   (e.g. never restarts the router dataplane to fix a VPS-side issue).
6. A recursive filesystem op (`chown -R`, `rm -rf`, `chmod -R`) must first
   assert its target is a non-empty absolute path under the expected root;
   otherwise skip and report, never act on the fallback (`.` / `/`).
7. A rendered artifact that still contains a `${PLACEHOLDER}` is a defect,
   not input to act on. Every renderer substitutes every placeholder; every
   consumer of a render rejects a leftover placeholder (node R).

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
  the same destination get `Connection refused`/`Operation timed out` from the
  repeater while a single connect succeeds (observed on apcli0, 2026-07-09).
  Environmental constraint, not a fault. Mitigate in code: bound the retry
  storm — `ConnectTimeout=6`, `ConnectionAttempts=2`, a wrapper retry of 2 with
  a 2 s gap (see `ssh_works`). This caps worst-case latency so a rate-limited
  uplink cannot push a request past the UI timeout, while still absorbing a
  single burst rejection. Note: SSH `ControlMaster` multiplexing was tried and
  **reverted** — it left stale control sockets under `/tmp` on the router that
  accumulated and were worse than the burst itself; do not reintroduce it as a
  mitigation. Do **not** diagnose "VPS down" from a burst-context refusal —
  verify with a single isolated probe after a pause first (node 5.2).

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
  `Operation timed out` as auth failure.
- 5.3 **:443 closed but SSH works** → VPS xray down, node 6.
- 5.4 **Both closed** → VPS is down/rebuilding or its provider firewall
  changed; nothing the router can repair. Surface reachability + last-known
  state to the operator. `safe`

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
| 6.1 | `binary` | `$XRAY_BIN` runnable | install from bundled zip; network installer as last resort | air-gap first |
| 6.2 | `service_unit` | unit file exists | write minimal unit; `daemon-reload` | drop-ins (User=xray) still apply |
| 6.3 | `directories` | config+log dirs exist, owned by service user | `install -d` + `chown` | |
| 6.4 | `permissions` | every log file owned by service user; user can actually append | `chown`/`chmod 640`; probe with `runuser` | uid-drift after reprovision (`nobody:nogroup` log files) makes xray exit status 23 under `RestartPreventExitStatus=23` so it stays down. **One** of two causes of the 2026-07-09 outage — the other, and the recurring one, was 6.5 below. |
| 6.5 | `certs` | cert+key present **at a validated absolute path** | generate self-signed for `$TLS_CN` | **THE recurring corruptor of the 2026-07-09 outage.** `chown -R "$u:$g" "$(dirname "$TLS_CERT_PATH")"` ran with `TLS_CERT_PATH` empty (render never substituted it, node R) → `dirname` = `.` → recursive chown of the SSH CWD `/root` → key auth broke every run (5.1b). Guard: refuse any non-absolute cert path, report `skipped`, touch nothing. Also `skipped` when CN unknown — never generate a `CN=` empty cert. |
| 6.6 | `config` | staged config has **no unsubstituted `${…}`** AND passes `xray -test`; else existing config passes | install staged (backup old) | Two guards: (a) reject a staged render still holding a `${PLACEHOLDER}` — it passes `xray -test` (a placeholder is a valid string) but silently breaks the tunnel, e.g. WS path = literal `${XRAY_WS_PATH}` (node R); (b) `skipped` when staged invalid but live config valid — never overwrite a working config with a broken render. |
| 6.7 | `firewall` | ufw allows `$XRAY_PORT` | `ufw allow` | inactive ufw = `ok`; **no-ufw host = `ok` unconditionally, which is a blind spot** (Gap G5) — an nftables-only host with 443 closed is reported healthy |
| 6.8 | `runtime` | unit active AND port bound ≤15s | `reset-failed` + `enable` + `restart` | `reset-failed` is mandatory: a unit failed with `RestartPreventExitStatus` silently ignores plain restart |

Whole pipeline runs under `timeout 90` from the caller (meta-rule 1).

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
- **G7**: **profile parity.** All repair code — `diagnose_repair`, the
  render fixes, the ownership self-heal, the progress UI — lives in the
  `gl-mt3000-glinet` profile only. The `asus-tuf-ax4200-openwrt`
  `xray-vps.cgi`/`xray.html` never received the `diagnose_repair` action and
  still carry the pre-refactor buttons and the render bugs (empty TLS path,
  literal WS path). An asus repair today would re-corrupt `/root`. Must port
  nodes 5.1b, 6.5, 6.6, R and the UI safety before the asus profile is used
  for repair.
- **G8**: transport mismatch (8.5) has no automated detector — nothing compares
  router `streamSettings.network`+`security` against the VPS inbound. Drift is
  found only by a failed proxy probe. A cheap status-time check would catch it.
- **G9**: no test asserts the two renderers (`render_vps_profile_template`
  CGI, `render_template` installer) cover the same placeholder set for the
  shared templates, nor that a rendered artifact is placeholder-free. R.1/R.3
  regressions would pass CI today. A contract test should render both and
  `grep` for residual `${…}` and diff the key sets.
