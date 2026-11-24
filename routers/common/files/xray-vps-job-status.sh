#!/bin/sh
# Read-only Apply history serialization and polling (tree 8.2a).
# Loaded beside setup by both CGI profiles; never repairs/deletes history.
router_apply_status_json() {
	local state='' profile='' message='' pid='' applied='' health='' origin='' steps='[]'
	local step_error='' index type field snapshot key value seen='|' error='' scheduled='' age pointer="$ROUTER_APPLY_STATUS_FILE"
	local ROUTER_APPLY_STATUS_FILE="$(router_apply_status_path)"
	if [ ! -e "$ROUTER_APPLY_STATUS_FILE" ] && [ ! -L "$ROUTER_APPLY_STATUS_FILE" ]; then
		if [ -L "$pointer" ]; then error='Router apply history link has no target; actual application state unknown.'
		else state=idle; fi
	elif [ ! -f "$ROUTER_APPLY_STATUS_FILE" ] || ! snapshot="$(cat "$ROUTER_APPLY_STATUS_FILE" 2>/dev/null)"; then
		error='Router apply history is unreadable; actual application state unknown.'
	else
		while IFS='=' read -r key value || [ -n "$key" ]; do
			case "$key" in
				state|profile|message|pid|router_apply|path_health|origin|scheduled_at)
					case "$seen" in *"|$key|"*) error='Router apply history has duplicate fields.';; esac
					seen="$seen$key|";;
			esac
			case "$key" in
				state) state="$value";; profile) profile="$value";; message) message="$value";;
				pid) pid="$value";; router_apply) applied="$value";; path_health) health="$value";;
				origin) origin="$value";; scheduled_at) scheduled="$value";;
			esac
		done <<EOF
$snapshot
EOF
		case "$state" in
			scheduled)
				case "$scheduled" in ''|*[!0-9]*|0*|???????????*) error='Router apply history has an invalid schedule timestamp.';;
					*) age=$(($(date +%s) - scheduled))
						[ "$age" -ge 0 ] && [ "$age" -lt 10 ] || error='Router apply did not start within its scheduled grace period.';;
				esac;;
			running)
				case "$pid" in ''|*[!0-9]*|0) error='Router apply history has an invalid process ID.';;
					*) kill -0 "$pid" 2>/dev/null || error='Router apply job ended without a final result; inspect actual target/runtime.';;
				esac;;
			done|failed) ;;
			*) error='Router apply history is empty or invalid; actual application state unknown.';;
		esac
	fi
	case "$applied" in ''|applied|unchanged|rolled_back|unknown) ;; *) error='Router apply history has an invalid application outcome.';; esac
	case "$health" in ''|ok|failed|not_checked|unknown) ;; *) error='Router apply history has an invalid health outcome.';; esac
	case "$state" in
		done)
			[ -n "$message" ] || error='Router apply success history is missing its terminal message.'
			case "$applied:$health" in applied:ok|unchanged:ok|applied:not_checked|unchanged:not_checked) ;;
				*) error='Router apply success history has missing or inconsistent outcomes; actual application state unknown.';;
			esac;;
		failed)
			[ -n "$applied" ] && [ -n "$health" ] || error='Router apply failure history has missing outcomes; actual application state unknown.';;
	esac
	if [ -e "$ROUTER_APPLY_STATUS_FILE.steps" ] || [ -L "$ROUTER_APPLY_STATUS_FILE.steps" ]; then
		if ! steps="$(cat "$ROUTER_APPLY_STATUS_FILE.steps" 2>/dev/null)" ||
			[ "$(jsonfilter -s "[$steps]" -t '@[0]' 2>/dev/null)" != array ] ||
			[ -n "$(jsonfilter -s "[$steps]" -t '@[1]' 2>/dev/null)" ] ||
			! steps="$(jsonfilter -s "[$steps]" -e '@[0]' 2>/dev/null)"; then
			steps='[]'; error='Router apply step report is unreadable or invalid; stored history was preserved.'
		fi
	fi
	# Use the same native object/type predicates as the pipeline report reader.
	# The UI dereferences every row; valid JSON alone does not make it a step.
	index=0
	# Indexed null looks absent in native jsonfilter; wildcard types retain it.
	for type in $(jsonfilter -s "$steps" -t '@[*]' 2>/dev/null | tr '\\' ' '); do
		if [ "$type" != object ]; then step_error='Router apply step report contains a non-object step.'; break; fi
		for field in id status message; do
			[ "$(jsonfilter -s "$steps" -t "@[$index].$field" 2>/dev/null)" = string ] || step_error='Router apply step report has missing or invalid display fields.'
		done
		case "$(jsonfilter -s "$steps" -e "@[$index].status" 2>/dev/null)" in ok|fixed|failed|skipped) ;;
			*) step_error='Router apply step report has an invalid step status.';; esac
		case "$(jsonfilter -s "$steps" -t "@[$index].details" 2>/dev/null)" in ''|string) ;;
			*) step_error='Router apply step report has invalid details.';; esac
		[ -z "$step_error" ] || break
		index=$((index + 1))
	done
	if [ -n "$step_error" ]; then steps='[]'; error="$step_error"; fi
	if [ -n "$error" ]; then state=failed; message="$error"; applied=unknown; health=unknown; fi
	printf '{"router_apply":"%s","path_health":"%s","origin":"%s",' "$(json_escape "${applied:-unknown}")" "$(json_escape "${health:-not_checked}")" "$(json_escape "$origin")"
	printf '"applied":'
	case "$applied" in applied) printf true;; unknown|'') printf null;; *) printf false;; esac
	printf ',"steps":%s,' "$steps"
	printf '"state":"%s","profile_id":"%s","message":"%s","raw_log":"%s"}' \
		"$(json_escape "$state")" "$(json_escape "$profile")" "$(json_escape "$message")" \
		"$(raw_log_payload "$ROUTER_APPLY_STATUS_FILE.log")"
}

router_apply_status_action() {
	local job_id="$(request_value job_id)"
	local ROUTER_APPLY_STATUS_FILE="$ROUTER_APPLY_STATUS_FILE"
	if [ -n "$job_id" ]; then
		repair_job_valid_id "$job_id" || { emit_error apply_router_status 'Invalid job ID'; return; }
		ROUTER_APPLY_STATUS_FILE="$VPS_REPAIR_JOB_DIR/$job_id/status"
		[ -s "$ROUTER_APPLY_STATUS_FILE" ] || { emit_error apply_router_status 'Unknown job ID'; return; }
	fi
	emit_header
	printf '{"ok":true,"action":"apply_router_status","job":'
	router_apply_status_json
	printf '}'
}
