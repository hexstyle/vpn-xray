#!/bin/sh

set -eu

# DIAGNOSTIC-TREE node R (template rendering): a rendered artifact must
# never carry an unsubstituted ${PLACEHOLDER}. Two production outages came
# from this class — a literal ${XRAY_WS_PATH} in the VPS config (silently
# broke the tunnel) and an empty ${VPS_TLS_CERT_PATH} whose dirname "."
# made a recursive chown corrupt /root. This test enforces R.1 and R.3
# statically so those regressions fail CI instead of the field.

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
PROFILE="$ROOT/routers/gl-mt3000-glinet"
CONFIG_TEMPLATE="$ROOT/vps/debian-13/files/xray-vps-config.template.json"
REMOTE_INSTALL="$ROOT/vps/debian-13/files/install-vps.remote.sh"
CGI="$PROFILE/files/xray-vps.cgi"

fail() {
	printf 'FAIL: %s\n' "$1" >&2
	exit 1
}

# R.1: every ${...} placeholder in the VPS server-config template must be
# covered by render_vps_profile_template's sed substitution list. A missing
# key ships the literal placeholder into the live config.
placeholders="$(grep -oE '\$\{[A-Z_][A-Z0-9_]*\}' "$CONFIG_TEMPLATE" \
	| sed -e 's/^\${//' -e 's/}$//' | sort -u)"

sed_keys="$(sed -n '/^render_vps_profile_template()/,/^}/p' "$CGI" \
	| grep -oE 's\|\\\$\{[A-Z_][A-Z0-9_]*\}' \
	| grep -oE '[A-Z_][A-Z0-9_]*' | sort -u)"

for key in $placeholders; do
	printf '%s\n' "$sed_keys" | grep -qx "$key" \
		|| fail "VPS config template placeholder \${$key} is not substituted by render_vps_profile_template (node R.1) — it would ship literally into the live config"
done

# R.2 guardrails: the path placeholders that feed recursive chown must be
# in the substitution set (an empty one collapses dirname to ".").
for key in VPS_TLS_CERT_PATH VPS_TLS_KEY_PATH; do
	printf '%s\n' "$sed_keys" | grep -qx "$key" \
		|| fail "render_vps_profile_template must substitute \${$key} (node R.2 / 6.5) — an empty TLS path makes chown -R hit the CWD"
done

# R.3: a literal ${VAR} token in a comment of a templated shell script is
# still substituted by the installer's naive Python renderer and crashes
# on an unknown key (KeyError). Comments in the rendered remote script must
# not contain dollar-brace tokens.
if grep -nE '^[[:space:]]*#.*\$\{[A-Z_][A-Z0-9_]*\}' "$REMOTE_INSTALL" >/dev/null 2>&1; then
	grep -nE '^[[:space:]]*#.*\$\{[A-Z_][A-Z0-9_]*\}' "$REMOTE_INSTALL" >&2
	fail "install-vps.remote.sh has a \${...} token in a comment (node R.3) — the installer renderer substitutes it and KeyErrors on an unknown var"
fi

# The certs step must guard against a non-absolute cert path before any
# recursive chown (meta-rules 6/7, node 6.5).
grep -q 'case "$TLS_CERT_PATH" in' "$REMOTE_INSTALL" \
	|| fail "step_certs must validate TLS_CERT_PATH is absolute before chown -R (node 6.5)"

# The config step must reject a staged config that still holds a placeholder
# (node 6.6 guard a).
grep -q "grep -q '\[\$\]\[{\]\[A-Z_\]\[A-Z0-9_\]\*\[}\]' \"\$staged\"" "$REMOTE_INSTALL" \
	|| fail "step_config must reject a staged config containing an unsubstituted placeholder (node 6.6)"

printf 'ok\n'
