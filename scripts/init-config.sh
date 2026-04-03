#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ROUTER_ENV="${ROUTER_ENV:-$ROOT_DIR/config/router.env}"
VPS_ENV="${VPS_ENV:-$ROOT_DIR/config/vps.env}"
ROUTER_TEMPLATE="$ROOT_DIR/config/router.env.example"
VPS_TEMPLATE="$ROOT_DIR/config/vps.env.example"
DEFAULT_SERVER_NAME="${DEFAULT_SERVER_NAME:-www.microsoft.com}"
DEFAULT_ROUTER_PROFILE="${DEFAULT_ROUTER_PROFILE:-gl-mt3000-glinet}"
DEFAULT_VPS_PROFILE="${DEFAULT_VPS_PROFILE:-debian-13}"

mkdir -p "$(dirname "$ROUTER_ENV")" "$(dirname "$VPS_ENV")"
[[ -f "$ROUTER_ENV" ]] || cp "$ROUTER_TEMPLATE" "$ROUTER_ENV"
[[ -f "$VPS_ENV" ]] || cp "$VPS_TEMPLATE" "$VPS_ENV"

python3 - <<'PY' "$ROUTER_ENV" "$VPS_ENV" "$DEFAULT_SERVER_NAME" "$DEFAULT_ROUTER_PROFILE" "$DEFAULT_VPS_PROFILE"
import base64
import os
import secrets
import sys
import uuid
from pathlib import Path

P = 2**255 - 19
A24 = 121665
PLACEHOLDER_PREFIXES = (
    "REPLACE_WITH",
    "CHANGE_ME",
    "CHANGEME",
    "YOUR_",
    "TODO",
)


def is_placeholder(value: str) -> bool:
    if value is None:
        return True
    value = value.strip()
    if not value:
        return True
    if any(value.startswith(prefix) for prefix in PLACEHOLDER_PREFIXES):
        return True
    if "example.invalid" in value:
        return True
    return False


def parse_env(path: Path):
    lines = path.read_text().splitlines()
    values = {}
    order = []
    for line in lines:
        if "=" not in line or line.lstrip().startswith("#"):
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        values[key] = value
        order.append(key)
    return lines, values, order


def set_value(lines, key, value):
    prefix = f"{key}="
    for idx, line in enumerate(lines):
        if line.startswith(prefix):
            lines[idx] = f"{key}={value}"
            return
    lines.append(f"{key}={value}")


def b64url_no_pad(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def host_from_ssh_target(target: str) -> str:
    target = target.strip()
    if not target:
        return ""
    if target.startswith("ssh://"):
        target = target[6:]
    target = target.split("/", 1)[0]
    if "@" in target:
        target = target.split("@", 1)[1]
    if target.startswith("[") and "]" in target:
        return target[1:].split("]", 1)[0]
    return target.split(":", 1)[0]


def clamp_scalar(raw: bytes) -> bytes:
    k = bytearray(raw)
    k[0] &= 248
    k[31] &= 127
    k[31] |= 64
    return bytes(k)


def x25519(scalar_int: int, u: int = 9) -> int:
    x1 = u
    x2, z2 = 1, 0
    x3, z3 = u, 1
    swap = 0
    for t in reversed(range(255)):
        k_t = (scalar_int >> t) & 1
        swap ^= k_t
        if swap:
            x2, x3 = x3, x2
            z2, z3 = z3, z2
        swap = k_t
        a = (x2 + z2) % P
        aa = (a * a) % P
        b = (x2 - z2) % P
        bb = (b * b) % P
        e = (aa - bb) % P
        c = (x3 + z3) % P
        d = (x3 - z3) % P
        da = (d * a) % P
        cb = (c * b) % P
        x3 = ((da + cb) ** 2) % P
        z3 = (x1 * ((da - cb) ** 2)) % P
        x2 = (aa * bb) % P
        z2 = (e * (aa + A24 * e)) % P
    if swap:
        x2, x3 = x3, x2
        z2, z3 = z3, z2
    return (x2 * pow(z2, P - 2, P)) % P


def generate_reality_pair():
    private_raw = clamp_scalar(secrets.token_bytes(32))
    private_int = int.from_bytes(private_raw, "little")
    public_int = x25519(private_int, 9)
    public_raw = public_int.to_bytes(32, "little")
    return b64url_no_pad(private_raw), b64url_no_pad(public_raw)


router_path = Path(sys.argv[1])
vps_path = Path(sys.argv[2])
default_server_name = sys.argv[3]
default_router_profile = sys.argv[4]
default_vps_profile = sys.argv[5]

router_lines, router, _ = parse_env(router_path)
vps_lines, vps, _ = parse_env(vps_path)

if is_placeholder(router.get("ROUTER_PROFILE", "").strip()):
    set_value(router_lines, "ROUTER_PROFILE", default_router_profile)

if is_placeholder(vps.get("VPS_PROFILE", "").strip()):
    set_value(vps_lines, "VPS_PROFILE", default_vps_profile)

router_ssh = router.get("ROUTER_SSH", "").strip()
vps_ssh = vps.get("VPS_SSH", "").strip()

router_host = router.get("ROUTER_HOST", "").strip()
if is_placeholder(router_host) and not is_placeholder(router_ssh):
    router_host = host_from_ssh_target(router_ssh)
    set_value(router_lines, "ROUTER_HOST", router_host)

vps_host = vps.get("VPS_HOST", "").strip()
if is_placeholder(vps_host) and not is_placeholder(vps_ssh):
    vps_host = host_from_ssh_target(vps_ssh)
    set_value(vps_lines, "VPS_HOST", vps_host)

uuid_value = None
for candidate in (router.get("XRAY_UUID"), vps.get("XRAY_UUID")):
    if candidate and not is_placeholder(candidate):
        uuid_value = candidate.strip()
        break
if uuid_value is None:
    uuid_value = str(uuid.uuid4())

server_name = None
for candidate in (router.get("XRAY_SERVER_NAME"), vps.get("XRAY_SERVER_NAME")):
    if candidate and not is_placeholder(candidate):
        server_name = candidate.strip()
        break
if server_name is None:
    server_name = default_server_name

short_id = None
for candidate in (router.get("XRAY_SHORT_ID"), vps.get("XRAY_SHORT_ID")):
    if candidate and not is_placeholder(candidate):
        short_id = candidate.strip()
        break
if short_id is None:
    short_id = secrets.token_hex(8)

public_key = router.get("XRAY_PUBLIC_KEY", "").strip()
private_key = vps.get("XRAY_PRIVATE_KEY", "").strip()

if is_placeholder(private_key) and is_placeholder(public_key):
    private_key, public_key = generate_reality_pair()
elif is_placeholder(private_key) and not is_placeholder(public_key):
    raise SystemExit("XRAY_PUBLIC_KEY is set in router.env but XRAY_PRIVATE_KEY is still missing in vps.env")
elif not is_placeholder(private_key) and is_placeholder(public_key):
    # Derive public key from the private key already present in vps.env.
    raw = base64.urlsafe_b64decode(private_key + "=" * ((4 - len(private_key) % 4) % 4))
    private_int = int.from_bytes(raw, "little")
    public_raw = x25519(private_int, 9).to_bytes(32, "little")
    public_key = b64url_no_pad(public_raw)

set_value(router_lines, "XRAY_UUID", uuid_value)
set_value(vps_lines, "XRAY_UUID", uuid_value)
set_value(router_lines, "XRAY_SERVER_NAME", server_name)
set_value(vps_lines, "XRAY_SERVER_NAME", server_name)
set_value(router_lines, "XRAY_SHORT_ID", short_id)
set_value(vps_lines, "XRAY_SHORT_ID", short_id)
set_value(router_lines, "XRAY_PUBLIC_KEY", public_key)
set_value(vps_lines, "XRAY_PRIVATE_KEY", private_key)

router_xray_server = router.get("XRAY_SERVER", "").strip()
if not is_placeholder(vps_host) and is_placeholder(router_xray_server):
    set_value(router_lines, "XRAY_SERVER", vps_host)

router_path.write_text("\n".join(router_lines) + "\n")
vps_path.write_text("\n".join(vps_lines) + "\n")

print("Generated / synchronized Xray values:")
print(f"  XRAY_UUID={uuid_value}")
print(f"  XRAY_SERVER_NAME={server_name}")
print(f"  XRAY_SHORT_ID={short_id}")
print(f"  XRAY_PUBLIC_KEY={public_key}")
print("  XRAY_PRIVATE_KEY=<written to vps.env>")
PY
