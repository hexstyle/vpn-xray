#!/bin/sh
# Profile template assembly and placeholder rendering; sourced by installers.

vps_template_source() {
  local input="$1" runtime
  if [ "${input##*/}" = install-vps.remote.sh ]; then
    runtime="${input%/*}/install-vps-runtime.remote.sh"
    [ -s "$input" ] && [ -s "$runtime" ] || {
      echo 'VPS install source part missing or empty' >&2; return 1;
    }
    cat "$input" "$runtime"
  else
    cat "$input"
  fi
}

render_template() {
  local input="$1"
  local output="$2"
  local assembled rc=0
  assembled="$(mktemp)" || return 1
  vps_template_source "$input" > "$assembled" || {
    rm -f "$assembled" "$output"; return 1;
  }
  python3 - "$input" "$output" "$assembled" <<'PY' || rc=$?
import json, os, pathlib, re, sys
template_path = pathlib.Path(sys.argv[1])
template = pathlib.Path(sys.argv[3]).read_text()
def repl(match):
    key = match.group(1)
    try:
        value = os.environ[key]
        return json.dumps(value, ensure_ascii=False)[1:-1] if key == 'XRAY_WS_PATH' else value
    except KeyError:
        raise SystemExit(f"Template {template_path} requires env variable {key}, but it is missing")
rendered = re.sub(r"\$\{([A-Z0-9_]+)\}", repl, template)
if re.search(r"\$\{[A-Z0-9_]+\}", rendered):
    raise SystemExit(f"Template {template_path} has unresolved placeholders")
pathlib.Path(sys.argv[2]).write_text(rendered)
PY
  rm -f "$assembled"
  [ "$rc" -eq 0 ] || rm -f "$output"
  return "$rc"
}
