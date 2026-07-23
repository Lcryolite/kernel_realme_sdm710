#!/usr/bin/env bash
set -euo pipefail

expected_head=dbc6d0dab1093092d15c64ffd79a713ba214c107
expected_epoch=1784042363
script_repo=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
source_repo="${SOURCE_REPO:-$script_repo}"
out_dir="${OUT_DIR:-$source_repo/out-donor-control}"
jobs="${JOBS:-6}"
toolchain_root="${TOOLCHAIN_ROOT:-/home/lknife/android/toolchains/aosp-android11}"
dtc_bin="${DTC_BIN:-/usr/bin/dtc}"

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

[[ $(git -C "$source_repo" rev-parse HEAD) == "$expected_head" ]] ||
	die "M1 requires donor HEAD $expected_head"
[[ ! -e "$out_dir" ]] ||
	die "OUT_DIR must not exist: $out_dir"
[[ $jobs =~ ^[1-9][0-9]*$ ]] || die "JOBS must be a positive integer"

clang_bin="$toolchain_root/clang-r383902/bin/clang"
lld_bin="$toolchain_root/clang-r383902/bin/ld.lld"
[[ -x "$clang_bin" && -x "$lld_bin" ]] ||
	die "pinned toolchain missing; run fetch-aosp-android11-toolchain.sh"
[[ -x "$dtc_bin" ]] || die "external DTC missing: $dtc_bin"

[[ $(sha256sum "$dtc_bin" | awk '{print $1}') == \
	223c2f97f431b1ef64c206e15375c063a180287cf29acdbdbf1d0dc3cdeee7b4 ]] ||
	die "DTC hash differs from the M1 baseline"

mkdir -p "$out_dir"
export PATH="$toolchain_root/clang-r383902/bin:$toolchain_root/aarch64-linux-android-4.9/bin:$toolchain_root/arm-linux-androideabi-4.9/bin:/usr/bin:/bin"
export ARCH=arm64
export LLVM=1
export LLVM_IAS=1
export DTC_EXT="$dtc_bin"
export KBUILD_BUILD_USER=rmx1901
export KBUILD_BUILD_HOST=bringup
export KBUILD_BUILD_VERSION=1
export KBUILD_BUILD_TIMESTAMP='Tue Jul 14 15:19:23 UTC 2026'
export SOURCE_DATE_EPOCH=$expected_epoch
export TAR_OPTIONS="--sort=name --mtime=@$SOURCE_DATE_EPOCH --owner=0 --group=0 --numeric-owner"

make -C "$source_repo" O="$out_dir" vendor/sm8150-perf_defconfig \
	>"$out_dir/configure.log" 2>&1
make -C "$source_repo" O="$out_dir" olddefconfig \
	>>"$out_dir/configure.log" 2>&1
make -C "$source_repo" O="$out_dir" listnewconfig \
	>"$out_dir/listnewconfig.log" 2>&1

if grep -q '^CONFIG_' "$out_dir/listnewconfig.log"; then
	die "listnewconfig is not empty"
fi

if [[ -n ${REPRO_SIGNING_KEY_PEM:-} ]]; then
	[[ -f $REPRO_SIGNING_KEY_PEM ]] || die "REPRO_SIGNING_KEY_PEM is not a file"
	mkdir -p "$out_dir/certs"
	install -m 0600 "$REPRO_SIGNING_KEY_PEM" "$out_dir/certs/signing_key.pem"
fi

make -C "$source_repo" -j"$jobs" O="$out_dir" Image Image.gz dtbs modules \
	>"$out_dir/build.log" 2>&1
make -C "$source_repo" O="$out_dir" savedefconfig \
	>>"$out_dir/configure.log" 2>&1

"$script_repo/scripts/bringup/verify-m1-output.sh" "$out_dir"
