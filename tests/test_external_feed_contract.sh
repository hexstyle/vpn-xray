#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
ROUTER_RULES_FILE="$ROOT/routers/common/files/router-rules"
CONFIG_TEMPLATE="$ROOT/routers/common/files/router-rules.config.template"
INSTALL_PLATFORM="$ROOT/routers/gl-mt3000-glinet/install-platform.sh"
INSTALL_ROUTER="$ROOT/routers/gl-mt3000-glinet/install-router.sh"
CGI_FILE="$ROOT/routers/gl-mt3000-glinet/files/xray-rules.cgi"
HTML_FILE="$ROOT/routers/gl-mt3000-glinet/files/xray.html"
PYTHON_GENERATOR="$ROOT/routers/common/files/router-rules-external.py"

fail() {
	printf 'FAIL: %s\n' "$1" >&2
	exit 1
}

[ -f "$PYTHON_GENERATOR" ] || fail "router-rules external generator script is missing"
grep -q -- "--collapse" "$PYTHON_GENERATOR" \
	|| fail "router-rules external generator must support collapsing IPv4 targets for the runtime-effective ruleset"

grep -q "option external_source_enabled" "$CONFIG_TEMPLATE" \
	|| fail "router-rules config template must expose external_source_enabled"
grep -q "option external_source_url" "$CONFIG_TEMPLATE" \
	|| fail "router-rules config template must expose external_source_url"
grep -q "option external_source_interval" "$CONFIG_TEMPLATE" \
	|| fail "router-rules config template must expose external_source_interval"

grep -qE '(cp|copy_if_changed) "\$COMMON_DIR/files/router-rules-external.py"' "$INSTALL_PLATFORM" \
	|| fail "install-platform must copy the external generator to the router"
grep -q "python3" "$INSTALL_PLATFORM" \
	|| fail "install-platform must provision python3 for the external generator"
grep -q "resolve_pkg_via_openwrt_fallback()" "$INSTALL_PLATFORM" \
	|| fail "install-platform must resolve fallback package dependencies recursively"
grep -q "python3_supports_external_fetcher()" "$INSTALL_PLATFORM" \
	|| fail "install-platform must verify the Python runtime can import the external fetcher modules"
grep -q "effective_external_source_enabled()" "$INSTALL_PLATFORM" \
	|| fail "install-platform must preserve existing external source enable state on router updates"
grep -q "exec </dev/null" "$INSTALL_PLATFORM" \
	|| fail "install-platform must close remote stdin before starting long-lived services so SSH deploys can finish cleanly"
awk '
	/\/usr\/bin\/router-rules sync-apply-xray/ && !apply_line { apply_line = NR }
	/\/etc\/init\.d\/router-rules-sync start/ && !start_line { start_line = NR }
	END { exit !(apply_line && start_line && apply_line < start_line) }
' "$INSTALL_PLATFORM" \
	|| fail "install-platform must apply the ruleset before starting the background sync loop to avoid lock contention during deploys"
grep -q "/etc/init.d/router-rules-sync stop" "$INSTALL_PLATFORM" \
	|| fail "install-platform must stop the existing background sync loop before applying a new ruleset during deploys"
grep -q "current_router_external_source_config()" "$INSTALL_ROUTER" \
	|| fail "install-router must preserve the router's current external source config on updates"
grep -q "current_vps_xray_meta()" "$INSTALL_ROUTER" \
	|| fail "install-router must be able to sync the live VPS Reality profile during router updates"
awk '
	/current_vps_meta="\$\(current_vps_xray_meta 2>\/dev\/null \|\| true\)"/ && !meta_line { meta_line = NR }
	/^require_vars[[:space:]]*\\/ && !require_line { require_line = NR }
	END { exit !(meta_line && require_line && meta_line < require_line) }
' "$INSTALL_ROUTER" \
	|| fail "install-router must sync live VPS Reality metadata before requiring XRAY variables"
grep -q "RULES_EXTERNAL_SOURCE_ENABLED" "$INSTALL_ROUTER" \
	|| fail "install-router must pass external source settings to install-platform"
grep -q "exec </dev/null" "$INSTALL_ROUTER" \
	|| fail "install-router must close remote stdin before starting long-lived services so SSH updates can finish cleanly"
grep -q "nohup sh -c" "$INSTALL_ROUTER" \
	|| fail "install-router must bring long-lived router services back asynchronously after the blocking rules apply step"
grep -q "wait_for_router_runtime_ready()" "$INSTALL_ROUTER" \
	|| fail "install-router must wait for the router runtime to report ready before exiting"

grep -q "external_source_enabled()" "$ROUTER_RULES_FILE" \
	|| fail "router-rules must expose external_source_enabled()"
grep -q "preview_external_source_internal()" "$ROUTER_RULES_FILE" \
	|| fail "router-rules must implement preview_external_source_internal()"
grep -q "refresh_external_sources_internal()" "$ROUTER_RULES_FILE" \
	|| fail "router-rules must implement refresh_external_sources_internal()"
grep -q "compose_effective_rules_internal()" "$ROUTER_RULES_FILE" \
	|| fail "router-rules must build an effective merged rules file from editable and managed sources"
grep -q -- "--collapse --input-file" "$ROUTER_RULES_FILE" \
	|| fail "router-rules must collapse managed IPv4 targets before applying the runtime-effective ruleset"
grep -q "refresh_resolved_runtime_internal()" "$ROUTER_RULES_FILE" \
	|| fail "router-rules must refresh resolved selective targets without forcing a hard cutover every time"
grep -q "read_external_source_internal()" "$ROUTER_RULES_FILE" \
	|| fail "router-rules must expose read_external_source_internal() for source file viewing"
grep -q "external_sources_json()" "$ROUTER_RULES_FILE" \
	|| fail "router-rules status must emit per-source metadata"
grep -q "preview-external-source" "$ROUTER_RULES_FILE" \
	|| fail "router-rules must expose preview-external-source command"
grep -q "read-external-source" "$ROUTER_RULES_FILE" \
	|| fail "router-rules must expose read-external-source command"
grep -q "status_include_rules_text()" "$ROUTER_RULES_FILE" \
	|| fail "router-rules must support lightweight status responses without full rules_text"

grep -q "preview_external_source)" "$CGI_FILE" \
	|| fail "xray-rules.cgi must support preview_external_source action"
grep -q "read_external_source)" "$CGI_FILE" \
	|| fail "xray-rules.cgi must support read_external_source action"
grep -q "sync_external_source)" "$CGI_FILE" \
	|| fail "xray-rules.cgi must support sync_external_source action"
grep -q "external_source_enabled_ids" "$CGI_FILE" \
	|| fail "xray-rules.cgi must persist per-source external enable flags"
grep -q 'ROUTER_RULES_LOCK_WAIT="\$RULES_EXTERNAL_LOCK_WAIT"' "$CGI_FILE" \
	|| fail "xray-rules.cgi must let external preview/sync wait for the router-rules lock"
grep -q "include_rules_text" "$CGI_FILE" \
	|| fail "xray-rules.cgi status must be able to omit or include the full rules_text payload"

grep -q 'id="rulesExternalSources"' "$HTML_FILE" \
	|| fail "xray.html must render the managed external source list"
grep -q 'id="rulesExternalRunBtn"' "$HTML_FILE" \
	|| fail "xray.html must render the external source run button"
grep -q 'id="rulesLoadTextBtn"' "$HTML_FILE" \
	|| fail "xray.html must render a button for loading the full rules list on demand"
grep -q 'id="rulesTextModal"' "$HTML_FILE" \
	|| fail "xray.html must render a popup/modal for viewing managed source contents"
grep -q "external_source_enabled_ids" "$HTML_FILE" \
	|| fail "xray.html must submit per-source external source settings"

printf 'ok\n'
