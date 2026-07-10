#!/bin/sh

set -eu

# Contract for the unified diagnostic tree (docs/UNIFIED-DIAGNOSTIC-UI-DESIGN.md):
# the node manifest is the single source of truth, the admin CGI serves it via
# action=tree, and the UI renders it. Assert the wiring so a node can never be
# half-added.

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
MANIFEST="$ROOT/routers/common/files/diag/nodes.manifest"
TREE_LIB="$ROOT/routers/common/files/xray-admin-tree.sh"
TREE_JS="$ROOT/routers/common/files/xray-tree.js"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

[ -f "$MANIFEST" ] || fail "node manifest missing"

# Every non-comment, non-blank line has exactly 10 pipe-separated fields
# (id|parent|layer|title|side|risk|repair|auto|ui_slot|gap) and a non-empty id.
awk -F'|' '
	/^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
	{ if (NF != 10) { printf "BADFIELDS line %d: %d fields\n", NR, NF; bad=1 }
	  if ($1 == "") { printf "EMPTY id line %d\n", NR; bad=1 }
	  seen[$3]=1 }
	END { if (bad) exit 1 }
' "$MANIFEST" || fail "manifest has a malformed node row (need 10 | fields)"

# Every top-level layer 1..9 has at least one node.
for layer in 1 2 3 4 5 6 7 8 9; do
	awk -F'|' -v L="$layer" '$3==L{f=1} END{exit f?0:1}' "$MANIFEST" \
		|| fail "manifest has no node for layer $layer"
done

# The runner exposes both functions and derives the transparent-proxy node
# (4.1) — the one whose failure caused the 2026-07-10 blackout — so it is
# always visible in the tree.
grep -q '^tree_json()' "$TREE_LIB" || fail "xray-admin-tree.sh must define tree_json()"
grep -q '^tree_node_status()' "$TREE_LIB" || fail "xray-admin-tree.sh must define tree_node_status()"
grep -q 'CODEX_TRANSPROXY\|nat_rule_present' "$TREE_LIB" \
	|| fail "tree runner must check the transparent-proxy nat rule for node 4.1"
grep -Eq '4\.1\|' "$MANIFEST" || fail "manifest must carry the transparent-proxy node 4.1"

# The runner exposes the repair surface: single-node repair and the tree walk,
# and both derive success from the honest listening signal, not a bare rc.
grep -q '^node_repair_run()' "$TREE_LIB" || fail "tree lib must define node_repair_run()"
grep -q '^tree_repair_json()' "$TREE_LIB" || fail "tree lib must define tree_repair_json() (the bottom-up walk)"
grep -q 'listen_present 12345' "$TREE_LIB" \
	|| fail "tree lib must verify redsocks LISTENING on :12345 (not pgrep -x, which never matches /usr/sbin/redsocks)"
grep -q 'pgrep -x redsocks' "$TREE_LIB" \
	&& fail "tree lib must not use pgrep -x redsocks (false DOWN on a healthy /usr/sbin/redsocks)"

# Every profile's admin CGI sources the tree lib and dispatches the tree +
# repair actions.
for prof in gl-mt3000-glinet asus-tuf-ax4200-openwrt; do
	cgi="$ROOT/routers/$prof/files/xray-admin.cgi"
	grep -q 'xray-admin-tree.sh' "$cgi" || fail "$prof xray-admin.cgi must source the tree lib"
	grep -q '^	tree)' "$cgi" || fail "$prof xray-admin.cgi must dispatch action=tree"
	grep -q '^	node_repair)' "$cgi" || fail "$prof xray-admin.cgi must dispatch action=node_repair"
	grep -q '^	tree_repair)' "$cgi" || fail "$prof xray-admin.cgi must dispatch action=tree_repair"
done
# The install completion gate must use the same honest redsocks signal.
grep -q 'pgrep -x redsocks' "$ROOT/routers/gl-mt3000-glinet/install-router-lib.sh" \
	&& fail "install-router-lib.sh must not use pgrep -x redsocks in the completion gate"

# UI renderer exists and reads the tree endpoint.
[ -f "$TREE_JS" ] || fail "xray-tree.js renderer missing"
grep -q 'action=tree' "$TREE_JS" || fail "xray-tree.js must fetch action=tree"
grep -q 'pathHealthTree' "$TREE_JS" || fail "xray-tree.js must render into #pathHealthTree"
grep -q 'id="pathHealthTree"' "$ROOT/routers/gl-mt3000-glinet/files/xray.html" \
	|| fail "xray.html must contain the #pathHealthTree mount"

# The DIAGNOSTIC-TREE.md node summary is generated from the manifest and must
# stay in sync (single source of truth — the doc can no longer drift).
if command -v python3 >/dev/null 2>&1; then
	python3 "$ROOT/common/lib/diag/gen-tree-doc.py" --check \
		|| fail "docs/DIAGNOSTIC-TREE.md node table is out of sync with the manifest — run: python3 common/lib/diag/gen-tree-doc.py"
fi

printf 'ok\n'
