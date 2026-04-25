#!/usr/bin/env python3
"""
Harvest opkg packages for offline router installation.

Downloads all required .ipk files and their transitive dependencies from
OpenWrt 21.02.3 feeds for aarch64_cortex-a53.

Usage:
    ./scripts/harvest-opkg-packages.sh
    # or
    python3 scripts/harvest-opkg-packages.sh

Output:
    routers/gl-mt3000-glinet/packages/opkg/*.ipk
    routers/gl-mt3000-glinet/packages/opkg/MANIFEST
"""

from __future__ import annotations

import gzip
import hashlib
import os
import re
import sys
import urllib.request

ARCH = "aarch64_cortex-a53"
RELEASE = "21.02.3"

FEEDS = {
    "base": f"https://downloads.openwrt.org/releases/{RELEASE}/packages/{ARCH}/base",
    "packages": f"https://downloads.openwrt.org/releases/{RELEASE}/packages/{ARCH}/packages",
}

# Target feed for kernel/core packages (mediatek/mt7622 is the closest
# OpenWrt 21.02.3 target to GL-MT3000's MT7981)
TARGET_BASE = f"https://downloads.openwrt.org/releases/{RELEASE}/targets/mediatek/mt7622/packages"

# Packages required by install-platform.sh
REQUIRED_PACKAGES = [
    "ca-bundle",
    "ca-certificates",
    "curl",
    "unzip",
    "openssh-client",
    "openssh-keygen",
    "sshpass",
    "python3-light",
    "git",
    "git-http",
]

# Packages provided by GL-MT3000 stock firmware — skip these and their deps
# that are also stock. These are always present on the router.
FIRMWARE_PROVIDED = {
    "libc",
    "libgcc1",
    "busybox",
    "kernel",
    "base-files",
}


def download(url: str) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": "harvest-opkg/1.0"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return resp.read()


def parse_packages_index(data: str) -> dict:
    """Parse a Packages file into {name: {field: value, ...}}."""
    packages = {}
    current = {}
    for line in data.splitlines():
        if not line.strip():
            if "Package" in current:
                packages[current["Package"]] = current
            current = {}
            continue
        if line.startswith(" "):
            continue
        if ": " in line:
            key, _, value = line.partition(": ")
            current[key] = value
    if "Package" in current:
        packages[current["Package"]] = current
    return packages


def load_feed(url: str, cache_dir: str) -> dict:
    """Download and parse a Packages.gz feed."""
    name = url.replace("/", "_").replace(":", "")
    cache_path = os.path.join(cache_dir, f"{name}.txt")
    if os.path.exists(cache_path):
        with open(cache_path, "r") as f:
            return parse_packages_index(f.read())

    print(f"  Downloading {url}/Packages.gz ...")
    gz_data = download(f"{url}/Packages.gz")
    text = gzip.decompress(gz_data).decode("utf-8", errors="replace")
    with open(cache_path, "w") as f:
        f.write(text)
    return parse_packages_index(text)


def normalize_dep(dep_str: str) -> str | None:
    """Extract package name from a dependency string like 'libfoo (>=1.0)'."""
    dep_str = dep_str.strip()
    if not dep_str or dep_str.startswith("@"):
        return None
    # Handle alternatives: 'libfoo | libbar' → take first
    dep_str = dep_str.split("|")[0].strip()
    # Remove version constraint: 'libfoo (>=1.0)' → 'libfoo'
    dep_str = re.sub(r"\s*\(.*?\)\s*", "", dep_str).strip()
    # Remove leading '+' (optional marker in some indices)
    dep_str = dep_str.lstrip("+")
    # Remove ABI-version suffixes that are part of dependency, not package name
    # e.g., 'libc:...' → just take the package name
    if ":" in dep_str:
        dep_str = dep_str.split(":")[0]
    return dep_str if dep_str else None


def parse_depends(depends_str: str) -> list[str]:
    """Parse a Depends field into a list of package names."""
    if not depends_str:
        return []
    result = []
    for part in depends_str.split(","):
        name = normalize_dep(part)
        if name:
            result.append(name)
    return result


def resolve_deps(
    package: str,
    all_packages: dict,
    resolved: set,
    order: list,
):
    """Recursively resolve dependencies."""
    if package in resolved or package in FIRMWARE_PROVIDED:
        return
    resolved.add(package)

    info = all_packages.get(package)
    if not info:
        # Package not found in any feed — likely provided by firmware
        return

    deps = parse_depends(info.get("Depends", ""))
    for dep in deps:
        resolve_deps(dep, all_packages, resolved, order)

    order.append(package)


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(8192), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    repo_root = os.path.dirname(script_dir)
    output_dir = os.path.join(
        repo_root, "routers", "gl-mt3000-glinet", "packages", "opkg"
    )
    cache_dir = os.path.join(script_dir, ".harvest-cache")
    os.makedirs(output_dir, exist_ok=True)
    os.makedirs(cache_dir, exist_ok=True)

    print("Loading package indices...")
    all_packages: dict = {}

    # Load target-specific base feed first (lowest priority)
    target_pkgs = load_feed(TARGET_BASE, cache_dir)
    all_packages.update(target_pkgs)

    # Load architecture feeds (higher priority, override target packages)
    for feed_name, feed_url in FEEDS.items():
        pkgs = load_feed(feed_url, cache_dir)
        all_packages.update(pkgs)
        print(f"  {feed_name}: {len(pkgs)} packages")

    print(f"  Total unique packages: {len(all_packages)}")

    # Resolve dependency tree
    print("\nResolving dependencies...")
    resolved: set = set()
    order: list = []
    missing_top_level = []

    for pkg in REQUIRED_PACKAGES:
        if pkg not in all_packages:
            missing_top_level.append(pkg)
            print(f"  WARNING: {pkg} not found in any feed")
        else:
            resolve_deps(pkg, all_packages, resolved, order)

    if missing_top_level:
        print(
            f"\n  {len(missing_top_level)} top-level packages not found: "
            f"{', '.join(missing_top_level)}"
        )

    # Filter to only packages that are in the feed (skip firmware-provided)
    downloadable = [p for p in order if p in all_packages and p not in FIRMWARE_PROVIDED]
    print(f"  Resolved {len(downloadable)} packages to download:")
    for pkg in downloadable:
        info = all_packages[pkg]
        print(f"    {pkg} ({info.get('Version', '?')})")

    # Download packages
    print("\nDownloading packages...")
    manifest_lines = []
    total_size = 0

    for pkg in downloadable:
        info = all_packages[pkg]
        filename = info.get("Filename", "")
        if not filename:
            print(f"  WARNING: {pkg} has no Filename field, skipping")
            continue

        basename = os.path.basename(filename)
        target_path = os.path.join(output_dir, basename)
        expected_sha = info.get("SHA256sum", "")

        # Determine which feed URL to use
        feed_url = None
        for feed_name, furl in FEEDS.items():
            feed_pkgs = load_feed(furl, cache_dir)
            if pkg in feed_pkgs:
                feed_url = furl
                break
        if not feed_url:
            feed_url = TARGET_BASE

        if os.path.exists(target_path):
            if expected_sha and sha256_file(target_path) == expected_sha:
                print(f"  {basename} (cached, verified)")
                manifest_lines.append(f"{pkg}\t{basename}\t{expected_sha}")
                total_size += os.path.getsize(target_path)
                continue
            else:
                os.remove(target_path)

        url = f"{feed_url}/{filename}"
        print(f"  Downloading {basename} ...")
        try:
            data = download(url)
        except Exception as e:
            print(f"  ERROR downloading {url}: {e}")
            continue

        with open(target_path, "wb") as f:
            f.write(data)

        if expected_sha:
            got_sha = sha256_file(target_path)
            if got_sha != expected_sha:
                print(f"  WARNING: SHA256 mismatch for {basename}")
                print(f"    expected: {expected_sha}")
                print(f"    got:      {got_sha}")

        manifest_lines.append(f"{pkg}\t{basename}\t{expected_sha}")
        total_size += len(data)

    # Write manifest
    manifest_path = os.path.join(output_dir, "MANIFEST")
    with open(manifest_path, "w") as f:
        f.write("# Package\tFilename\tSHA256\n")
        for line in manifest_lines:
            f.write(line + "\n")

    total_kb = total_size / 1024
    print(f"\nDone. {len(manifest_lines)} packages ({total_kb:.0f} KB) in {output_dir}")
    print(f"Manifest written to {manifest_path}")


if __name__ == "__main__":
    main()
