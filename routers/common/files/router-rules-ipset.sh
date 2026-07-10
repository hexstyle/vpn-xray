#!/bin/sh
# router-rules-ipset.sh — extracted from router-rules (AGENTS.md 500-line
# rule). Deployed to /usr/share/vpn-xray/. Sourced by /usr/bin/router-rules
# after lib-common.sh, before the LIB_ONLY guard. Functions only; runs no code.

selective_fallback_marker_path() { printf '%s\n' '/etc/router-rules/selective-fallback-pending'; }

selective_fallback_active() {
	[ -f "$(selective_fallback_marker_path)" ]
}

selective_fallback_reason() {
	local path
	path="$(selective_fallback_marker_path)"
	[ -f "$path" ] || return 0
	sed -n '1p' "$path"
}

enable_selective_fallback_internal() {
	local reason="${1:-rules repository unreachable during install}"
	local path
	path="$(selective_fallback_marker_path)"
	mkdir -p "$(dirname "$path")"
	printf '%s\n' "$reason" > "$path"
	chmod 600 "$path"
	# Flip routing to FULL so the user still has working internet while the
	# background loop keeps trying to bring selective back up. The intent
	# (selective) is preserved in the marker file so we can restore it
	# without depending on the workstation re-running the install.
	set_xray_mode_internal full || true
}

clear_selective_fallback_internal() {
	rm -f "$(selective_fallback_marker_path)"
}

selective_fallback_retry_internal() {
	selective_fallback_active || return 0
	repo_configured || return 1
	# Probe the repo with the existing sync path. sync_repo_internal handles
	# clone, fetch, and the failure recording, so we get the same
	# behavior — and the same status fields — as a manual sync.
	if sync_repo_internal; then
		# Make sure the rules file actually exists; an empty pull means
		# selective would route nothing and the user would still see no
		# traffic. Stay in fallback in that case.
		[ -s "$(repo_rules_path)" ] || return 1
		set_xray_mode_internal selective || return 1
		hard_cutover_xray_internal || return 1
		clear_selective_fallback_internal
		set_status_ok 'Selective routing restored; rules repository is reachable again'
		return 0
	fi
	return 1
}

resolve_domain_ipv4() {
	local host="$1"
	local dns="$2"
	local resolver result

	result="$(resolve_via_doh "$host" || true)"
	if [ -n "$result" ]; then
		printf '%s\n' "$result"
		return 0
	fi

	if [ -n "$dns" ]; then
		for resolver in $dns; do
			result="$(resolve_via_dig "$host" "$resolver" || true)"
			[ -n "$result" ] || result="$(resolve_via_nslookup "$host" "$resolver" || true)"
			if [ -n "$result" ]; then
				printf '%s\n' "$result"
				return 0
			fi
		done
	fi

	while IFS= read -r resolver || [ -n "$resolver" ]; do
		[ -n "$resolver" ] || continue
		result="$(resolve_via_dig "$host" "$resolver" || true)"
		[ -n "$result" ] || result="$(resolve_via_nslookup "$host" "$resolver" || true)"
		if [ -n "$result" ]; then
			printf '%s\n' "$result"
			return 0
		fi
	done <<EOF
$(resolver_candidates)
EOF

	result="$(resolve_via_resolveip "$host" || true)"
	if [ -n "$result" ]; then
		printf '%s\n' "$result"
		return 0
	fi

	resolve_via_doh "$host" || true
}

split_rules_internal() {
	local source_file out_domains out_literals tmp_domains tmp_literals

	source_file="$(compose_effective_rules_internal)"
	out_domains="$(domain_file)"
	out_literals="$(literal_file)"
	tmp_domains="$(rr_mktemp)"
	tmp_literals="$(rr_mktemp)"

	awk -v domains_out="$tmp_domains" -v literals_out="$tmp_literals" '
		function trim(s) {
			sub(/\r$/, "", s)
			sub(/^[[:space:]]+/, "", s)
			sub(/[[:space:]]+$/, "", s)
			return s
		}
		{
			line = trim($0)
			if (line == "" || line ~ /^#/) {
				next
			}
			if (line ~ /^[0-9]+(\.[0-9]+){3}(\/[0-9]+)?$/) {
				print line >> literals_out
			} else {
				print tolower(line) >> domains_out
			}
		}
	' "$source_file"

	sort -u "$tmp_domains" > "$out_domains"
	sort -u "$tmp_literals" > "$out_literals"
	rm -f "$tmp_domains" "$tmp_literals"
}

resolve_rules_internal() {
	local source_file dns out_map out_resolved out_domains out_literals tmp_resolved old_map line resolved
	local reuse_cache

	source_file="$(compose_effective_rules_internal)"
	dns="$(dns_resolver)"
	out_map="$(mapping_file)"
	out_resolved="$(resolved_file)"
	out_domains="$(domain_file)"
	out_literals="$(literal_file)"
	tmp_resolved="$(rr_mktemp)"
	old_map="$(rr_mktemp)"
	reuse_cache="${ROUTER_RULES_REUSE_RESOLVED_CACHE:-0}"

	split_rules_internal
	[ -f "$out_map" ] && cp "$out_map" "$old_map"
	: > "$out_map"
	: > "$tmp_resolved"

	if [ -f "$out_literals" ]; then
		while IFS= read -r line || [ -n "$line" ]; do
			[ -n "$line" ] || continue
			printf '%s\n' "$line" >> "$tmp_resolved"
			printf '%s\tliteral\t%s\n' "$line" "$line" >> "$out_map"
		done < "$out_literals"
	fi

	if [ -f "$out_domains" ]; then
		while IFS= read -r line || [ -n "$line" ]; do
			[ -n "$line" ] || continue
		if [ "$reuse_cache" = '1' ] && [ -s "$old_map" ]; then
			resolved="$(awk -F '\t' -v host="$line" '$2 == "domain" && $3 == host { print $1 }' "$old_map" | awk '!seen[$0]++')"
		else
			resolved=''
		fi
		[ -n "$resolved" ] || resolved="$(resolve_domain_ipv4 "$line" "$dns" || true)"
		printf '%s\n' "$resolved" | while IFS= read -r resolved || [ -n "$resolved" ]; do
			[ -n "$resolved" ] || continue
			printf '%s\n' "$resolved"
			printf '%s\tdomain\t%s\n' "$resolved" "$line" >> "$out_map"
		done >> "$tmp_resolved"
		done < "$out_domains"
	fi

	sort -u "$tmp_resolved" > "$out_resolved"
	rm -f "$tmp_resolved" "$old_map"
	status_set last_resolve_at "$(date +%s)"
	if [ "$reuse_cache" != '1' ]; then
		status_set last_full_resolve_at "$(date +%s)"
	fi
	status_set resolved_count "$(wc -l < "$out_resolved" | awk '{print $1}')"
	status_set source_count "$(rule_count "$(repo_rules_path)")"
	status_set effective_source_count "$(rule_count "$source_file")"
}

build_xray_ipset_internal() {
	local setname domains conf tmp_conf resolved count restore_file value old_resolved incremental adds_file dels_file

	# Preload literal targets and current A-record snapshots for domains.
	# On some OpenWrt/dnsmasq builds the ipset hook does not populate
	# runtime sets reliably, so selective routing must not depend on it.
	setname="$(xray_ipset)"
	domains="$(domain_file)"
	resolved="$(resolved_file)"
	old_resolved="$(rr_mktemp)"
	[ -f "$resolved" ] && cp "$resolved" "$old_resolved"
	if [ "${ROUTER_RULES_USE_CACHED_RESOLVED:-0}" = '1' ] && [ -f "$resolved" ]; then
		# Boot-time restore should prefer the last resolved snapshot so the
		# selective dataplane comes back before a full DNS refresh finishes.
		split_rules_internal
	else
		resolve_rules_internal
	fi
	conf="$(xray_dnsmasq_conf)"
	tmp_conf="$(rr_mktemp)"
	count=0

	incremental="${ROUTER_RULES_INCREMENTAL_IPSET:-0}"
	if [ "$incremental" = '1' ] && [ -s "$old_resolved" ] && ipset list "$setname" >/dev/null 2>&1; then
		adds_file="$(rr_mktemp)"
		dels_file="$(rr_mktemp)"
		awk 'FILENAME == ARGV[1] { old[$0]=1; next } $0 != "" && !($0 in old) { print }' "$old_resolved" "$resolved" > "$adds_file"
		awk 'FILENAME == ARGV[1] { new[$0]=1; next } $0 != "" && !($0 in new) { print }' "$resolved" "$old_resolved" > "$dels_file"
		while IFS= read -r value || [ -n "$value" ]; do
			[ -n "$value" ] || continue
			ipset add "$setname" "$value" -exist >/dev/null 2>&1 || true
		done < "$adds_file"
		while IFS= read -r value || [ -n "$value" ]; do
			[ -n "$value" ] || continue
			ipset del "$setname" "$value" >/dev/null 2>&1 || true
		done < "$dels_file"
		rm -f "$adds_file" "$dels_file"
	else
		restore_file="$(rr_mktemp)"
		{
			printf 'create %s hash:net family inet maxelem 65536 -exist\n' "$setname"
			printf 'flush %s\n' "$setname"
			if [ -f "$resolved" ]; then
				while IFS= read -r value || [ -n "$value" ]; do
					[ -n "$value" ] || continue
					printf 'add %s %s -exist\n' "$setname" "$value"
				done < "$resolved"
			fi
		} > "$restore_file"
		ipset restore < "$restore_file"
		rm -f "$restore_file"
	fi
	rm -f "$old_resolved"
	if [ -f "$resolved" ]; then
		count="$(wc -l < "$resolved" | awk '{print $1}')"
		[ -n "$count" ] || count=0
	fi

	: > "$tmp_conf"
	# Some stock OpenWrt dnsmasq-full builds (e.g. 23.05.x mediatek/filogic) are
	# compiled with no-ipset and crash on `ipset=...` directives. In that case
	# skip writing the conf — the ipset is already populated by direct DNS
	# resolution in the build script above, and the periodic sync keeps it
	# fresh, so the runtime path stays correct.
	if [ -f "$domains" ] && dnsmasq --help 2>&1 | grep -q -- '--ipset='; then
		if ! dnsmasq -v 2>&1 | grep -q 'no-ipset'; then
			while IFS= read -r value || [ -n "$value" ]; do
				[ -n "$value" ] || continue
				printf 'ipset=/%s/%s\n' "$value" "$setname" >> "$tmp_conf"
			done < "$domains"
		fi
	fi

	mkdir -p "$(dirname "$conf")"
	if ! cmp -s "$tmp_conf" "$conf" 2>/dev/null; then
		mv "$tmp_conf" "$conf"
		/etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
	else
		rm -f "$tmp_conf"
	fi

	count="$(ipset list "$setname" 2>/dev/null | sed -n 's/^Number of entries: //p' | sed -n '1p')"
	[ -n "$count" ] || count=0
	status_set xray_ipset_count "$count"
}

build_xray_dnsmasq_server_conf_internal() {
	local domains conf tmp_conf dns resolver value changed

	domains="$(domain_file)"
	conf="$(xray_dnsmasq_server_conf)"
	tmp_conf="$(rr_mktemp)"
	dns="$(dns_resolver)"
	changed=0

	: > "$tmp_conf"
	if [ -f "$domains" ] && [ -n "$dns" ]; then
		while IFS= read -r value || [ -n "$value" ]; do
			[ -n "$value" ] || continue
			for resolver in $dns; do
				[ -n "$resolver" ] || continue
				printf 'server=/%s/%s\n' "$value" "$resolver" >> "$tmp_conf"
			done
		done < "$domains"
	fi

	mkdir -p "$(dirname "$conf")"
	if [ -s "$tmp_conf" ]; then
		if ! cmp -s "$tmp_conf" "$conf" 2>/dev/null; then
			mv "$tmp_conf" "$conf"
			changed=1
		else
			rm -f "$tmp_conf"
		fi
	else
		rm -f "$tmp_conf"
		if [ -f "$conf" ]; then
			rm -f "$conf"
			changed=1
		fi
	fi

	if [ "$changed" = '1' ]; then
		/etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
	fi
}

xray_dnsmasq_ready_internal() {
	local conf domains

	conf="$(xray_dnsmasq_conf)"
	domains="$(domain_file)"

	[ -f "$conf" ] || return 1
	if [ -s "$domains" ]; then
		[ -s "$conf" ] || return 1
	fi
	return 0
}

clear_xray_dnsmasq_internal() {
	local conf

	conf="$(xray_dnsmasq_conf)"
	if [ -f "$conf" ]; then
		rm -f "$conf"
		/etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
	fi
}

ensure_ipv4_only_dns_internal() {
	local current

	current="$(uci -q get dhcp.@dnsmasq[0].filter_aaaa 2>/dev/null || echo 0)"
	[ "$current" = '1' ] && return 0
	uci set dhcp.@dnsmasq[0].filter_aaaa='1'
	uci commit dhcp
	/etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
}

save_last_known_good_dir_internal() {
	local lkg="$1"
	local gen_dir eff_file

	gen_dir="$(generated_dir)"
	eff_file="$(effective_rules_file)"

	[ -f "$eff_file" ] || return 0

	rm -rf "${lkg}.tmp"
	mkdir -p "${lkg}.tmp"
	[ -f "$eff_file" ] && cp "$eff_file" "${lkg}.tmp/"
	[ -f "$(domain_file)" ] && cp "$(domain_file)" "${lkg}.tmp/"
	[ -f "$(literal_file)" ] && cp "$(literal_file)" "${lkg}.tmp/"
	[ -f "$(resolved_file)" ] && cp "$(resolved_file)" "${lkg}.tmp/"
	mkdir -p "${lkg}.tmp/rules-tree"
	snapshot_rules_tree_from_worktree_internal "$(repo_path)" "${lkg}.tmp/rules-tree" || true
	printf '%s\n' "$(xray_mode)" > "${lkg}.tmp/mode"
	printf '%s\n' "$(rules_relpath)" > "${lkg}.tmp/rules_relpath"
	printf '%s\n' "$(tracked_rules_signature)" > "${lkg}.tmp/rules_signature"
	date +%s > "${lkg}.tmp/timestamp"

	rm -rf "${lkg}.old"
	[ -d "$lkg" ] && mv "$lkg" "${lkg}.old"
	mv "${lkg}.tmp" "$lkg"
	rm -rf "${lkg}.old"
}

save_last_known_good() {
	local mode mode_lkg

	mode="$(xray_mode)"
	mode_lkg="/etc/router-rules/last-known-good-${mode}"
	save_last_known_good_dir_internal "$mode_lkg"
	save_last_known_good_dir_internal '/etc/router-rules/last-known-good'
}

restore_lkg_internal() {
	local lkg='/etc/router-rules/last-known-good'
	local gen_dir mode

	mode="$(xray_mode)"
	case "$mode" in
		full|selective)
			if [ -d "/etc/router-rules/last-known-good-${mode}" ]; then
				lkg="/etc/router-rules/last-known-good-${mode}"
			fi
			;;
	esac
	[ -d "$lkg" ] || {
		echo 'no last-known-good state found' >&2
		return 1
	}
	[ -f "$lkg/effective_shared_targets.txt" ] || {
		echo 'last-known-good state is incomplete' >&2
		return 1
	}

	gen_dir="$(generated_dir)"
	mkdir -p "$gen_dir"

	cp "$lkg/effective_shared_targets.txt" "$(effective_rules_file)"
	[ -f "$lkg/domains.txt" ] && cp "$lkg/domains.txt" "$(domain_file)"
	[ -f "$lkg/literals_ipv4.txt" ] && cp "$lkg/literals_ipv4.txt" "$(literal_file)"
	[ -f "$lkg/resolved_ipv4.txt" ] && cp "$lkg/resolved_ipv4.txt" "$(resolved_file)"
	if [ -d "$lkg/rules-tree" ]; then
		restore_rules_tree_exact_local_internal "$lkg/rules-tree" "$(repo_path)"
	fi
	[ -f "$lkg/mode" ] && mode="$(cat "$lkg/mode")" || mode='full'
	uci set router_rules.global.xray_mode="$mode"
	uci commit router_rules

	apply_xray_internal
}

