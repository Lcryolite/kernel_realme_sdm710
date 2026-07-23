#!/usr/bin/env bash
set -euo pipefail

toolchain_root="${TOOLCHAIN_ROOT:-/home/lknife/android/toolchains/aosp-android11}"
archive_dir="$toolchain_root/archives"

clang_commit=252aba16f513a857bc923172f67b0e55e23de35f
aarch64_commit=606f80986096476912e04e5c2913685a8f2c3b65
arm_commit=b0c6a654327ca8796bed1e61dffcf523d04dceaa

clang_archive="$archive_dir/clang-r383902-$clang_commit.tar.gz"
aarch64_archive="$archive_dir/aarch64-linux-android-4.9-$aarch64_commit.tar.gz"
arm_archive="$archive_dir/arm-linux-androideabi-4.9-$arm_commit.tar.gz"

mkdir -p "$archive_dir"

fetch() {
	local output=$1
	local url=$2
	if [[ ! -s "$output" ]]; then
		curl --fail --location --retry 5 --silent --show-error \
			--output "$output" "$url"
	fi
}

fetch "$clang_archive" \
	"https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/$clang_commit/clang-r383902.tar.gz"
fetch "$aarch64_archive" \
	"https://android.googlesource.com/platform/prebuilts/gcc/linux-x86/aarch64/aarch64-linux-android-4.9/+archive/$aarch64_commit.tar.gz"
fetch "$arm_archive" \
	"https://android.googlesource.com/platform/prebuilts/gcc/linux-x86/arm/arm-linux-androideabi-4.9/+archive/$arm_commit.tar.gz"

printf '%s  %s\n' \
	2b919802aae65dfc4fabfd2a88f899e80ea1f8e43b772acdf30fc280854fcdb7 "$clang_archive" \
	68bd35d11795fb9237639dbc3eeccbaaedc44da9e094e902133ffb5535fe28e6 "$aarch64_archive" \
	602904ecd94a59d103d546311823505733e8a91834b66e0dba79d4b629de957b "$arm_archive" \
	| sha256sum --check --strict

extract_once() {
	local archive=$1
	local destination=$2
	local sentinel=$3
	mkdir -p "$destination"
	if [[ ! -x "$destination/$sentinel" ]]; then
		tar -xzf "$archive" -C "$destination"
	fi
}

extract_once "$clang_archive" "$toolchain_root/clang-r383902" bin/clang
extract_once "$aarch64_archive" "$toolchain_root/aarch64-linux-android-4.9" \
	bin/aarch64-linux-android-objcopy
extract_once "$arm_archive" "$toolchain_root/arm-linux-androideabi-4.9" \
	bin/arm-linux-androideabi-objcopy

"$toolchain_root/clang-r383902/bin/clang" --version | sed -n '1,3p'
"$toolchain_root/clang-r383902/bin/ld.lld" --version | sed -n '1p'
