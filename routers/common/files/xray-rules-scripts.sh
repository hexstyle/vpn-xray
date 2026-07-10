#!/bin/sh
# xray-rules-scripts.sh — external-script CRUD + file download
# for the xray-rules CGI.
# Deployed to /usr/share/vpn-xray/xray-rules-scripts.sh
# Sourced by /www/cgi-bin/xray-rules after lib-common.sh (shares its scope).
# Defines functions only; runs no code.

save_external_script_action() {
	local source_id label url script_text max_targets tmp_json validate_out error_file rc line_count message

	source_id="$(request_value source_id)"
	label="$(request_value label)"
	url="$(request_value url)"
	script_text="$(request_value script_text)"
	max_targets="$(request_value max_targets)"

	[ -n "$source_id" ] || {
		emit_error save_external_script 'Source ID is required.'
		return 0
	}
	case "$source_id" in
		*[!a-z0-9_]*)
			emit_error save_external_script 'Source ID must contain only lowercase letters, digits and underscores.'
			return 0
			;;
	esac
	[ -n "$label" ] || label="$source_id"
	[ -n "$url" ] || {
		emit_error save_external_script 'Source URL is required.'
		return 0
	}
	[ -n "$script_text" ] || {
		emit_error save_external_script 'Script text is required.'
		return 0
	}
	case "$max_targets" in
		''|*[!0-9]*) max_targets='5000' ;;
	esac

	tmp_json="$(mktemp)"
	python3 -c "
import json, sys
data = {
    'id': sys.argv[1],
    'label': sys.argv[2],
    'url': sys.argv[3],
    'script': sys.stdin.read(),
    'max_targets': int(sys.argv[4])
}
json.dump(data, open(sys.argv[5], 'w'), indent=2, ensure_ascii=False)
" "$source_id" "$label" "$url" "$max_targets" "$tmp_json" <<SCRIPT_EOF
$script_text
SCRIPT_EOF

	validate_out="$(mktemp)"
	error_file="$(mktemp)"
	rc=0
	if command -v timeout >/dev/null 2>&1; then
		timeout "$RULES_EXTERNAL_VALIDATE_TIMEOUT" /usr/bin/router-rules validate-external-script "$tmp_json" > "$validate_out" 2> "$error_file" || rc=$?
	else
		/usr/bin/router-rules validate-external-script "$tmp_json" > "$validate_out" 2> "$error_file" || rc=$?
	fi

	if [ "$rc" -ne 0 ]; then
		message="$(sed '/^[[:space:]]*$/d' "$error_file" | sed -n '1p')"
		[ -n "$message" ] || message='Script validation failed.'
		rm -f "$tmp_json" "$validate_out" "$error_file"
		emit_error save_external_script "$message"
		return 0
	fi

	line_count="$(awk '{print $2}' "$validate_out")"

	ROUTER_RULES_SYNC_ACTOR='ui-save-script' /usr/bin/router-rules save-external-script "$tmp_json" >/dev/null 2>&1 || {
		rm -f "$tmp_json" "$validate_out" "$error_file"
		emit_error save_external_script 'Failed to save script to git.'
		return 0
	}

	rm -f "$tmp_json" "$validate_out" "$error_file"

	emit_header
	printf '{'
	printf '"ok":true,'
	printf '"action":"save_external_script",'
	printf '"source_id":"%s",' "$(json_escape "$source_id")"
	printf '"validated_lines":"%s"' "$(json_escape "$line_count")"
	printf '}'
}

delete_external_script_action() {
	local source_id error_file rc message

	source_id="$(request_value source_id)"
	[ -n "$source_id" ] || {
		emit_error delete_external_script 'Source ID is required.'
		return 0
	}

	error_file="$(mktemp)"
	rc=0
	ROUTER_RULES_SYNC_ACTOR='ui-delete-script' /usr/bin/router-rules delete-external-script "$source_id" >/dev/null 2> "$error_file" || rc=$?

	if [ "$rc" -ne 0 ]; then
		message="$(sed '/^[[:space:]]*$/d' "$error_file" | sed -n '1p')"
		[ -n "$message" ] || message='Failed to delete external source script.'
		rm -f "$error_file"
		emit_error delete_external_script "$message"
		return 0
	fi
	rm -f "$error_file"

	emit_header
	printf '{'
	printf '"ok":true,'
	printf '"action":"delete_external_script",'
	printf '"source_id":"%s"' "$(json_escape "$source_id")"
	printf '}'
}

read_external_script_action() {
	local source_id script_json error_file rc message

	source_id="$(request_value source_id)"
	[ -n "$source_id" ] || {
		emit_error read_external_script 'Source ID is required.'
		return 0
	}

	script_json="$(mktemp)"
	error_file="$(mktemp)"
	rc=0
	/usr/bin/router-rules read-external-script "$source_id" > "$script_json" 2> "$error_file" || rc=$?

	if [ "$rc" -ne 0 ]; then
		message="$(sed '/^[[:space:]]*$/d' "$error_file" | sed -n '1p')"
		[ -n "$message" ] || message='Script not found.'
		rm -f "$script_json" "$error_file"
		emit_error read_external_script "$message"
		return 0
	fi

	local label url script_text max_targets
	label="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('label',''))" "$script_json" 2>/dev/null || true)"
	url="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('url',''))" "$script_json" 2>/dev/null || true)"
	script_text="$(python3 -c "import json,sys; sys.stdout.write(json.load(open(sys.argv[1])).get('script',''))" "$script_json" 2>/dev/null || true)"
	max_targets="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('max_targets',5000))" "$script_json" 2>/dev/null || echo 5000)"
	rm -f "$script_json" "$error_file"

	emit_header
	printf '{'
	printf '"ok":true,'
	printf '"action":"read_external_script",'
	printf '"source_id":"%s",' "$(json_escape "$source_id")"
	printf '"label":"%s",' "$(json_escape "$label")"
	printf '"url":"%s",' "$(json_escape "$url")"
	printf '"max_targets":"%s",' "$(json_escape "$max_targets")"
	printf '"script_text":"%s"' "$(json_escape "$script_text")"
	printf '}'
}

download_external_file_action() {
	local source_id download_type output_file error_file rc message filename

	source_id="$(request_value source_id)"
	download_type="$(request_value type)"
	[ -n "$source_id" ] || {
		emit_error download_external_file 'Source ID is required.'
		return 0
	}
	[ -n "$download_type" ] || download_type='stored'

	output_file="$(mktemp)"
	error_file="$(mktemp)"
	rc=0

	case "$download_type" in
		preview)
			filename="${source_id}_preview.txt"
			if command -v timeout >/dev/null 2>&1; then
				ROUTER_RULES_LOCK_WAIT="$RULES_EXTERNAL_LOCK_WAIT" ROUTER_RULES_SYNC_ACTOR='ui-download-preview' timeout "$RULES_EXTERNAL_PREVIEW_TIMEOUT" /usr/bin/router-rules preview-external-source "$source_id" > "$output_file" 2> "$error_file" || rc=$?
			else
				ROUTER_RULES_LOCK_WAIT="$RULES_EXTERNAL_LOCK_WAIT" ROUTER_RULES_SYNC_ACTOR='ui-download-preview' /usr/bin/router-rules preview-external-source "$source_id" > "$output_file" 2> "$error_file" || rc=$?
			fi
			;;
		*)
			filename="${source_id}.txt"
			/usr/bin/router-rules read-external-source "$source_id" > "$output_file" 2> "$error_file" || rc=$?
			;;
	esac

	if [ "$rc" -ne 0 ]; then
		message="$(sed '/^[[:space:]]*$/d' "$error_file" | sed -n '1p')"
		[ -n "$message" ] || message='External file download failed.'
		rm -f "$output_file" "$error_file"
		emit_error download_external_file "$message"
		return 0
	fi
	rm -f "$error_file"

	printf 'Content-Type: text/plain\r\n'
	printf 'Content-Disposition: attachment; filename="%s"\r\n' "$filename"
	printf 'Cache-Control: no-store\r\n'
	printf '\r\n'
	cat "$output_file"
	rm -f "$output_file"
}
