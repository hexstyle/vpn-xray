#!/bin/sh
# router-rules-external-a.sh — extracted from router-rules (AGENTS.md 500-line
# rule). Deployed to /usr/share/vpn-xray/. Sourced by /usr/bin/router-rules
# after lib-common.sh, before the LIB_ONLY guard. Functions only; runs no code.

compose_effective_rules_internal() {
	local manual_file combined_file out_file collapsed_file tracked_sig id label url path python_bin
	local skip_collapse

	recover_empty_manual_rules_internal 'compose-effective-rules' || true
	manual_file="$(repo_rules_path)"
	skip_collapse="${ROUTER_RULES_SKIP_EFFECTIVE_COLLAPSE:-0}"
	tracked_sig="$(tracked_rules_signature)|collapse_skipped:${skip_collapse}"
	if [ -s "$(effective_rules_file)" ] \
		&& [ -f "$(effective_rules_signature_file)" ] \
		&& [ "$(cat "$(effective_rules_signature_file)" 2>/dev/null || true)" = "$tracked_sig" ]; then
		printf '%s\n' "$(effective_rules_file)"
		return 0
	fi
	combined_file="$(rr_mktemp)"
	out_file="$(rr_mktemp)"
	collapsed_file="$(rr_mktemp)"

	: > "$combined_file"
	if [ -s "$manual_file" ]; then
		cat "$manual_file" >> "$combined_file"
	fi

	while IFS='|' read -r id label url || [ -n "$id" ]; do
		[ -n "$id" ] || continue
		[ "$(external_source_enabled_by_id "$id")" = '1' ] || continue
		path="$(external_source_path "$id")"
		[ -s "$path" ] || continue
		if [ -s "$combined_file" ]; then
			printf '\n' >> "$combined_file"
		fi
		cat "$path" >> "$combined_file"
	done <<EOF
$(external_source_catalog)
EOF

	awk '
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
			norm = tolower(line)
			if (!(norm in seen)) {
				print line
				seen[norm] = 1
			}
		}
	' "$combined_file" > "$out_file"

	python_bin="$(python_interpreter || true)"
	if [ "$skip_collapse" = '1' ]; then
		rm -f "$collapsed_file"
		mv "$out_file" "$(effective_rules_file)"
	elif [ -n "$python_bin" ] && [ -f "$(external_source_script)" ]; then
		if "$python_bin" "$(external_source_script)" --collapse --input-file "$out_file" > "$collapsed_file" 2>/dev/null; then
			mv "$collapsed_file" "$(effective_rules_file)"
		else
			rm -f "$collapsed_file"
			mv "$out_file" "$(effective_rules_file)"
		fi
	else
		rm -f "$collapsed_file"
		mv "$out_file" "$(effective_rules_file)"
	fi
	printf '%s\n' "$tracked_sig" > "$(effective_rules_signature_file)"
	rm -f "$combined_file" "$out_file"
	printf '%s\n' "$(effective_rules_file)"
}

maybe_migrate_external_repo_layout_internal() {
	local union_file filtered_file main_file removed_count before_count after_count current_version

	current_version="$(external_source_repo_layout_version)"
	managed_external_sources_present_internal || {
		printf '0\n'
		return 0
	}

	main_file="$(repo_rules_path)"
	union_file="$(rr_mktemp)"
	filtered_file="$(rr_mktemp)"
	collect_managed_external_sources_internal "$union_file"
	[ -f "$main_file" ] || : > "$main_file"
	before_count="$(rule_count "$main_file")"

	awk '
		function trim(s) {
			sub(/\r$/, "", s)
			sub(/^[[:space:]]+/, "", s)
			sub(/[[:space:]]+$/, "", s)
			return s
		}
		FILENAME == ARGV[1] {
			line = trim($0)
			if (line == "" || line ~ /^#/) {
				next
			}
			managed[tolower(line)] = 1
			next
		}
		{
			line = trim($0)
			if (line == "" || line ~ /^#/) {
				print
				next
			}
			if (!(tolower(line) in managed)) {
				print line
			}
		}
	' "$union_file" "$main_file" > "$filtered_file"

	after_count="$(rule_count "$filtered_file")"
	removed_count=$((before_count - after_count))
	if [ "$before_count" -gt 0 ] 2>/dev/null \
		&& [ "$after_count" -eq 0 ] 2>/dev/null \
		&& ! allow_empty_manual_rules_internal; then
		rm -f "$union_file" "$filtered_file"
		backup_rules_tree_internal 'blocked-empty-manual-external-migration' >/dev/null 2>&1 || true
		set_status_error "refusing to migrate $(rules_relpath) to an empty manual rules file; set ROUTER_RULES_ALLOW_EMPTY_MANUAL=1 only for an intentional wipe"
		return 1
	fi
	if ! cmp -s "$main_file" "$filtered_file" 2>/dev/null; then
		backup_rules_tree_internal 'before-external-layout-migration' >/dev/null 2>&1 || true
		mv "$filtered_file" "$main_file"
	else
		rm -f "$filtered_file"
	fi
	rm -f "$union_file"
	if [ "$current_version" != "$EXTERNAL_SOURCE_REPO_LAYOUT_VERSION" ]; then
		uci -q set "${CONFIG_PKG}.${CONFIG_SECTION}.external_source_repo_layout_version=${EXTERNAL_SOURCE_REPO_LAYOUT_VERSION}"
		uci commit "$CONFIG_PKG"
	fi
	if [ "$removed_count" -gt 0 ] 2>/dev/null; then
		status_trace_add sync_trace "external migrated: moved ${removed_count} managed targets out of $(rules_relpath)"
	fi
	printf '%s\n' "$removed_count"
}

external_source_script_for_id() {
	local id="$1"
	local json_file tmp_script
	json_file="$(scripts_dir)/${id}.json"
	[ -f "$json_file" ] || return 1
	tmp_script="$(rr_mktemp)"
	python3 -c "import json,sys; sys.stdout.write(json.load(open(sys.argv[1])).get('script',''))" "$json_file" > "$tmp_script" 2>/dev/null || {
		rm -f "$tmp_script"
		return 1
	}
	[ -s "$tmp_script" ] || { rm -f "$tmp_script"; return 1; }
	printf '%s\n' "$tmp_script"
}

external_source_max_targets() {
	local id="$1"
	local json_file val
	json_file="$(scripts_dir)/${id}.json"
	[ -f "$json_file" ] || { printf '%s\n' "$EXTERNAL_SCRIPT_MAX_TARGETS"; return 0; }
	val="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('max_targets',$EXTERNAL_SCRIPT_MAX_TARGETS))" "$json_file" 2>/dev/null || echo "$EXTERNAL_SCRIPT_MAX_TARGETS")"
	if [ "$val" -gt "$EXTERNAL_SCRIPT_MAX_TARGETS" ] 2>/dev/null; then
		val="$EXTERNAL_SCRIPT_MAX_TARGETS"
	fi
	printf '%s\n' "$val"
}

generate_external_source_internal() {
	local id="$1"
	local url script script_file timeout_seconds python_bin max_targets rc

	url="$(external_source_url_by_id "$id" 2>/dev/null || true)"
	[ -n "$url" ] || {
		echo "Unknown external source: $id" >&2
		return 1
	}
	python_bin="$(python_interpreter || true)"
	[ -n "$python_bin" ] || {
		echo 'python3 or python is required for external source imports on this router.' >&2
		return 1
	}
	timeout_seconds="$(external_source_timeout)"

	script_file="$(external_source_script_for_id "$id" 2>/dev/null || true)"
	if [ -n "$script_file" ] && [ -f "$script_file" ]; then
		max_targets="$(external_source_max_targets "$id")"
		local script_timeout tmp_out tmp_err line_count bad_lines
		script_timeout="$EXTERNAL_SCRIPT_TIMEOUT"
		tmp_out="$(rr_mktemp)"
		tmp_err="$(rr_mktemp)"
		rc=0
		run_with_timeout "$script_timeout" "$python_bin" "$script_file" --collapse --url "$url" --timeout "$script_timeout" > "$tmp_out" 2> "$tmp_err" || rc=$?
		rm -f "$script_file"
		if [ "$rc" -ne 0 ]; then
			if [ "$rc" -eq 124 ] 2>/dev/null; then
				echo "Script $id killed: exceeded ${script_timeout}s timeout" >&2
			else
				echo "Script $id failed with exit code $rc" >&2
			fi
			head -5 "$tmp_err" >&2
			rm -f "$tmp_out" "$tmp_err"
			return 1
		fi
		rm -f "$tmp_err"
		line_count="$(wc -l < "$tmp_out" | awk '{print $1}')"
		if [ "$line_count" -eq 0 ]; then
			echo "Script $id produced no output" >&2
			rm -f "$tmp_out"
			return 1
		fi
		if [ "$line_count" -gt "$max_targets" ] 2>/dev/null; then
			echo "Script $id produced $line_count lines (max $max_targets), rejecting" >&2
			rm -f "$tmp_out"
			return 1
		fi
		bad_lines="$(awk '
			/^[[:space:]]*$/ { next }
			/^[0-9]+(\.[0-9]+){3}(\/[0-9]+)?$/ { next }
			/^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?\.[a-zA-Z]{2,}$/ { next }
			{ print NR": "$0 }
		' "$tmp_out" | head -3)"
		if [ -n "$bad_lines" ]; then
			printf 'Script %s: invalid output lines:\n%s\n' "$id" "$bad_lines" >&2
			rm -f "$tmp_out"
			return 1
		fi
		cat "$tmp_out"
		rm -f "$tmp_out"
		return 0
	fi

	script="$(external_source_script)"
	[ -f "$script" ] || {
		echo "External source generator is missing on this router: $script" >&2
		return 1
	}
	run_with_timeout "$timeout_seconds" "$python_bin" "$script" --collapse --url "$url" --timeout "$timeout_seconds"
}

preview_external_source_internal() {
	local id="${1:-}"

	external_source_record "$id" >/dev/null 2>&1 || {
		echo 'Unknown external source.' >&2
		return 1
	}
	generate_external_source_internal "$id"
}

read_external_source_internal() {
	local id="$1"
	local path

	external_source_record "$id" >/dev/null 2>&1 || {
		echo 'Unknown external source.' >&2
		return 1
	}
	path="$(external_source_path "$id")"
	[ -f "$path" ] && cat "$path"
}

read_external_script_internal() {
	local id="$1"
	local json_file
	json_file="$(scripts_dir)/${id}.json"
	[ -f "$json_file" ] || { echo "Script not found: $id" >&2; return 1; }
	cat "$json_file"
}

validate_external_script_internal() {
	local json_file="$1" python_bin tmp_script url timeout_seconds output line_count rc max_targets bad_lines real_script

	python_bin="$(python_interpreter || true)"
	[ -n "$python_bin" ] || { echo 'python3 required' >&2; return 1; }

	tmp_script="$(rr_mktemp)"
	"$python_bin" -c "
import json, sys, py_compile, tempfile, os
data = json.load(open(sys.argv[1]))
script = data.get('script', '')
if not script.strip():
    print('Script is empty', file=sys.stderr); sys.exit(1)
tf = tempfile.NamedTemporaryFile(suffix='.py', delete=False, mode='w')
tf.write(script); tf.close()
try:
    py_compile.compile(tf.name, doraise=True)
except py_compile.PyCompileError as e:
    print('Syntax error: {}'.format(e), file=sys.stderr)
    os.unlink(tf.name); sys.exit(1)
print(tf.name)
" "$json_file" > "$tmp_script" 2>&1
	rc=$?
	if [ "$rc" -ne 0 ]; then
		cat "$tmp_script" >&2
		rm -f "$tmp_script"
		return 1
	fi

	real_script="$(cat "$tmp_script")"
	rm -f "$tmp_script"

	url="$("$python_bin" -c "import json,sys; print(json.load(open(sys.argv[1])).get('url',''))" "$json_file")"
	timeout_seconds="$EXTERNAL_SCRIPT_TIMEOUT"
	output="$(rr_mktemp)"
	if ! run_with_timeout "$timeout_seconds" "$python_bin" "$real_script" --collapse --url "$url" --timeout "$timeout_seconds" > "$output" 2>&1; then
		echo "Script timed out or failed (limit ${timeout_seconds}s)" >&2
		head -5 "$output" >&2
		rm -f "$output" "$real_script"
		return 1
	fi
	rm -f "$real_script"

	line_count="$(wc -l < "$output" | awk '{print $1}')"
	max_targets="$("$python_bin" -c "import json,sys; print(json.load(open(sys.argv[1])).get('max_targets',5000))" "$json_file" 2>/dev/null || echo "$EXTERNAL_SCRIPT_MAX_TARGETS")"

	if [ "$line_count" -eq 0 ]; then
		echo "Script produced no output" >&2
		rm -f "$output"; return 1
	fi
	if [ "$line_count" -gt "$max_targets" ] 2>/dev/null; then
		echo "Script produced $line_count lines (max $max_targets)" >&2
		rm -f "$output"; return 1
	fi

	bad_lines="$(awk '
		/^[[:space:]]*$/ { next }
		/^[0-9]+(\.[0-9]+){3}(\/[0-9]+)?$/ { next }
		/^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?\.[a-zA-Z]{2,}$/ { next }
		{ print NR": "$0 }
	' "$output" | head -3)"

	if [ -n "$bad_lines" ]; then
		printf 'Invalid output lines:\n%s\n' "$bad_lines" >&2
		rm -f "$output"; return 1
	fi

	printf 'ok %s lines\n' "$line_count"
	rm -f "$output"
}

save_external_script_internal() {
	local json_file="$1"
	local sdir id

	sdir="$(scripts_dir)"
	mkdir -p "$sdir"

	id="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('id',''))" "$json_file" 2>/dev/null || true)"
	[ -n "$id" ] || { echo 'Missing id in JSON.' >&2; return 1; }

	cp "$json_file" "${sdir}/${id}.json"

	if repo_configured && [ -d "$(repo_path)/.git" ]; then
		(
			cd "$(repo_path)"
			git add "${SCRIPTS_DIR_RELPATH}/${id}.json"
			git -c user.name="$(git_user_name)" -c user.email="$(git_user_email)" \
				commit -m "Update external source script: $id" -- "${SCRIPTS_DIR_RELPATH}/${id}.json" 2>/dev/null || true
		)
	fi
	printf 'saved %s\n' "$id"
}

delete_external_script_internal() {
	local id="$1"
	local sdir json_file ext_file

	sdir="$(scripts_dir)"
	json_file="${sdir}/${id}.json"
	[ -f "$json_file" ] || { echo "Script not found: $id" >&2; return 1; }

	rm -f "$json_file"
	ext_file="$(external_source_path "$id")"
	rm -f "$ext_file"

	if repo_configured && [ -d "$(repo_path)/.git" ]; then
		(
			cd "$(repo_path)"
			git rm -f --quiet "${SCRIPTS_DIR_RELPATH}/${id}.json" 2>/dev/null || true
			git rm -f --quiet "$(external_source_relpath "$id")" 2>/dev/null || true
			git -c user.name="$(git_user_name)" -c user.email="$(git_user_email)" \
				commit -m "Remove external source script: $id" 2>/dev/null || true
		)
	fi
	printf 'deleted %s\n' "$id"
}

migrate_external_catalog_internal() {
	local sdir python_bin bundled_script script_text id label url json_file count
	sdir="$(scripts_dir)"

	if [ -d "$sdir" ] && ls "$sdir"/*.json >/dev/null 2>&1; then
		echo 'Scripts directory already has JSON files, skipping migration.' >&2
		return 0
	fi

	python_bin="$(python_interpreter || true)"
	[ -n "$python_bin" ] || { echo 'python3 required for migration' >&2; return 1; }

	bundled_script="$(external_source_script)"
	[ -f "$bundled_script" ] || { echo "Bundled parser not found: $bundled_script" >&2; return 1; }

	script_text="$(cat "$bundled_script")"
	mkdir -p "$sdir"
	count=0

	while IFS='|' read -r id label url || [ -n "$id" ]; do
		[ -n "$id" ] || continue
		json_file="${sdir}/${id}.json"
		"$python_bin" -c "
import json, sys
data = {
    'id': sys.argv[1],
    'label': sys.argv[2],
    'url': sys.argv[3],
    'script': sys.argv[4],
    'max_targets': 5000
}
json.dump(data, open(sys.argv[5], 'w'), indent=2, ensure_ascii=False)
" "$id" "$label" "$url" "$script_text" "$json_file"
		count=$((count + 1))
	done <<'EOF'
microsoft_service_tags|Microsoft Service Tags|https://www.microsoft.com/en-us/download/details.aspx?id=56519
cloudflare_ipv4|Cloudflare IPv4|https://www.cloudflare.com/ips-v4
google_ipv4|Google IPv4 Ranges|https://www.gstatic.com/ipranges/goog.json
aws_ipv4|AWS IPv4 Ranges|https://ip-ranges.amazonaws.com/ip-ranges.json
EOF

	if repo_configured && [ -d "$(repo_path)/.git" ]; then
		(
			cd "$(repo_path)"
			git add "$SCRIPTS_DIR_RELPATH"
			git -c user.name="$(git_user_name)" -c user.email="$(git_user_email)" \
				commit -m "Migrate external source catalog to JSON scripts" -- "$SCRIPTS_DIR_RELPATH" 2>/dev/null || true
		)
	fi
	printf 'migrated %s sources\n' "$count"
}

