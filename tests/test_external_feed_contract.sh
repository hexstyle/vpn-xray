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

grep -q "option external_source_enabled" "$CONFIG_TEMPLATE" \
	|| fail "router-rules config template must expose external_source_enabled"
grep -q "option external_source_url" "$CONFIG_TEMPLATE" \
	|| fail "router-rules config template must expose external_source_url"
grep -q "option external_source_interval" "$CONFIG_TEMPLATE" \
	|| fail "router-rules config template must expose external_source_interval"

grep -q "cp \"\$COMMON_DIR/files/router-rules-external.py\"" "$INSTALL_PLATFORM" \
	|| fail "install-platform must copy the external generator to the router"
grep -q "python3" "$INSTALL_PLATFORM" \
	|| fail "install-platform must provision python3 for the external generator"
grep -q "resolve_pkg_via_openwrt_fallback()" "$INSTALL_PLATFORM" \
	|| fail "install-platform must resolve fallback package dependencies recursively"
grep -q "python3_supports_external_fetcher()" "$INSTALL_PLATFORM" \
	|| fail "install-platform must verify the Python runtime can import the external fetcher modules"
grep -q "RULES_EXTERNAL_SOURCE_ENABLED" "$INSTALL_ROUTER" \
	|| fail "install-router must pass external source settings to install-platform"

grep -q "external_source_enabled()" "$ROUTER_RULES_FILE" \
	|| fail "router-rules must expose external_source_enabled()"
grep -q "preview_external_source_internal()" "$ROUTER_RULES_FILE" \
	|| fail "router-rules must implement preview_external_source_internal()"
grep -q "refresh_external_source_internal()" "$ROUTER_RULES_FILE" \
	|| fail "router-rules must implement refresh_external_source_internal()"
grep -q "preview-external-source" "$ROUTER_RULES_FILE" \
	|| fail "router-rules must expose preview-external-source command"

grep -q "preview_external_source)" "$CGI_FILE" \
	|| fail "xray-rules.cgi must support preview_external_source action"
grep -q "sync_external_source)" "$CGI_FILE" \
	|| fail "xray-rules.cgi must support sync_external_source action"
grep -q "external_source_enabled" "$CGI_FILE" \
	|| fail "xray-rules.cgi must persist external source settings"
grep -q 'ROUTER_RULES_LOCK_WAIT="\$RULES_EXTERNAL_LOCK_WAIT"' "$CGI_FILE" \
	|| fail "xray-rules.cgi must let external preview/sync wait for the router-rules lock"

grep -q 'id="rulesExternalEnabled"' "$HTML_FILE" \
	|| fail "xray.html must render the external source toggle"
grep -q 'id="rulesExternalUrl"' "$HTML_FILE" \
	|| fail "xray.html must render the external source URL field"
grep -q 'id="rulesExternalPreviewBtn"' "$HTML_FILE" \
	|| fail "xray.html must render the external source preview button"
grep -q 'id="rulesExternalRunBtn"' "$HTML_FILE" \
	|| fail "xray.html must render the external source run button"
grep -q "external_source_enabled" "$HTML_FILE" \
	|| fail "xray.html must submit external source settings"

printf 'ok\n'
