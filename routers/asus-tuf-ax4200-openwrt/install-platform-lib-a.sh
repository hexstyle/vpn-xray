#!/bin/sh
# install-platform-lib-a.sh (asus-tuf-ax4200-openwrt) — package management, OpenWrt fallback,
# and router-rules config helpers for install-platform.sh. Sourced via
# $SELF_DIR early in install-platform.sh; defines functions only.
# Profile-specific by design (package dir, fallback release differ per profile).

copy_if_changed() {
	local src="$1" dst="$2"
	if [ -f "$dst" ]; then
		local src_h dst_h
		src_h="$(sha256_file "$src")"
		dst_h="$(sha256_file "$dst")"
		if [ "$src_h" = "$dst_h" ]; then
			return 0
		fi
	fi
	cp "$src" "$dst"
	FILES_CHANGED=1
}

uci_set_if_different() {
	local key="$1" value="$2"
	local current
	current="$(uci -q get "$key" 2>/dev/null || true)"
	[ "$current" = "$value" ] && return 0
	uci set "${key}=${value}"
}

info() {
	printf '%s\n' "$*"
}

warn() {
	printf 'WARNING: %s\n' "$*" >&2
}

fail() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

have_cmd() {
	command -v "$1" >/dev/null 2>&1
}

require_cmd() {
	have_cmd "$1" || fail "Missing required router command: $1"
}

pkg_installed_exact() {
	local package="$1"

	opkg list-installed 2>/dev/null | awk -v pkg="$package" '$1 == pkg { found = 1 } END { exit(found ? 0 : 1) }'
}

ensure_pkg_installed() {
	local package="$1"

	pkg_installed_exact "$package" && return 0
	install_bundled_opkg_single "$package" && return 0
	if [ "${VPN_XRAY_ALLOW_NETWORK_PKG:-0}" = "1" ]; then
		opkg install "$package" >/dev/null 2>&1 && pkg_installed_exact "$package" && return 0
	fi
	fail "Could not install package '$package' from the offline bundle. Add it to routers/asus-tuf-ax4200-openwrt/packages/opkg/ or set VPN_XRAY_ALLOW_NETWORK_PKG=1."
}

ensure_cmd_via_package() {
	local cmd="$1"
	local package="$2"

	have_cmd "$cmd" && return 0
	ensure_pkg_installed "$package"
	have_cmd "$cmd" || fail "Command '$cmd' is still unavailable after installing package '$package'."
}

try_pkg_install() {
	local package="$1"
	local purpose="$2"

	pkg_installed_exact "$package" && return 0
	install_bundled_opkg_single "$package" 2>/dev/null && return 0
	if [ "${VPN_XRAY_ALLOW_NETWORK_PKG:-0}" = "1" ]; then
		opkg install "$package" >/dev/null 2>&1 && pkg_installed_exact "$package" && return 0
	fi
	warn "Could not install optional package '$package' for $purpose. The core VPN path can still work, but the related feature may stay unavailable."
	return 1
}

install_bundled_opkg_single() {
	local package="$1"
	local opkg_bundle_dir="${BUNDLED_PAYLOAD_DIR}/opkg"
	local bundled

	[ -d "$opkg_bundle_dir" ] || return 1
	bundled="$(find "$opkg_bundle_dir" -name "${package}_*.ipk" 2>/dev/null | head -1)"
	[ -n "$bundled" ] && [ -f "$bundled" ] || return 1
	opkg install "$bundled" >/dev/null 2>&1
}

install_bundled_opkg_packages() {
	local opkg_bundle_dir="${BUNDLED_PAYLOAD_DIR}/opkg"
	local ipk_list

	[ -d "$opkg_bundle_dir" ] || return 1
	ipk_list="$(find "$opkg_bundle_dir" -name '*.ipk' 2>/dev/null | sort)"
	[ -n "$ipk_list" ] || return 1

	info "Installing packages from offline bundle..."
	# shellcheck disable=SC2086
	opkg install $ipk_list >/tmp/vpn-xray-bundled-opkg.log 2>&1 || {
		warn "Bundled opkg install had errors (some may be harmless version conflicts). See /tmp/vpn-xray-bundled-opkg.log."
		return 0
	}
}

router_package_arch() {
	local arch=''

	if [ -f /etc/openwrt_release ]; then
		# shellcheck disable=SC1091
		. /etc/openwrt_release
		arch="${DISTRIB_ARCH:-}"
	fi

	if [ -z "$arch" ]; then
		arch="$(opkg print-architecture 2>/dev/null | awk '/^arch / && $2 != "all" && $2 != "noarch" {if ($3 > best) {best=$3; arch=$2}} END {print arch}')"
	fi

	[ -n "$arch" ] || return 1
	printf '%s\n' "$arch"
}

openwrt_target_path() {
	local target=''

	if [ -f /etc/openwrt_release ]; then
		# shellcheck disable=SC1091
		. /etc/openwrt_release
		target="${DISTRIB_TARGET:-}"
	fi

	[ -n "$target" ] || return 1
	printf '%s\n' "$target"
}

openwrt_fallback_repo_url() {
	local feed="$1"
	local arch target

	arch="$(router_package_arch)" || return 1
	case "$feed" in
		base)
			target="$(openwrt_target_path)" || return 1
			printf 'https://downloads.openwrt.org/releases/%s/targets/%s/packages\n' "$OPENWRT_FALLBACK_RELEASE" "$target"
			;;
		packages)
			printf 'https://downloads.openwrt.org/releases/%s/packages/%s/packages\n' "$OPENWRT_FALLBACK_RELEASE" "$arch"
			;;
		*)
			return 1
			;;
	esac
}

openwrt_fallback_index_path() {
	local feed="$1"
	local arch target index_suffix

	arch="$(router_package_arch)" || return 1
	case "$feed" in
		base)
			target="$(openwrt_target_path)" || return 1
			index_suffix="$(printf '%s\n' "$target" | tr '/' '-')"
			;;
		packages)
			index_suffix="$arch"
			;;
		*)
			return 1
			;;
	esac
	printf '%s/openwrt-%s-%s.gz\n' "$DOWNLOAD_DIR" "$feed" "$index_suffix"
}

openwrt_fallback_package_metadata() {
	local package="$1"
	local metadata_path feed repo_url index_path raw filename depends

	metadata_path="${DOWNLOAD_DIR}/openwrt-package-$(printf '%s\n' "$package" | tr '/ ' '__').meta"
	if [ -f "$metadata_path" ]; then
		cat "$metadata_path"
		return 0
	fi

	for feed in base packages; do
		repo_url="$(openwrt_fallback_repo_url "$feed")" || continue
		index_path="$(openwrt_fallback_index_path "$feed")" || continue

		if [ ! -f "$index_path" ]; then
			download_to_file "$repo_url/Packages.gz" "$index_path" || continue
		fi

		raw="$(gzip -dc "$index_path" 2>/dev/null | awk -v pkg="$package" -v feed="$feed" '
			BEGIN { RS = ""; FS = "\n" }
			{
				found = 0
				for (i = 1; i <= NF; i++) {
					if ($i == "Package: " pkg) {
						found = 1
						break
					}
				}
				if (!found) {
					next
				}
				for (i = 1; i <= NF; i++) {
					if ($i ~ /^Filename: /) {
						filename = substr($i, 11)
					} else if ($i ~ /^Depends: /) {
						depends = substr($i, 10)
					}
				}
				printf "FEED=%s\nFILENAME=%s\nDEPENDS=%s\n", feed, filename, depends
				exit
			}
		')"
		[ -n "$raw" ] || continue

		filename="$(printf '%s\n' "$raw" | sed -n 's/^FILENAME=//p' | sed -n '1p')"
		[ -n "$filename" ] || continue
		depends="$(printf '%s\n' "$raw" | sed -n 's/^DEPENDS=//p' | sed -n '1p')"
		printf 'FEED=%s\nFILENAME=%s\nDEPENDS=%s\n' "$feed" "$filename" "$depends" > "$metadata_path"
		cat "$metadata_path"
		return 0
	done

	return 1
}

normalize_openwrt_dependency() {
	local dependency="$1"

	dependency="$(printf '%s\n' "$dependency" | sed \
		-e 's/|.*$//' \
		-e 's/([^)]*)//g' \
		-e 's/^[[:space:]]*//' \
		-e 's/[[:space:]]*$//' \
		-e 's/^+//')"
	case "$dependency" in
		''|@*)
			return 1
			;;
		*:* )
			dependency="${dependency##*:}"
			;;
	esac
	dependency="$(printf '%s\n' "$dependency" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
	[ -n "$dependency" ] || return 1
	printf '%s\n' "$dependency"
}

openwrt_dependency_list() {
	local depends="$1"
	local old_ifs raw dependency

	[ -n "$depends" ] || return 0
	old_ifs="$IFS"
	IFS=','
	set -- $depends
	IFS="$old_ifs"
	for raw in "$@"; do
		dependency="$(normalize_openwrt_dependency "$raw")" || continue
		printf '%s\n' "$dependency"
	done
}

resolve_pkg_via_openwrt_fallback() {
	local package="$1"
	local seen_file="$2"
	local ordered_file="$3"
	local metadata depends dependency

	pkg_installed_exact "$package" && return 0
	grep -Fxq "$package" "$seen_file" >/dev/null 2>&1 && return 0
	printf '%s\n' "$package" >> "$seen_file"

	metadata="$(openwrt_fallback_package_metadata "$package")" || return 1
	depends="$(printf '%s\n' "$metadata" | sed -n 's/^DEPENDS=//p' | sed -n '1p')"
	while IFS= read -r dependency; do
		[ -n "$dependency" ] || continue
		if pkg_installed_exact "$dependency"; then
			continue
		fi
		if openwrt_fallback_package_metadata "$dependency" >/dev/null 2>&1; then
			resolve_pkg_via_openwrt_fallback "$dependency" "$seen_file" "$ordered_file" || return 1
			continue
		fi
		warn "Assuming dependency '$dependency' for package '$package' is already provided by the router firmware."
	done <<EOF
$(openwrt_dependency_list "$depends")
EOF

	printf '%s\n' "$package" >> "$ordered_file"
}

install_pkg_via_openwrt_fallback() {
	local package="$1"
	local seen_file ordered_file resolved_package metadata feed repo_url filename target

	if pkg_installed_exact "$package"; then
		return 0
	fi

	seen_file="${DOWNLOAD_DIR}/openwrt-fallback-seen.$$.txt"
	ordered_file="${DOWNLOAD_DIR}/openwrt-fallback-order.$$.txt"
	: > "$seen_file"
	: > "$ordered_file"
	resolve_pkg_via_openwrt_fallback "$package" "$seen_file" "$ordered_file" || return 1

	set --
	while IFS= read -r resolved_package; do
		[ -n "$resolved_package" ] || continue
		metadata="$(openwrt_fallback_package_metadata "$resolved_package")" || return 1
		feed="$(printf '%s\n' "$metadata" | sed -n 's/^FEED=//p' | sed -n '1p')"
		filename="$(printf '%s\n' "$metadata" | sed -n 's/^FILENAME=//p' | sed -n '1p')"
		[ -n "$feed" ] || return 1
		[ -n "$filename" ] || return 1
		repo_url="$(openwrt_fallback_repo_url "$feed")" || return 1
		target="${DOWNLOAD_DIR}/$(basename "$filename")"
		[ -f "$target" ] || download_to_file "$repo_url/$filename" "$target" || return 1
		set -- "$@" "$target"
	done < "$ordered_file"

	[ "$#" -gt 0 ] || return 1
	opkg install "$@" >/tmp/vpn-xray-opkg-fallback.log 2>&1
}

ensure_pkg_installed_or_fallback() {
	local package="$1"
	local purpose="$2"

	pkg_installed_exact "$package" && return 0

	# Air-gap default: serve only from the bundled offline payload that
	# travels with the source tree. The workstation has no path to public
	# package mirrors and the router's configured feeds are not trustworthy
	# either, so external downloads are gated behind VPN_XRAY_ALLOW_NETWORK_PKG=1.
	install_bundled_opkg_single "$package" && return 0

	if [ "${VPN_XRAY_ALLOW_NETWORK_PKG:-0}" = "1" ]; then
		opkg install "$package" >/dev/null 2>&1 && pkg_installed_exact "$package" && return 0
		warn "Could not install package '$package' from configured feeds or offline bundle for $purpose. Trying the official OpenWrt 23.05.5 package mirror."
		install_pkg_via_openwrt_fallback "$package" || fail "Could not install package '$package' for $purpose from opkg feeds, offline bundle, or the official OpenWrt package mirror."
		pkg_installed_exact "$package" || fail "Package '$package' is still unavailable after fallback install."
		return 0
	fi

	fail "Package '$package' missing for $purpose. Add it to routers/asus-tuf-ax4200-openwrt/packages/opkg/ (run scripts/harvest-opkg-packages.sh) or set VPN_XRAY_ALLOW_NETWORK_PKG=1 to allow online fallback."
}

git_sync_requested() {
	[ "${RULES_GIT_SYNC_ENABLED:-0}" = '1' ]
}

effective_xray_rules_mode() {
	local existing

	# Env wins when explicit. install-router.sh's PRESERVE_XRAY_RULES_MODE
	# already preloads XRAY_RULES_MODE from current UCI when preservation is
	# desired, so by the time we reach install-platform.sh the env already
	# encodes the final intent: install.env value (override) or current UCI
	# (preserve). Treat XRAY_RULES_MODE as authoritative if it is valid.
	case "${XRAY_RULES_MODE:-}" in
		full|selective)
			printf '%s\n' "$XRAY_RULES_MODE"
			return
			;;
	esac

	existing="$(uci -q get router_rules.global.xray_mode 2>/dev/null || true)"
	case "$existing" in
		full|selective)
			printf '%s\n' "$existing"
			;;
		*)
			printf 'full\n'
			;;
	esac
}

existing_router_rules_value() {
	uci -q get "router_rules.global.$1" 2>/dev/null || true
}

effective_external_source_enabled() {
	local existing

	case "${RULES_EXTERNAL_SOURCE_ENABLED:-}" in
		0|1)
			printf '%s\n' "$RULES_EXTERNAL_SOURCE_ENABLED"
			return
			;;
	esac

	existing="$(existing_router_rules_value external_source_enabled)"
	case "$existing" in
		0|1)
			printf '%s\n' "$existing"
			;;
		*)
			printf '0\n'
			;;
	esac
}

effective_external_source_url() {
	local existing

	existing="$(existing_router_rules_value external_source_url)"
	if [ -n "$existing" ]; then
		printf '%s\n' "$existing"
	else
		printf '%s\n' "${RULES_EXTERNAL_SOURCE_URL:-}"
	fi
}

effective_external_source_interval() {
	local existing

	existing="$(existing_router_rules_value external_source_interval)"
	case "$existing" in
		''|*[!0-9]*)
			printf '%s\n' "${RULES_EXTERNAL_SOURCE_INTERVAL:-86400}"
			;;
		*)
			printf '%s\n' "$existing"
			;;
	esac
}

effective_router_rules_text_value() {
	local key="$1"
	local fallback="$2"
	local existing

	# Env wins when explicit (non-empty). Preserve UCI only when env is empty.
	# This makes install.env authoritative for things like repo URLs while
	# still preserving UI-set values that have no env override.
	if [ -n "$fallback" ]; then
		printf '%s\n' "$fallback"
		return
	fi
	existing="$(existing_router_rules_value "$key")"
	printf '%s\n' "$existing"
}

effective_router_rules_bool_value() {
	local key="$1"
	local fallback="$2"
	local existing

	# Env wins when explicit (0 or 1). Preserve UCI only when env is unset.
	case "$fallback" in
		0|1)
			printf '%s\n' "$fallback"
			return
			;;
	esac
	existing="$(existing_router_rules_value "$key")"
	case "$existing" in
		0|1)
			printf '%s\n' "$existing"
			;;
		*)
			printf '0\n'
			;;
	esac
}

