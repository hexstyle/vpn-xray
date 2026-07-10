#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
ROUTER_RULES_FILE="$ROOT/routers/common/files/router-rules"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT INT TERM

VX_LIB_COMMON="$ROOT/routers/common/files/lib-common.sh" VX_RULES_LIB_DIR="$ROOT/routers/common/files" ROUTER_RULES_LIB_ONLY=1 . "$ROUTER_RULES_FILE"

status_set() { :; }
status_get() {
	case "$1" in
		last_sync_changed)
			printf '%s\n' "${LAST_SYNC_CHANGED:-0}"
			;;
		*)
			printf '\n'
			;;
	esac
}

set_sync_phase() {
	printf '%s|%s\n' "$1" "$2" >> "$TMPDIR/phases.log"
}

xray_mode() { printf '%s\n' 'selective'; }

run_case() {
	local name="$1"
	local repo_enabled="$2"
	local resolved_drift="$3"
	local runtime_drift="$4"
	local sync_changed="$5"
	local apply_calls_file="$TMPDIR/${name}.apply"
	local cutover_calls_file="$TMPDIR/${name}.cutover"

	: > "$TMPDIR/phases.log"
	: > "$apply_calls_file"
	: > "$cutover_calls_file"

	repo_configured() {
		[ "$repo_enabled" = '1' ]
	}

	sync_actor() {
		printf '%s\n' 'background'
	}

	resolved_snapshot_needs_apply_internal() {
		[ "$resolved_drift" = '1' ]
	}

	xray_needs_apply_internal() {
		[ "$runtime_drift" = '1' ] || [ "$sync_changed" = '1' ]
	}

	sync_repo_internal() {
		LAST_SYNC_CHANGED="$sync_changed"
		return 0
	}

	apply_xray_internal() {
		printf 'apply\n' >> "$apply_calls_file"
	}

	hard_cutover_xray_internal() {
		printf 'cutover\n' >> "$cutover_calls_file"
	}

	LAST_SYNC_CHANGED=0
	sync_apply_xray_internal

	printf '%s\n' "$apply_calls_file|$cutover_calls_file"
}

files="$(run_case local_only_resolved 0 1 0 0)"
apply_file="${files%%|*}"
cutover_file="${files##*|}"
[ "$(wc -l < "$apply_file" | awk '{print $1}')" = '1' ] || {
	printf 'FAIL: local-only resolved drift must refresh runtime once\n' >&2
	exit 1
}
[ ! -s "$cutover_file" ] || {
	printf 'FAIL: local-only resolved drift must not trigger hard cutover\n' >&2
	exit 1
}
grep -q 'verified|Resolved selective targets refreshed without hard cutover' "$TMPDIR/phases.log" || {
	printf 'FAIL: local-only resolved drift must finish in verified phase without hard cutover\n' >&2
	exit 1
}

files="$(run_case repo_resolved 1 1 0 0)"
apply_file="${files%%|*}"
cutover_file="${files##*|}"
[ "$(wc -l < "$apply_file" | awk '{print $1}')" = '1' ] || {
	printf 'FAIL: repo-backed resolved drift must refresh runtime once\n' >&2
	exit 1
}
[ ! -s "$cutover_file" ] || {
	printf 'FAIL: repo-backed resolved drift must not trigger hard cutover\n' >&2
	exit 1
}

files="$(run_case repo_rules_changed 1 0 0 1)"
apply_file="${files%%|*}"
cutover_file="${files##*|}"
[ ! -s "$apply_file" ] || {
	printf 'FAIL: repo rule changes must not use the lightweight resolved-drift refresh path\n' >&2
	exit 1
}
[ "$(wc -l < "$cutover_file" | awk '{print $1}')" = '1' ] || {
	printf 'FAIL: repo rule changes must still trigger a hard cutover\n' >&2
	exit 1
}

printf 'ok\n'
