#!/usr/bin/env bash
set -euo pipefail

[[ $# == 2 ]] || {
	printf 'usage: %s OUT_DIR DTBO_ENTRY_46\n' "$0" >&2
	exit 2
}

out_dir=$(realpath "$1")
overlay=$(realpath "$2")
repo=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
baseline="$repo/bringup/baselines/M1-warnings.txt"
dtb="$out_dir/arch/arm64/boot/dts/rmx1901/sdm710.dtb"
expected_signing_key=3eebca2a75fbd744e0f2a42a60fff8d97cbc2ee073c7912e17fe1b58a6fb0e03
expected_signing_cert=e4db0c74f32306baf093f81e1f87c6d8d541d5dde2669f39f21a7343c2cc4dbe

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

for file in \
	"$out_dir/arch/arm64/boot/Image" \
	"$out_dir/arch/arm64/boot/Image.gz" \
	"$out_dir/vmlinux" \
	"$out_dir/System.map" \
	"$out_dir/Module.symvers" \
	"$out_dir/.config" \
	"$out_dir/defconfig" \
	"$out_dir/build.log" \
	"$out_dir/listnewconfig.log" \
	"$out_dir/certs/signing_key.pem" \
	"$out_dir/certs/signing_key.x509" \
	"$out_dir/arch/arm64/kernel/.stacktrace.o.cmd" \
	"$out_dir/arch/arm64/kernel/stacktrace.o" \
	"$dtb"; do
	[[ -s $file ]] || die "missing output: $file"
done

grep -Fq -- '-fdebug-compilation-dir=.' \
	"$out_dir/arch/arm64/kernel/.stacktrace.o.cmd" ||
	die "stable Clang debug compilation directory flag is missing"
if strings "$out_dir/arch/arm64/kernel/stacktrace.o" | grep -Fq "$out_dir"; then
	die "absolute output path leaked into Clang bitcode"
fi
[[ $(sha256sum "$out_dir/certs/signing_key.pem" | awk '{print $1}') == \
	"$expected_signing_key" ]] || die "pinned module signing PEM was replaced"
[[ $(sha256sum "$out_dir/certs/signing_key.x509" | awk '{print $1}') == \
	"$expected_signing_cert" ]] || die "unexpected module signing certificate"
! grep -Fq 'Now generating an X.509 key pair' "$out_dir/build.log" ||
	die "build regenerated a random module signing key"

! grep -q '^CONFIG_' "$out_dir/listnewconfig.log" || die "listnewconfig is not empty"
cmp -s "$out_dir/defconfig" \
	"$repo/arch/arm64/configs/vendor/rmx1901_m2_defconfig" ||
	die "savedefconfig differs from the tracked M2 defconfig"

grep -qx 'CONFIG_ARCH_SDM670=y' "$out_dir/.config" || die "ARCH_SDM670 is disabled"
! grep -qx 'CONFIG_ARCH_SM8150=y' "$out_dir/.config" || die "ARCH_SM8150 leaked into M2"
grep -qx 'CONFIG_LOCALVERSION="-RMX1901-A17-M2"' "$out_dir/.config" ||
	die "unexpected localversion"
grep -qx '# CONFIG_LOCALVERSION_AUTO is not set' "$out_dir/.config" ||
	die "LOCALVERSION_AUTO must be disabled"

for option in \
	CONFIG_QCOM_SCM CONFIG_ARM_SMMU CONFIG_QTI_RPMH_API CONFIG_MSM_CLK_RPMH \
	CONFIG_REGULATOR_RPMH CONFIG_SPMI_MSM_PMIC_ARB CONFIG_PINCTRL_SDM670 \
	CONFIG_QTI_PDC_SDM670 CONFIG_QCOM_SDM670_LLCC CONFIG_MSM_GCC_SDM845 \
	CONFIG_CLOCK_CPU_OSM CONFIG_SCSI_UFSHCD CONFIG_SCSI_UFS_QCOM \
	CONFIG_PHY_QCOM_UFS CONFIG_SERIAL_MSM_GENI_CONSOLE CONFIG_PSTORE_RAM; do
	grep -qx "$option=y" "$out_dir/.config" || die "$option is not built in"
done

if grep -Eq '^(CONFIG_KSU|CONFIG_KSU_SUSFS|CONFIG_SCHED_BORE)=y' "$out_dir/.config"; then
	die "ReSukiSU/KernelSU/BORE must remain disabled in M2"
fi

gzip -t "$out_dir/arch/arm64/boot/Image.gz"
gzip -dc "$out_dir/arch/arm64/boot/Image.gz" |
	cmp -s - "$out_dir/arch/arm64/boot/Image" || die "Image.gz does not expand to Image"

release=$(<"$out_dir/include/config/kernel.release")
[[ $release == 4.14.357-openela-RMX1901-A17-M2 ]] ||
	die "unexpected kernel release: $release"

warning_count=0
while IFS= read -r warning; do
	[[ -z $warning ]] && continue
	warning_count=$((warning_count + 1))
	grep -Fxq "$warning" "$baseline" || die "new warning: $warning"
done < <(grep -E 'warning:|^WARNING:' "$out_dir/build.log" || true)

expected_modules=$(printf '%s\n' \
	'drivers/media/usb/gspca/gspca_main.ko' \
	'techpack/data/drivers/rmnet/perf/rmnet_perf.ko' \
	'techpack/data/drivers/rmnet/shs/rmnet_shs.ko')
actual_modules=$(find "$out_dir" -type f -name '*.ko' -printf '%P\n' | sort)
[[ $actual_modules == "$expected_modules" ]] || die "unexpected module set"

"$repo/scripts/bringup/verify-rmx1901-dtb.py" "$dtb" "$overlay"

sha256sum \
	"$out_dir/arch/arm64/boot/Image" \
	"$out_dir/arch/arm64/boot/Image.gz" \
	"$out_dir/vmlinux" \
	"$out_dir/System.map" \
	"$out_dir/Module.symvers" \
	"$out_dir/.config" \
	"$out_dir/defconfig" \
	"$dtb" >"$out_dir/sha256sums.txt"

printf 'M2 output gate: PASS\n'
printf 'kernel release: %s\n' "$release"
printf 'warnings accepted from M1 baseline: %d\n' "$warning_count"
