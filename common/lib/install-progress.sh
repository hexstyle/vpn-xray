#!/bin/sh
# install-progress.sh — shared install-step indicator.
#
# Sourced by both install-router.sh (workstation) and install-platform.sh
# (router). Tracks an N-step plan, prints `[i/N] <name>` to stderr, and
# mirrors state to a JSON file so the router UI can render a live banner.
#
# Public functions:
#   install_progress_init <status_file_path>
#   install_progress_plan <"step 1 name"> <"step 2 name"> ...
#   install_progress_begin <"current step name">
#   install_progress_fail <"cause"> <"how to fix">
#   install_progress_complete
#
# The JSON schema written to the status file:
#   { "schema":1, "state":"running"|"failed"|"complete",
#     "step_index":<int>, "step_total":<int>, "step_name":"...",
#     "started_at":<unix>, "error_cause":"...", "error_fix":"..." }

_VX_PROGRESS_STATUS_FILE=''
_VX_PROGRESS_TOTAL=0
_VX_PROGRESS_INDEX=0
_VX_PROGRESS_NAME=''
_VX_PROGRESS_STARTED=0

_vx_progress_json_escape() {
	# Minimal JSON string escaping for ASCII content. Step names and error
	# strings are author-controlled so we only need to handle quotes and
	# backslashes in practice.
	printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

_vx_progress_write() {
	local state="$1" cause_esc="" fix_esc=""
	[ -n "$_VX_PROGRESS_STATUS_FILE" ] || return 0

	cause_esc="$(_vx_progress_json_escape "${2:-}")"
	fix_esc="$(_vx_progress_json_escape "${3:-}")"
	{
		printf '{'
		printf '"schema":1,'
		printf '"state":"%s",' "$state"
		printf '"step_total":%d,' "$_VX_PROGRESS_TOTAL"
		printf '"step_index":%d,' "$_VX_PROGRESS_INDEX"
		printf '"step_name":"%s",' "$(_vx_progress_json_escape "$_VX_PROGRESS_NAME")"
		printf '"started_at":%s,' "$_VX_PROGRESS_STARTED"
		printf '"error_cause":"%s",' "$cause_esc"
		printf '"error_fix":"%s"' "$fix_esc"
		printf '}\n'
	} > "${_VX_PROGRESS_STATUS_FILE}.tmp" 2>/dev/null || return 0
	mv "${_VX_PROGRESS_STATUS_FILE}.tmp" "$_VX_PROGRESS_STATUS_FILE" 2>/dev/null || true
}

install_progress_init() {
	_VX_PROGRESS_STATUS_FILE="${1:-/tmp/vpn-xray-install-status.json}"
	_VX_PROGRESS_TOTAL=0
	_VX_PROGRESS_INDEX=0
	_VX_PROGRESS_NAME=''
	_VX_PROGRESS_STARTED="$(date +%s 2>/dev/null || echo 0)"
}

_vx_progress_after_update() {
	# Optional post-update hook: callers may define
	# `install_progress_after_update` (e.g. to mirror the JSON to a remote
	# host over SSH) and we will invoke it after every transition. Failures
	# in the hook are non-fatal — progress reporting must never break the
	# install itself.
	command -v install_progress_after_update >/dev/null 2>&1 || return 0
	install_progress_after_update "${1:-running}" 2>/dev/null || true
}

install_progress_plan() {
	local i=0 name=''
	_VX_PROGRESS_TOTAL="$#"
	_VX_PROGRESS_INDEX=0

	printf 'Install plan (%d steps):\n' "$_VX_PROGRESS_TOTAL" >&2
	for name in "$@"; do
		i=$((i + 1))
		printf '  %d. %s\n' "$i" "$name" >&2
	done
	printf '\n' >&2
	_vx_progress_write running
	_vx_progress_after_update running
}

install_progress_begin() {
	_VX_PROGRESS_INDEX=$((_VX_PROGRESS_INDEX + 1))
	_VX_PROGRESS_NAME="$1"
	printf '[%d/%d] %s\n' "$_VX_PROGRESS_INDEX" "$_VX_PROGRESS_TOTAL" "$_VX_PROGRESS_NAME" >&2
	_vx_progress_write running
	_vx_progress_after_update running
}

install_progress_fail() {
	local cause="$1" fix="${2:-}"
	printf '[%d/%d] FAILED: %s\n' "$_VX_PROGRESS_INDEX" "$_VX_PROGRESS_TOTAL" "$cause" >&2
	[ -n "$fix" ] && printf 'Fix: %s\n' "$fix" >&2
	_vx_progress_write failed "$cause" "$fix"
	_vx_progress_after_update failed
	return 1
}

install_progress_complete() {
	_VX_PROGRESS_INDEX="$_VX_PROGRESS_TOTAL"
	_VX_PROGRESS_NAME='complete'
	printf 'Install complete: %d/%d steps OK\n' "$_VX_PROGRESS_TOTAL" "$_VX_PROGRESS_TOTAL" >&2
	_vx_progress_write complete
	_vx_progress_after_update complete
}

# Convenience wrapper: clear any previous status file. Call this once at the
# start of an install so a stale failed state is not shown to the UI.
install_progress_reset() {
	[ -n "$_VX_PROGRESS_STATUS_FILE" ] || return 0
	rm -f "$_VX_PROGRESS_STATUS_FILE" "${_VX_PROGRESS_STATUS_FILE}.tmp" 2>/dev/null || true
}
