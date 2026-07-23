#!/usr/bin/env bash
set -euo pipefail

expected_epoch=1784042363
expected_defconfig=707c0160f92b00e0e59d887c49e324bc2abc60e6b73787553d2d0b069e57aa20
expected_signing_key=3eebca2a75fbd744e0f2a42a60fff8d97cbc2ee073c7912e17fe1b58a6fb0e03
script_repo=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
source_repo="${SOURCE_REPO:-$script_repo}"
out_dir="${OUT_DIR:-$source_repo/out-m2-static}"
jobs="${JOBS:-6}"
toolchain_root="${TOOLCHAIN_ROOT:-/home/lknife/android/toolchains/aosp-android11}"
dtc_bin="${DTC_BIN:-/usr/bin/dtc}"
overlay="${RMX1901_DTBO_ENTRY_46:-}"
signing_key="${REPRO_SIGNING_KEY_PEM:-}"

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

[[ $jobs =~ ^[1-9][0-9]*$ ]] || die "JOBS must be a positive integer"
[[ ! -e $out_dir ]] || die "OUT_DIR must not exist: $out_dir"
[[ -f $overlay ]] || die "set RMX1901_DTBO_ENTRY_46 to extracted DTBO entry 46"
[[ -f $signing_key ]] || die "set REPRO_SIGNING_KEY_PEM to the reproducible build key"
[[ $(sha256sum "$signing_key" | awk '{print $1}') == "$expected_signing_key" ]] ||
	die "module signing PEM differs from the M1 reproducible key"
[[ $(sha256sum "$source_repo/arch/arm64/configs/vendor/rmx1901_m2_defconfig" |
	awk '{print $1}') == "$expected_defconfig" ]] || die "M2 defconfig hash changed"

clang_bin="$toolchain_root/clang-r383902/bin/clang"
lld_bin="$toolchain_root/clang-r383902/bin/ld.lld"
[[ -x $clang_bin && -x $lld_bin ]] ||
	die "pinned toolchain missing; run fetch-aosp-android11-toolchain.sh"
[[ -x $dtc_bin ]] || die "external DTC missing: $dtc_bin"
[[ $(sha256sum "$dtc_bin" | awk '{print $1}') == \
	223c2f97f431b1ef64c206e15375c063a180287cf29acdbdbf1d0dc3cdeee7b4 ]] ||
	die "DTC hash differs from the M1 baseline"

mkdir -p "$out_dir/certs"
# certs/Makefile generates x509.genkey during the build.  If that new file is
# newer than an already supplied signing_key.pem, Make regenerates a random
# key pair.  Pre-create its generation-only prerequisite with a deterministic
# older mtime so the pinned PEM remains the actual kernel/module certificate.
install -m 0600 /dev/null "$out_dir/certs/x509.genkey"
touch -d "@$((expected_epoch - 1))" "$out_dir/certs/x509.genkey"
install -m 0600 "$signing_key" "$out_dir/certs/signing_key.pem"
touch -d "@$expected_epoch" "$out_dir/certs/signing_key.pem"

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
# An explicitly set empty value suppresses setlocalversion's untagged-tree '+'.
export LOCALVERSION=
# Clang otherwise records the absolute O= directory as DW_AT_comp_dir.  That
# changes ThinLTO's internal .llvm.<hash> names and, through kallsyms, changes
# Image even when the source, configuration, and generated code are identical.
export KCFLAGS='-fdebug-compilation-dir=.'
export KAFLAGS='-fdebug-compilation-dir=.'

make -C "$source_repo" O="$out_dir" vendor/rmx1901_m2_defconfig \
	>"$out_dir/configure.log" 2>&1
make -C "$source_repo" O="$out_dir" olddefconfig \
	>>"$out_dir/configure.log" 2>&1
make -C "$source_repo" O="$out_dir" listnewconfig \
	>"$out_dir/listnewconfig.log" 2>&1

if grep -q '^CONFIG_' "$out_dir/listnewconfig.log"; then
	die "listnewconfig is not empty"
fi

make -C "$source_repo" -j"$jobs" O="$out_dir" \
	Image Image.gz dtbs modules >"$out_dir/build.log" 2>&1
make -C "$source_repo" O="$out_dir" savedefconfig \
	>>"$out_dir/configure.log" 2>&1

"$script_repo/scripts/bringup/verify-m2-output.sh" "$out_dir" "$overlay"
