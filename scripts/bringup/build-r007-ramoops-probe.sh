#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0

set -euo pipefail

expected_epoch=1784042363
expected_defconfig=${EXPECTED_DEFCONFIG_SHA:-892c8cdb025a2ff0767387c6b53ddb6d116a06ac4d7fccad5385b5073a284e94}
expected_signing_key=${EXPECTED_SIGNING_KEY_SHA:-1dda1a9e9308ddac7bad047fceb74b4c02c8dcd82d0625aef98b5df32717c7cf}
image_size_limit=$((50 * 1024 * 1024))
expected_console_address=$((0xb7f40000))
expected_device_info_address=$((0xb81c0000))
script_repo=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
source_repo=${SOURCE_REPO:-$script_repo}
out_dir=${OUT_DIR:-$source_repo/out-r007-ramoops-probe}
jobs=${JOBS:-6}
toolchain_root=${TOOLCHAIN_ROOT:-/home/lknife/android/toolchains/aosp-android11}
dtc_bin=${DTC_BIN:-/usr/bin/dtc}
fdtget_bin=${FDTGET_BIN:-/usr/bin/fdtget}
fdtoverlay_bin=${FDTOVERLAY_BIN:-/usr/bin/fdtoverlay}
overlay=${RMX1901_DTBO_ENTRY_46:-}
signing_key=${REPRO_SIGNING_KEY_PEM:-}
fragment="$script_repo/bringup/configs/r006-under-50m.fragment"

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

dt_hex() {
	"$fdtget_bin" -t x "$dtb" "$ramoops_node" "$1"
}

[[ $jobs =~ ^[1-9][0-9]*$ ]] || die "JOBS must be a positive integer"
[[ ! -e $out_dir ]] || die "OUT_DIR must not exist: $out_dir"
[[ -f $overlay ]] || die "set RMX1901_DTBO_ENTRY_46 to extracted DTBO entry 46"
[[ -f $signing_key ]] || die "set REPRO_SIGNING_KEY_PEM to the reproducible build key"
if [[ -z ${ALLOW_UNPINNED_SIGNING_KEY:-} ]]; then
	[[ $(sha256sum "$signing_key" | awk '{print $1}') == "$expected_signing_key" ]] ||
		die "module signing PEM differs from the M1 reproducible key"
fi
if [[ -z ${ALLOW_STALE_DEFCONFIG_GATE:-} ]]; then
	[[ $(sha256sum "$source_repo/arch/arm64/configs/vendor/rmx1901_m2_defconfig" |
		awk '{print $1}') == "$expected_defconfig" ]] || die "M2 defconfig hash changed"
fi
[[ $(wc -l <"$fragment") == 1 ]] || die "r006 fragment must contain one line"
grep -qx '# CONFIG_SPECTRA_CAMERA is not set' "$fragment" ||
	die "unexpected r006 fragment"
grep -q 'parse_size("devinfo-size", pdata->device_info_size);' \
	"$source_repo/fs/pstore/ram.c" || die "devinfo-size parser is missing"

if [[ -n ${LLVM_BIN_DIR:-} ]]; then
	clang_bin="$LLVM_BIN_DIR/clang"
	lld_bin="$LLVM_BIN_DIR/ld.lld"
	cross_compile=${CROSS_COMPILE:-aarch64-linux-gnu-}
	cross_compile_arm32=${CROSS_COMPILE_ARM32:-arm-linux-gnueabi-}
	[[ -x $clang_bin && -x $lld_bin ]] ||
		die "LLVM_BIN_DIR must contain clang and ld.lld: $LLVM_BIN_DIR"
	command -v "${cross_compile}elfedit" >/dev/null 2>&1 ||
		die "missing ${cross_compile}elfedit for LLVM cross-linking"
	command -v "${cross_compile_arm32}ld" >/dev/null 2>&1 ||
		die "missing ${cross_compile_arm32}ld for LLVM cross-linking"
else
	clang_bin="$toolchain_root/clang-r383902/bin/clang"
	lld_bin="$toolchain_root/clang-r383902/bin/ld.lld"
	[[ -x $clang_bin && -x $lld_bin ]] || die "pinned Clang 11 toolchain is missing"
fi
[[ -x $dtc_bin ]] || die "external DTC is missing: $dtc_bin"
[[ -x $fdtget_bin ]] || die "fdtget is missing: $fdtget_bin"
[[ -x $fdtoverlay_bin ]] || die "fdtoverlay is missing: $fdtoverlay_bin"

mkdir -p "$out_dir/certs" "$out_dir/tmp"
install -m 0600 /dev/null "$out_dir/certs/x509.genkey"
touch -d "@$((expected_epoch - 1))" "$out_dir/certs/x509.genkey"
install -m 0600 "$signing_key" "$out_dir/certs/signing_key.pem"
touch -d "@$expected_epoch" "$out_dir/certs/signing_key.pem"

if [[ -n ${LLVM_BIN_DIR:-} ]]; then
	export PATH="$LLVM_BIN_DIR:$(dirname "$dtc_bin"):$(dirname "$fdtget_bin"):$(dirname "$fdtoverlay_bin"):$(dirname "$(command -v "${cross_compile}elfedit")"):$(dirname "$(command -v "${cross_compile_arm32}ld")"):$PATH"
	export CROSS_COMPILE="$cross_compile"
	export CROSS_COMPILE_ARM32="$cross_compile_arm32"
else
	export PATH="$toolchain_root/clang-r383902/bin:$toolchain_root/aarch64-linux-android-4.9/bin:$toolchain_root/arm-linux-androideabi-4.9/bin:/usr/bin:/bin"
fi
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
export LOCALVERSION=
kcflags=${KCFLAGS:-}
case " $kcflags " in
	*' -fdebug-compilation-dir=. '*) ;;
	*) kcflags="${kcflags:+$kcflags }-fdebug-compilation-dir=." ;;
esac
export KCFLAGS="$kcflags"
ka_flags=${KAFLAGS:-}
case " $ka_flags " in
	*' -fdebug-compilation-dir=. '*) ;;
	*) ka_flags="${ka_flags:+$ka_flags }-fdebug-compilation-dir=." ;;
esac
export KAFLAGS="$ka_flags"
export TMPDIR="$out_dir/tmp"

make -C "$source_repo" O="$out_dir" vendor/rmx1901_m2_defconfig \
	>"$out_dir/configure.log" 2>&1
"$source_repo/scripts/config" --file "$out_dir/.config" \
	--disable SPECTRA_CAMERA

# Candidate-only built-in options may be supplied without changing the
# validated baseline defconfig. The variable is intentionally opt-in so all
# existing bring-up gates keep their original configuration.
extra_config_options=${RMX1901_EXTRA_CONFIG_OPTIONS:-}
if [[ -n "$extra_config_options" ]]; then
	for option in $extra_config_options; do
		[[ "$option" =~ ^[A-Z0-9_]+$ ]] ||
			die "invalid candidate config option: $option"
		"$source_repo/scripts/config" --file "$out_dir/.config" \
			--enable "$option"
	done
fi

make -C "$source_repo" O="$out_dir" olddefconfig \
	>>"$out_dir/configure.log" 2>&1
make -C "$source_repo" O="$out_dir" listnewconfig \
	>"$out_dir/listnewconfig.log" 2>&1

if grep -q '^CONFIG_' "$out_dir/listnewconfig.log"; then
	die "listnewconfig is not empty"
fi

make -C "$source_repo" -j"$jobs" O="$out_dir" Image Image.gz dtbs \
	>"$out_dir/build.log" 2>&1

image="$out_dir/arch/arm64/boot/Image"
image_gz="$out_dir/arch/arm64/boot/Image.gz"
dtb="$out_dir/arch/arm64/boot/dts/rmx1901/sdm710.dtb"
vmlinux="$out_dir/vmlinux"
for file in "$image" "$image_gz" "$dtb" "$vmlinux" "$out_dir/.config"; do
	[[ -s $file ]] || die "missing output: $file"
done

grep -qx '# CONFIG_SPECTRA_CAMERA is not set' "$out_dir/.config" ||
	die "SPECTRA_CAMERA was not disabled"
for option in \
	CONFIG_ARCH_SDM670 CONFIG_QCOM_SCM CONFIG_ARM_SMMU CONFIG_QTI_RPMH_API \
	CONFIG_MSM_CLK_RPMH CONFIG_REGULATOR_RPMH CONFIG_SPMI_MSM_PMIC_ARB \
	CONFIG_PINCTRL_SDM670 CONFIG_QTI_PDC_SDM670 CONFIG_QCOM_SDM670_LLCC \
	CONFIG_MSM_GCC_SDM845 CONFIG_CLOCK_CPU_OSM CONFIG_SCSI_UFSHCD \
	CONFIG_SCSI_UFS_QCOM CONFIG_PHY_QCOM_UFS CONFIG_SERIAL_MSM_GENI_CONSOLE \
	CONFIG_PSTORE_RAM; do
	grep -qx "$option=y" "$out_dir/.config" || die "$option is not built in"
done

gzip -t "$image_gz"
gzip -dc "$image_gz" | cmp -s - "$image" || die "Image.gz does not expand to Image"
magic=$(od -An -j 56 -N 4 -tx1 "$image" | tr -d ' \n')
[[ $magic == 41524d64 ]] || die "ARM64 Image magic is missing"
declared_hex=$(od -An -j 16 -N 8 -tx8 "$image" | tr -d ' \n')
declared_size=$((16#$declared_hex))
(( declared_size < image_size_limit )) ||
	die "declared Image size $declared_size is not below $image_size_limit"

"$script_repo/scripts/bringup/verify-rmx1901-dtb.py" "$dtb" "$overlay"

ramoops_node=/reserved-memory/ramoops@0x0xB7E00000
read -r reg_hi reg_lo size_hi size_lo < <("$fdtget_bin" -t x \
	"$dtb" "$ramoops_node" reg)
(( 16#$reg_hi == 0 && 16#$size_hi == 0 )) ||
	die "ramoops requires unsupported 64-bit high cells"
ramoops_base=$((16#$reg_lo))
ramoops_size=$((16#$size_lo))
record_size=$((16#$(dt_hex record-size)))
console_size=$((16#$(dt_hex console-size)))
ftrace_size=$((16#$(dt_hex ftrace-size)))
pmsg_size=$((16#$(dt_hex pmsg-size)))
device_info_size=$((16#$(dt_hex devinfo-size)))
dump_size=$((ramoops_size - console_size - ftrace_size - pmsg_size - device_info_size))
dump_count=$((dump_size / record_size))
console_address=$((ramoops_base + dump_count * record_size))
device_info_address=$((console_address + console_size + ftrace_size + pmsg_size))

(( dump_count == 5 )) || die "ramoops dump count is $dump_count instead of 5"
(( console_address == expected_console_address )) ||
	die "ramoops console moved to $(printf '0x%x' "$console_address")"
(( device_info_address == expected_device_info_address )) ||
	die "device info moved to $(printf '0x%x' "$device_info_address")"

sha256sum "$image" "$image_gz" "$vmlinux" "$out_dir/.config" "$dtb" \
	>"$out_dir/sha256sums.txt"
printf 'r007 ramoops probe build: PASS\n'
printf 'declared_image_size=%d\n' "$declared_size"
printf 'declared_image_limit=%d\n' "$image_size_limit"
printf 'actual_image_size=%s\n' "$(stat -c '%s' "$image")"
printf 'ramoops_dump_count=%d\n' "$dump_count"
printf 'ramoops_console_address=0x%x\n' "$console_address"
printf 'ramoops_device_info_address=0x%x\n' "$device_info_address"
cat "$out_dir/sha256sums.txt"
