#!/bin/sh
# xray-admin-tree.sh — unified diagnostic tree status for the xray-admin CGI.
# Reads the node manifest (docs/UNIFIED-DIAGNOSTIC-UI-DESIGN.md) and derives
# each node's live status from the SAME runtime signals status_json already
# uses — service pids, the nat rule, and the cached smoke result — so a tree
# poll runs no new probes (no curl). Deployed to /usr/share/vpn-xray/; sourced
# by /www/cgi-bin/xray-admin after lib-common.sh. Defines functions only.

DIAG_MANIFEST="${VX_DIAG_MANIFEST:-/usr/share/vpn-xray/diag/nodes.manifest}"

# tree_node_status <id> -> "status<TAB>detail"
# status is one of: ok | degraded | failed | unknown | na
tree_node_status() {
	local id="$1" sw hs eg st istate isf
	sw="$(current_switch_state)"
	case "$id" in
		1)
			printf 'ok\tadmin panel reachable from this workstation' ;;
		2)
			if [ -x /usr/bin/router-rules ] && [ -x /www/cgi-bin/xray-vps ] && [ -f /etc/init.d/codex-xray ]; then
				printf 'ok\tcore files present'
			else
				printf 'failed\tplatform files missing or stale — re-run install'
			fi ;;
		3)
			if ip route show default 2>/dev/null | grep -q .; then
				printf 'ok\tdefault route present'
			else
				printf 'failed\tno default route — router uplink is down'
			fi ;;
		4)
			[ "$sw" = 'on' ] || { printf 'na\thardware switch is off'; return 0; }
			if service_running "$XRAY_PID" && listen_present 1083; then
				printf 'ok\txray-core running, :1083 listening'
			else
				printf 'failed\txray-core is not running'
			fi ;;
		4.1)
			[ "$sw" = 'on' ] || { printf 'na\thardware switch is off'; return 0; }
			# Honest signal: redsocks actually LISTENING on :12345 (not just a
			# live pid) plus the nat rule — a process-alive-but-not-serving
			# redsocks must not read green (same lesson as the install banner).
			if listen_present 12345 && nat_rule_present; then
				printf 'ok\tredsocks listening on :12345, CODEX_TRANSPROXY active'
			else
				printf 'failed\ttransparent proxy down — LAN clients would be blocked'
			fi ;;
		5)
			[ "$sw" = 'on' ] || { printf 'na\thardware switch is off'; return 0; }
			st="$(status_file_value last_smoke_status)"
			hs="$(status_file_value last_smoke_https_ok)"
			if [ -z "$st" ]; then
				printf 'unknown\tno smoke check yet'
			elif [ "$hs" = '1' ]; then
				printf 'ok\tHTTPS reaches the internet through the tunnel'
			else
				printf 'failed\ttransport to VPS is failing'
			fi ;;
		6)
			st="$(status_file_value last_smoke_status)"
			eg="$(status_file_value last_smoke_egress_ok)"
			if [ -z "$st" ]; then
				printf 'unknown\tsee VPS panel / Diagnose & Repair'
			elif [ "$eg" = '1' ]; then
				printf 'ok\tVPS is serving (egress reached through it)'
			else
				printf 'degraded\tVPS may be unhealthy — run Diagnose & Repair'
			fi ;;
		7)
			[ "$sw" = 'on' ] || { printf 'na\thardware switch is off'; return 0; }
			st="$(status_file_value last_smoke_status)"
			if [ -z "$st" ]; then
				printf 'unknown\tno smoke check yet'
			elif [ "$st" = 'ok' ]; then
				printf 'ok\tclient path is healthy end to end'
			else
				printf 'failed\tend-to-end client path is broken'
			fi ;;
		8|8.5)
			printf 'unknown\tsee Config compare / VPS panel' ;;
		R)
			printf 'na\tbuild-time check (enforced in CI)' ;;
		9)
			isf='/tmp/vpn-xray-install-status.json'
			if [ -s "$isf" ]; then
				istate="$(sed -n 's/.*"state":"\([a-z]*\)".*/\1/p' "$isf" | sed -n '1p')"
				case "$istate" in
					running) printf 'degraded\tinstall in progress' ;;
					failed)  printf 'failed\tlast install failed' ;;
					complete) printf 'ok\tlast install completed' ;;
					*) printf 'unknown\tidle' ;;
				esac
			else
				printf 'unknown\tno install run recorded'
			fi ;;
		*)
			printf 'unknown\t' ;;
	esac
}

# node_repair_run <id> — DO the router-side repair for one node. Returns
# rc 0 = success (verified), 1 = ran but did not converge, 2 = no router repair.
# Action only, no output — shared by single-node repair and the tree walk.
# Only known-safe (recoverable) router-side repairs; VPS runtime (node 6) and
# config apply (node 8) stay in the guarded diagnose_repair.
node_repair_run() {
	case "$1" in
		4)
			restart_runtime_from_saved_config >/dev/null 2>&1 ;;
		4.1)
			# The 2026-07-10 blackout recovery: bring the transparent proxy
			# back and re-apply the switch state. Success = redsocks really
			# LISTENING + nat rule (not just "the command returned 0").
			/etc/init.d/codex-transproxy restart >/dev/null 2>&1 || true
			sleep 1
			/etc/gl-switch.d/xray.sh on >/dev/null 2>&1 || true
			sleep 1
			listen_present 12345 && nat_rule_present ;;
		5)
			[ -x /usr/bin/vpn-xray-repin-cert ] && /usr/bin/vpn-xray-repin-cert >/dev/null 2>&1
			restart_runtime_from_saved_config >/dev/null 2>&1 ;;
		*)
			return 2 ;;
	esac
}

# node_repair_msg <id> <rc> — human message for a node_repair_run result.
node_repair_msg() {
	case "$1:$2" in
		4:0)   printf 'Xray runtime restarted and re-synced to the hardware switch.' ;;
		4.1:0) printf 'Transparent proxy restarted; redsocks is listening on :12345 and CODEX_TRANSPROXY is active.' ;;
		5:0)   printf 'Re-pinned the VPS cert (if drifted) and restarted the runtime.' ;;
		*:2)   printf 'Node %s has no one-click router-side repair. Use Diagnose & Repair (VPS/config) above.' "$1" ;;
		*)     printf 'Repair of node %s did not converge; see logs.' "$1" ;;
	esac
}

# node_repair_json <id> — run one node's repair and return
# {ok, node, message, tree:{...}} so the UI re-renders from the post-repair state.
node_repair_json() {
	local id="$1" rc
	node_repair_run "$id"
	rc=$?
	printf '{'
	printf '"ok":'; json_bool "$([ "$rc" = '0' ] && printf 1 || printf 0)"; printf ','
	printf '"node":"%s",' "$(json_escape "$id")"
	printf '"message":"%s",' "$(json_escape "$(node_repair_msg "$id" "$rc")")"
	printf '"tree":'
	tree_json
	printf '}'
}

# tree_repair_json — the tree-walking Diagnose & Repair. Repair bottom-up: fix
# the lowest-layer broken router-repairable node, re-probe, repeat until the
# end-to-end node (7) is ok or nothing router-side is left to fix. Whatever it
# cannot fix (VPS runtime / config) is reported so the operator runs the guarded
# Diagnose & Repair. Bounded to 5 rounds so a non-converging node cannot churn.
tree_repair_json() {
	local walked='' rounds=0 target st
	while [ "$rounds" -lt 5 ]; do
		rounds=$((rounds + 1))
		target=''
		# dependency order (most foundational first): runtime, transproxy, transport
		for st in 4 4.1 5; do
			if [ "$(tree_node_status "$st" | cut -f1)" = 'failed' ]; then
				target="$st"; break
			fi
		done
		[ -n "$target" ] || break
		node_repair_run "$target" || true
		walked="$walked $target"
	done
	# Refresh the cached smoke so node 7 (end-to-end) reflects the POST-repair
	# reality, not a stale pre-repair result — the caller decides whether to
	# escalate to the VPS repair based on this.
	smoke_json >/dev/null 2>&1 || true
	local e2e msg
	e2e="$(tree_node_status 7 | cut -f1)"
	if [ -z "$walked" ] && [ "$e2e" = 'ok' ]; then
		msg='No router-side layer was broken and the path is healthy.'
	elif [ "$e2e" = 'ok' ]; then
		msg="Repaired router layer(s)${walked}. End-to-end client path is healthy."
	elif [ -z "$walked" ]; then
		msg='No router-side layer needed fixing, but the path is still down — the cause is the VPS or config.'
	else
		msg="Repaired router layer(s)${walked}, but the path is still down — the remaining cause is the VPS or config."
	fi
	printf '{'
	printf '"ok":'; json_bool "$([ "$e2e" = 'ok' ] && printf 1 || printf 0)"; printf ','
	printf '"walked":"%s",' "$(json_escape "$walked")"
	printf '"message":"%s",' "$(json_escape "$msg")"
	printf '"tree":'
	tree_json
	printf '}'
}

tree_json() {
	local id parent layer title side risk repair auto ui_slot gap
	local first=1 line st detail
	printf '{'
	printf '"ok":true,'
	printf '"switch_state":"%s",' "$(json_escape "$(current_switch_state)")"
	printf '"nodes":['
	while IFS='|' read -r id parent layer title side risk repair auto ui_slot gap; do
		case "$id" in ''|\#*) continue ;; esac
		line="$(tree_node_status "$id")"
		st="${line%%	*}"
		detail="${line#*	}"
		[ "$first" = '1' ] || printf ','
		first=0
		printf '{'
		printf '"id":"%s",' "$(json_escape "$id")"
		printf '"parent":"%s",' "$(json_escape "$parent")"
		printf '"layer":"%s",' "$(json_escape "$layer")"
		printf '"title":"%s",' "$(json_escape "$title")"
		printf '"side":"%s",' "$(json_escape "$side")"
		printf '"risk":"%s",' "$(json_escape "$risk")"
		printf '"repair":"%s",' "$(json_escape "$repair")"
		printf '"auto":"%s",' "$(json_escape "$auto")"
		printf '"ui_slot":"%s",' "$(json_escape "$ui_slot")"
		printf '"gap":"%s",' "$(json_escape "$gap")"
		printf '"status":"%s",' "$(json_escape "$st")"
		printf '"detail":"%s",' "$(json_escape "$detail")"
		printf '"can_repair":'; json_bool "$(case "$id" in 4|4.1|5) printf 1 ;; *) printf 0 ;; esac)"
		printf '}'
	done < "$DIAG_MANIFEST"
	printf ']'
	printf '}'
}
