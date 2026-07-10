# Unified Diagnostic System — one tree, one manifest, one UI

**Status:** design (design-first; nothing implemented from this doc yet).
**Builds on, does not replace:** [`DIAGNOSTIC-TREE.md`](DIAGNOSTIC-TREE.md) (the
layer model + node prose) and [`BOOT-PATH-DESIGN.md`](BOOT-PATH-DESIGN.md) (the
unattended self-heal layer). This doc is the reconception that ties those two
plus the live repair pipeline and the web UI into **one system**.

---

## 1. The reconception (why this exists)

Today the same decision tree is expressed **three times, in three shapes**, and
they drift:

| Where | Shape | Owns |
| --- | --- | --- |
| `DIAGNOSTIC-TREE.md` | prose (nodes 0–9, R, gaps G1–G12) | the *model* |
| repair pipeline (`install-vps.remote.sh` steps → `REPAIR_REPORT`) | shell `report <name> <status> <msg>` | *execution* for the VPS half (node 6) |
| web UI (`Live State` cells, `renderRepairReport`, smoke) | scattered DOM | *display* of a few nodes |
| boot-path watchdog / `vpn-xray-repin-cert` | init scripts | *unattended repair* for nodes 4/5 |

The VPS half already proves the target shape end to end — **node → probe →
status → UI row → repair action**. The rest of the tree (workstation, uplink,
router runtime, transport, coherence) has checks scattered across the admin
CGI, the watchdog, and prose, and the UI shows a hand-built subset.

**The reconception:** there is exactly **one node registry (the manifest)**.
Every layer/sub-check in `DIAGNOSTIC-TREE.md` becomes one manifest record. That
single source of truth drives **all four** consumers:

1. the **check-runner** that produces each node's live status,
2. the **repair flow** (diagnose top-down, repair bottom-up),
3. the **UI**, which renders the manifest as a live decision tree — every node
   is a row with a status, a detail, and (where applicable) a repair button,
4. the **doc** (`DIAGNOSTIC-TREE.md` becomes a *rendered view* of the manifest,
   so it can no longer drift).

Boot-path self-heal is not a separate thing: it is the **automated** repair
action on the nodes that can self-heal (4.x, 5.x). The manifest records which
nodes self-heal and the UI surfaces their last auto-action.

**Non-goal / hard rule:** this reduces duplication, never functionality. No
check, repair, or risk-gate is dropped in the move to data. Destructive repairs
stay behind an explicit confirm (risk classes carry over verbatim).

---

## 2. Node model (the manifest record)

One record per node. Sub-checks (e.g. `5.1a/b/c`) are child nodes with a
`parent`. Fields:

```
id            "5.1b"                 stable, matches DIAGNOSTIC-TREE numbering
parent        "5"                    tree edge (null for a layer root)
layer         5                      0..9 ; R is layer "R"
title         "TLS cert pin drift"   short, shown in the UI row
symptom       "path up, egress dead" operator-visible symptom (one line)
side          router|vps|workstation|xstation  where the probe runs
probe         <ref>                  how to check (see §4) — a named check fn
verify        <ref>                  status derivation -> ok|degraded|failed|na|unknown
risk          safe|disruptive|destructive       of the repair, not the probe
repair        <ref|null>             named repair action; null = diagnose-only
auto          none|watchdog|repin|...            unattended repair, if any (boot-path)
ui_slot       "path"|"vps"|"rules"|"config"      which UI group the row lives in
gap           "G6"|null              open gap this node still carries, if any
```

`status` is **not** stored — it is derived live by `verify` from the latest
`probe` output, so the tree is never stale. `unknown` = not yet probed;
`na` = not applicable on this platform (e.g. no hardware switch on asus).

The manifest ships in **two rendered forms from one source** (so shell and JS
never hand-maintain two copies):

- `routers/common/files/diag/nodes.manifest` — shell-sourceable (`id|parent|
  layer|side|title|risk|repair|auto|ui_slot|gap`), consumed by the check-runner
  and repair flow.
- served to the UI as JSON by the node-status endpoint (§4), which reads the
  same manifest — the browser never gets a second copy to drift.

A tiny generator emits `DIAGNOSTIC-TREE.md`'s node table from the manifest so
the prose doc becomes a **view**, not a parallel source (closes the class of
drift that `DIAGNOSTIC-TREE.md` vs code has today).

---

## 3. Node inventory (reconceived from the existing tree)

The existing layers map 1:1; this is the reconception, annotated with the UI
slot and the current signal that already exists (so migration reuses, not
rebuilds). `auto` = boot-path self-heal already covers it.

| id | title | side | probe today | ui_slot | repair | auto |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | Workstation → router | xstation | installer SSH/ping | path | local route fix | — |
| 2 | Router platform files | router | file presence vs repo | path | `install.sh` (disruptive) | — |
| 3 | Router uplink | router | `preferred_uplink_iface()` carrier+gw | path | uplink reselect | hotplug (G2 open) |
| 3.4 | Repeater rate-limit | router | burst vs isolated probe (G1 open) | path | back off / manual | — |
| 4 | Router Xray runtime | router | admin `status` (xray/redsocks/nat) | path | restart runtime | watchdog |
| 4.x | redsocks / transproxy down | router | `redsocks_running`,`transproxy_rule` | path | `codex-transproxy restart` | watchdog |
| 5 | Router → VPS transport | router | admin `smoke` https/egress | path | re-pin / re-render | watchdog+repin |
| 5.1b | TLS cert pin drift | router | served-vs-pinned cert | path | `vpn-xray-repin-cert` | repin |
| 5.1c | key-algorithm reject | router | ssh `PubkeyAcceptedAlgorithms` (G6) | config | switch to ed25519 | — |
| 6 | VPS Xray runtime | vps | repair steps binary…runtime | vps | repair pipeline | — |
| 6.5 | certs / perms | vps | `step_certs`,`step_permissions` | vps | repair step | — |
| 6.7 | VPS firewall | vps | `step_firewall` (G5 reachability) | vps | repair step | — |
| 7 | End-to-end data plane | router | admin `smoke` egress==VPS | path | (walks 4–6) | — |
| 8 | Config coherence | router+vps | drift / `profile_diff_fields` | config | apply profile (guarded) | — |
| 8.5 | transport mismatch | router+vps | `REMOTE_TRANSPORT_*` vs router | config | re-render WS+TLS | — |
| R | Template rendering | build | placeholder-free render (tests) | — | fix renderer | — |
| 9 | Install pipeline | xstation | 10-step progress | path banner | re-run install | — |

Gaps become **node attributes** (`gap=G6`), not a separate register — an open
gap is "this node's probe or repair is manual/missing". The UI can badge a node
whose `gap` is set ("diagnose-only — no auto-repair yet"), which makes the
backlog visible instead of buried in a doc.

---

## 4. Execution model

### 4.1 Check-runner (status)

A single router-side endpoint — `xray-admin?action=tree` — reads the manifest
and returns one JSON array of `{id, status, detail, checked_at}`. It does **not**
add new probes; it *aggregates the signals that already exist*:

- nodes 4/4.x/5/7 ← the admin `status` + `smoke` outputs (already computed),
- node 8/8.5 ← `router_current_json` transport + drift (already computed),
- node 6.x ← the last `REPAIR_REPORT` (cached) or "not yet run",
- nodes 1/2/3/9 ← router-local file/route/uplink probes + install-status file.

So phase 1 is mostly *routing existing signals through the manifest*, not
writing new checks. Meta-rules from `DIAGNOSTIC-TREE.md` carry over: per-probe
timeout, single-flight (`flock`), never block the UI poll.

### 4.2 Repair flow

`diagnose_repair` becomes **manifest-walking**: diagnose top-down (report every
node's status), then repair **bottom-up** — fix the deepest `failed` node whose
`risk<=allowed`, re-probe upward (upper layers self-heal), stop when node 7 is
`ok`. Each node's repair is its existing action (VPS steps unchanged; router
nodes call the transproxy/repin/apply actions). Destructive repairs are gated
behind an explicit UI confirm (risk carries from the manifest).

### 4.3 Boot-path (unattended) integration

`auto` nodes are repaired without the operator by the watchdog / `repin`
(BOOT-PATH-DESIGN §3). The tree endpoint reports their **last auto-action**
(from the watchdog state files) so the UI can show "self-healed 5.1b 40s ago"
instead of a bare green. No change to the boot path itself — it stays the
untouched, high-blast-radius layer; this only *reads* its state files.

---

## 5. UI correlation — the live decision tree

Replace the hand-built "Live State" cells + separate repair report with **one
"Path Health" tree view** that renders the manifest in layer order. This is the
core of "each element reflects a node with a check, a status, and a repair".

```
Path Health                                    [ Diagnose & Repair ▸ ]
─────────────────────────────────────────────────────────────────────
● 1  Workstation → router            ok        ssh 12ms
● 2  Router platform                 ok        files match repo
◐ 3  Router uplink                   degraded   wwan up, gateway flaky   [reselect]
● 4  Router Xray runtime             ok         xray+redsocks+nat up      ↻ self-heal
◐ 5  Router → VPS transport          degraded   cert drift               ↻ repin 40s ago
● 6  VPS Xray runtime                ok         6/6 steps                 [re-run]
✗ 7  End-to-end                      failed     egress ≠ VPS             [repair ▸]
● 8  Config coherence                ok         profile=router=VPS
⚠ R  Template rendering              n/a        (build-time; CI only)
```

Rules:

- **One row per node**, indented by `parent`, in tree order. Status glyph:
  `● ok / ◐ degraded / ✗ failed / ○ unknown / ⚠ n-a`. Colour = status.
- The row's **detail** is the node's live `detail` string; a `↻` marker with a
  timestamp when boot-path auto-repaired it; a `gap` badge when diagnose-only.
- **Repair affordance per node**: a row that is `failed`/`degraded` and has a
  `repair` shows an inline button; `destructive` repairs open a confirm. The
  top-level **Diagnose & Repair** walks the whole tree (§4.2) and animates each
  row's status as it goes — the existing `repairProgress`/`renderRepairReport`
  becomes this animation over the tree instead of a flat list.
- The current cards don't disappear — they become **detail drawers**: expanding
  node 8 shows the existing Detailed-Compare tables; expanding node 6 shows the
  VPS step report; expanding node 5 shows the live snapshot. The data-driven
  `STATUS_CELLS` work (just landed) is the seed of this renderer.
- The install banner (node 9) folds in as the tree's top row while an install
  runs; its honest completion gate (transparent-path check, just landed) is
  node 7's status — the banner and the tree agree by construction.

---

## 6. File structure (this is what the 500-line rule was pointing at)

"Refactor by functional purpose" = split along the **node layers**, so each
file owns one part of the tree and is independently testable:

```
routers/common/files/diag/
  nodes.manifest             the single source of truth (data)
  tree-runner.sh             read manifest, aggregate signals -> node status
  repair-walk.sh             diagnose top-down / repair bottom-up
  probes/router.sh           router-side probes (nodes 1-5,7)
  probes/vps.sh              vps-side probes/repairs (node 6) — wraps existing steps
common/lib/diag/gen-tree-doc.py   manifest -> DIAGNOSTIC-TREE.md node table
routers/common/files/xray-tree.js (or xray-app-*)  the Path-Health renderer
```

Each file stays well under 500 lines because it owns one layer/concern, not
because markup was compressed. The existing split libs (`xray-vps-*`,
`router-rules-*`, `xray-admin-*`) are the mechanical precedent; this adds the
*semantic* axis (by tree layer) on top.

---

## 7. Migration plan (phased, each phase shippable + verified)

1. **Manifest + doc-gen.** Write `nodes.manifest` from the existing tree prose;
   generator emits the `DIAGNOSTIC-TREE.md` node table. Contract test: every
   layer 0–9+R has ≥1 node; every node has the required fields; the generated
   table matches the committed doc. *No runtime change.*
2. **Tree status endpoint.** `xray-admin?action=tree` aggregates existing
   signals into per-node status. Playwright + admin-smoke verify it matches
   what the cells show today. *No new probes, no repair change.*
3. **Path-Health UI.** Render the manifest live (read-only tree view) beside
   the current cards; Playwright-verify identical data, then retire the
   duplicated cells into detail drawers.
4. **Repair-walk.** Move `diagnose_repair` onto the manifest; add the router-
   side node repairs (transproxy/repin/apply) into the same report shape as the
   VPS steps. Risk-gated. Verified against a deliberately-broken node.
5. **Close gaps as node attributes.** G1/G5/G6 etc. become real probes/repairs
   on their nodes, or stay badged diagnose-only — visibly, in the UI.

Each phase leaves the system working; nothing is a big-bang cutover.

---

## 8. Invariants (what must stay true)

- **No functionality removed** — every current check/repair maps to a node;
  the move is prose+scattered-code → data+one-renderer.
- **Risk classes are law** — `destructive` never auto-fires; the boot path is
  read, never extended, from here (BOOT-PATH-DESIGN owns changes to it).
- **UI == reality** — a node is green only when its probe says so; "10/10" and
  a green tree can never sit over a dead transparent path (node 7 gates it).
- **One source of truth** — manifest drives runner, repair, UI, and doc; a new
  node is added in exactly one place.
- **Files by layer, < 500 lines** — the size rule is satisfied by *functional*
  decomposition along the tree, not by compressing content.
