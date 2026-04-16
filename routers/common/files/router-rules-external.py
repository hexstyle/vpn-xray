#!/usr/bin/env python3

import argparse
import html
import ipaddress
import json
import re
import sys
import urllib.parse
import urllib.request
from typing import Callable, Iterator, List, Optional, Sequence, Set


FetchText = Callable[[str, float], str]

URL_PATTERN = re.compile(r"https?://[^\s<>'\"`]+", re.IGNORECASE)
IPV4_PATTERN = re.compile(
    r"\b(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)"
    r"(?:\.(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}"
    r"(?:/(?:3[0-2]|[12]?\d))?\b"
)
DOMAIN_PATTERN = re.compile(
    r"(?<![a-z0-9@/._-])(?:\*\.)?(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}\b",
    re.IGNORECASE,
)
MICROSOFT_JSON_PATTERN = re.compile(
    r"https://download\.microsoft\.com/[^\"'<> ]+\.json",
    re.IGNORECASE,
)
USER_AGENT = "vpn-xray-router-rules/1.0"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Fetch and normalize external domain/IP targets for router-rules."
    )
    source = parser.add_mutually_exclusive_group()
    source.add_argument("--input-file", help="Read source payload from a local file.")
    source.add_argument(
        "--url",
        action="append",
        help="Fetch source payload from an HTTP(S) URL. May be repeated or contain whitespace/comma-separated URLs.",
    )
    parser.add_argument(
        "--source-url",
        help="Hint the original source URL when using --input-file or stdin.",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=45.0,
        help="Network timeout in seconds for URL fetches.",
    )
    return parser.parse_args()


def default_fetch_text(url: str, timeout: float = 45.0) -> str:
    request = urllib.request.Request(
        url,
        headers={"User-Agent": USER_AGENT, "Accept": "*/*"},
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        charset = response.headers.get_content_charset() or "utf-8"
        return response.read().decode(charset, errors="ignore")


def read_payload_from_file(path: str) -> str:
    with open(path, "r", encoding="utf-8", errors="ignore") as handle:
        return handle.read()


def parse_json_payload(payload: str) -> Optional[object]:
    try:
        return json.loads(payload)
    except json.JSONDecodeError:
        return None


def expand_url_inputs(values: Optional[Sequence[str]]) -> List[str]:
    urls: List[str] = []
    for raw in values or []:
        for item in re.split(r"[\s,]+", raw.strip()):
            if item:
                urls.append(item)
    return urls


def normalize_token(value: str) -> str:
    token = value.strip().strip("()[]{}<>,;:'\"`")
    token = token.lower().rstrip(".")
    if token.startswith("*."):
        token = token[2:]
    return token


def normalize_ip_or_cidr(value: str) -> Optional[str]:
    token = normalize_token(value)
    if not token:
        return None
    try:
        if "/" in token:
            return str(ipaddress.ip_network(token, strict=False))
        return str(ipaddress.ip_address(token))
    except ValueError:
        return None


def normalize_ipv4_target(value: str) -> Optional[str]:
    normalized = normalize_ip_or_cidr(value)
    if not normalized or ":" in normalized:
        return None
    return normalized


def is_valid_domain(value: str) -> bool:
    if not value or "." not in value or "@" in value:
        return False
    if len(value) > 253:
        return False
    labels = value.split(".")
    if len(labels) < 2:
        return False
    for label in labels:
        if not label or len(label) > 63:
            return False
        if label.startswith("-") or label.endswith("-"):
            return False
        if not re.fullmatch(r"[a-z0-9-]+", label):
            return False
    return True


def normalize_domain(value: str) -> Optional[str]:
    token = normalize_token(value)
    if not token:
        return None
    if normalize_ip_or_cidr(token) is not None:
        return None
    if not is_valid_domain(token):
        return None
    return token


def sort_targets(values: Set[str]) -> List[str]:
    def key(value: str) -> tuple:
        normalized_ipv4 = normalize_ipv4_target(value)
        if normalized_ipv4:
            if "/" in normalized_ipv4:
                network = ipaddress.ip_network(normalized_ipv4, strict=False)
                return (0, int(network.network_address), network.prefixlen, "")
            address = ipaddress.ip_address(normalized_ipv4)
            return (0, int(address), 32, "")
        return (1, 0, 0, value)

    return sorted(values, key=key)


def iter_json_strings(value: object) -> Iterator[str]:
    if isinstance(value, str):
        yield value
        return
    if isinstance(value, dict):
        for item in value.values():
            yield from iter_json_strings(item)
        return
    if isinstance(value, list):
        for item in value:
            yield from iter_json_strings(item)


def iter_text_fragments(payload: str) -> Iterator[str]:
    yield payload
    parsed = parse_json_payload(payload)
    if parsed is None:
        return
    yield from iter_json_strings(parsed)


def parsed_url(url: Optional[str]) -> urllib.parse.ParseResult:
    return urllib.parse.urlparse(url or "")


def is_microsoft_download_details_url(url: Optional[str]) -> bool:
    parsed = parsed_url(url)
    return parsed.netloc.endswith("microsoft.com") and parsed.path.lower().endswith("/download/details.aspx")


def is_microsoft_service_tags_json_url(url: Optional[str]) -> bool:
    parsed = parsed_url(url)
    return parsed.netloc.endswith("download.microsoft.com") and parsed.path.lower().endswith(".json")


def is_cloudflare_ipv4_url(url: Optional[str]) -> bool:
    parsed = parsed_url(url)
    return parsed.netloc.endswith("cloudflare.com") and parsed.path.rstrip("/").lower().endswith("/ips-v4")


def is_google_goog_json_url(url: Optional[str]) -> bool:
    parsed = parsed_url(url)
    return parsed.netloc == "www.gstatic.com" and parsed.path.lower().endswith("/ipranges/goog.json")


def is_aws_ip_ranges_url(url: Optional[str]) -> bool:
    parsed = parsed_url(url)
    return parsed.netloc == "ip-ranges.amazonaws.com" and parsed.path.lower().endswith("/ip-ranges.json")


def extract_targets_from_plain_ipv4_list(payload: str) -> List[str]:
    targets: Set[str] = set()
    for line in payload.splitlines():
        line = normalize_token(line)
        if not line or line.startswith("#"):
            continue
        normalized = normalize_ipv4_target(line)
        if normalized:
            targets.add(normalized)
    return sort_targets(targets)


def extract_targets_from_google_json(payload: str) -> List[str]:
    parsed = parse_json_payload(payload)
    if not isinstance(parsed, dict):
        raise ValueError("Google IP ranges payload is not valid JSON.")
    targets: Set[str] = set()
    for item in parsed.get("prefixes", []):
        if not isinstance(item, dict):
            continue
        normalized = normalize_ipv4_target(str(item.get("ipv4Prefix", "")))
        if normalized:
            targets.add(normalized)
    return sort_targets(targets)


def extract_targets_from_aws_json(payload: str) -> List[str]:
    parsed = parse_json_payload(payload)
    if not isinstance(parsed, dict):
        raise ValueError("AWS IP ranges payload is not valid JSON.")
    targets: Set[str] = set()
    for item in parsed.get("prefixes", []):
        if not isinstance(item, dict):
            continue
        normalized = normalize_ipv4_target(str(item.get("ip_prefix", "")))
        if normalized:
            targets.add(normalized)
    return sort_targets(targets)


def extract_targets_from_microsoft_json(payload: str) -> List[str]:
    parsed = parse_json_payload(payload)
    if not isinstance(parsed, dict):
        raise ValueError("Microsoft service tags payload is not valid JSON.")
    targets: Set[str] = set()
    for item in parsed.get("values", []):
        if not isinstance(item, dict):
            continue
        properties = item.get("properties", {})
        if not isinstance(properties, dict):
            continue
        for prefix in properties.get("addressPrefixes", []):
            normalized = normalize_ipv4_target(str(prefix))
            if normalized:
                targets.add(normalized)
    return sort_targets(targets)


def extract_known_json_targets(payload: str) -> Optional[List[str]]:
    parsed = parse_json_payload(payload)
    if not isinstance(parsed, dict):
        return None
    prefixes = parsed.get("prefixes")
    if isinstance(prefixes, list):
        if any(isinstance(item, dict) and "ipv4Prefix" in item for item in prefixes):
            return extract_targets_from_google_json(payload)
        if any(isinstance(item, dict) and "ip_prefix" in item for item in prefixes):
            return extract_targets_from_aws_json(payload)
    values = parsed.get("values")
    if isinstance(values, list) and any(
        isinstance(item, dict)
        and isinstance(item.get("properties"), dict)
        and "addressPrefixes" in item.get("properties", {})
        for item in values
    ):
        return extract_targets_from_microsoft_json(payload)
    return None


def extract_targets_from_generic_text(payload: str) -> List[str]:
    targets: Set[str] = set()

    for fragment in iter_text_fragments(payload):
        for match in URL_PATTERN.finditer(fragment):
            host = urllib.parse.urlparse(match.group(0)).hostname or ""
            normalized = normalize_ipv4_target(host) or normalize_domain(host)
            if normalized:
                targets.add(normalized)

        for match in IPV4_PATTERN.finditer(fragment):
            normalized = normalize_ipv4_target(match.group(0))
            if normalized:
                targets.add(normalized)

        for match in DOMAIN_PATTERN.finditer(fragment):
            normalized = normalize_domain(match.group(0))
            if normalized:
                targets.add(normalized)

    return sort_targets(targets)


def extract_microsoft_download_json_url(payload: str) -> Optional[str]:
    matches = [html.unescape(match) for match in MICROSOFT_JSON_PATTERN.findall(payload)]
    if not matches:
        return None
    for match in matches:
        if "servicetags_public_" in match.lower():
            return match
    return matches[0]


def extract_targets(payload: str, source_url: Optional[str] = None, fetch_text: FetchText = default_fetch_text, timeout: float = 45.0) -> List[str]:
    if source_url and is_microsoft_download_details_url(source_url):
        download_url = extract_microsoft_download_json_url(payload)
        if not download_url:
            raise ValueError("Microsoft download page did not contain a service tags JSON link.")
        downloaded_payload = fetch_text(download_url, timeout)
        return extract_targets(downloaded_payload, source_url=download_url, fetch_text=fetch_text, timeout=timeout)

    if source_url and is_cloudflare_ipv4_url(source_url):
        return extract_targets_from_plain_ipv4_list(payload)
    if source_url and is_google_goog_json_url(source_url):
        return extract_targets_from_google_json(payload)
    if source_url and is_aws_ip_ranges_url(source_url):
        return extract_targets_from_aws_json(payload)
    if source_url and is_microsoft_service_tags_json_url(source_url):
        return extract_targets_from_microsoft_json(payload)

    known_targets = extract_known_json_targets(payload)
    if known_targets is not None:
        return known_targets
    return extract_targets_from_generic_text(payload)


def extract_targets_from_url(url: str, fetch_text: FetchText = default_fetch_text, timeout: float = 45.0) -> List[str]:
    payload = fetch_text(url, timeout)
    return extract_targets(payload, source_url=url, fetch_text=fetch_text, timeout=timeout)


def main() -> int:
    args = parse_args()
    targets: Set[str] = set()
    source_urls = expand_url_inputs(args.url)

    if source_urls:
        for url in source_urls:
            targets.update(extract_targets_from_url(url, timeout=args.timeout))
    elif args.input_file:
        payload = read_payload_from_file(args.input_file)
        targets.update(extract_targets(payload, source_url=args.source_url, timeout=args.timeout))
    else:
        targets.update(extract_targets(sys.stdin.read(), source_url=args.source_url, timeout=args.timeout))

    for line in sort_targets(targets):
        print(line)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
