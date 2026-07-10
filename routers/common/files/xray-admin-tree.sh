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

# node_repair_json <id> — run the router-side repair for one node, then return
# {ok, node, message, tree:[...]} so the UI can re-render the tree from the
# post-repair state. Only router-side, known-safe (recoverable) repairs live
# here; VPS runtime (node 6) and config apply (node 8) stay in the VPS panel /
# diagnose_repair, which already gate their disruptive/destructive steps.
node_repair_json() {
	local id="$1" rc=0 msg=''
	case "$id" in
		4)
			if restart_runtime_from_saved_config >/dev/null 2>&1; then
				msg='Xray runtime restarted and re-synced to the hardware switch.'
			else rc=1; msg='Runtime restart did not converge; see logs.'; fi ;;
		4.1)
			# The 2026-07-10 blackout recovery, one click: bring the transparent
			# proxy back and re-apply the switch state.
			/etc/init.d/codex-transproxy restart >/dev/null 2>&1 || true
			sleep 1
			/etc/gl-switch.d/xray.sh on >/dev/null 2>&1 || true
			sleep 1
			# Success = redsocks really LISTENING + nat rule (not just "the
			# command returned 0") so this cannot claim green over a dead path.
			if listen_present 12345 && nat_rule_present; then
				msg='Transparent proxy restarted; redsocks is listening on :12345 and CODEX_TRANSPROXY is active.'
			else rc=1; msg='Transparent proxy restart did not restore the path (redsocks not listening); see logs.'; fi ;;
		5)
			if [ -x /usr/bin/vpn-xray-repin-cert ]; then
				/usr/bin/vpn-xray-repin-cert >/dev/null 2>&1 || true
			fi
			if restart_runtime_from_saved_config >/dev/null 2>&1; then
				msg='Re-pinned the VPS cert (if drifted) and restarted the runtime.'
			else rc=1; msg='Re-pin/restart did not converge; see logs.'; fi ;;
		*)
			rc=2
			msg="Node $id has no one-click router-side repair. Use Diagnose & Repair (VPS/config) above." ;;
	esac
	[ "$rc" = '2' ] || sleep 2
	printf '{'
	printf '"ok":'; json_bool "$([ "$rc" = '0' ] && printf 1 || printf 0)"; printf ','
	printf '"node":"%s",' "$(json_escape "$id")"
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
