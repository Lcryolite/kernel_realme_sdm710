#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
source_repo=$(git -C "$script_dir" rev-parse --show-toplevel)
out_dir=${OUT_DIR:-$source_repo/out-r019-smb2}
defconfig="$source_repo/arch/arm64/configs/vendor/rmx1901_m2_defconfig"
expected_defconfig=4d66954ad1d0777f2e1758feeaf993371e88e60fb223b991f88135615de1f0fb

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

grep -Fq 'CONFIG_MSM_QUSB_PHY=y' "$defconfig" ||
	die "tracked defconfig is missing CONFIG_MSM_QUSB_PHY=y"
grep -Fq 'CONFIG_QPNP_USB_PDPHY=y' "$defconfig" ||
	die "tracked defconfig no longer preserves the PD PHY baseline"
grep -Fq 'CONFIG_QPNP_SMB2=y' "$defconfig" ||
	die "tracked defconfig is missing CONFIG_QPNP_SMB2=y"
grep -Fq '# CONFIG_QPNP_SMB5 is not set' "$defconfig" ||
	die "tracked defconfig unexpectedly keeps CONFIG_QPNP_SMB5=y"
if grep -Fq 'CONFIG_QPNP_FG_GEN3=y' "$defconfig"; then
	die "tracked defconfig unexpectedly enables CONFIG_QPNP_FG_GEN3"
fi
[[ $(sha256sum "$defconfig" | awk '{print $1}') == "$expected_defconfig" ]] ||
	die "tracked defconfig hash differs from the r019 SMB2-only checkpoint"

# Preserve the full r016 static candidate chain and override only the defconfig
# hash guard so earlier scripts accept the single intended r019 config change.
EXPECTED_DEFCONFIG_SHA="$expected_defconfig" OUT_DIR="$out_dir" \
	"$script_dir/build-r016-boot-guard.sh"

grep -Fq 'CONFIG_MSM_QUSB_PHY=y' "$out_dir/.config" ||
	die "built config is missing CONFIG_MSM_QUSB_PHY=y"
grep -Fq 'CONFIG_QPNP_USB_PDPHY=y' "$out_dir/.config" ||
	die "built config is missing CONFIG_QPNP_USB_PDPHY=y"
grep -Fq 'CONFIG_QPNP_SMB2=y' "$out_dir/.config" ||
	die "built config is missing CONFIG_QPNP_SMB2=y"
grep -Fq '# CONFIG_QPNP_SMB5 is not set' "$out_dir/.config" ||
	die "built config unexpectedly enables CONFIG_QPNP_SMB5"
grep -Fq '# CONFIG_QPNP_FG_GEN3 is not set' "$out_dir/.config" ||
	die "built config unexpectedly enables CONFIG_QPNP_FG_GEN3"

summary="$out_dir/r019-gate-summary.txt"
{
	printf 'source_commit=%s\n' "$(git -C "$source_repo" rev-parse HEAD)"
	printf 'source_tree_clean=%s\n' \
		"$([[ -z $(git -C "$source_repo" status --porcelain) ]] && printf PASS || printf DIRTY_ALLOWED)"
	printf 'candidate_kind=SMB2_CHARGER_STACK_SWAP\n'
	printf 'baseline_candidate=B14-M03-r018-usb-dt-compat\n'
	printf 'functional_change=CONFIG_QPNP_SMB2=y,# CONFIG_QPNP_SMB5 is not set\n'
	printf 'forbidden_functional_changes=DT,RAMDISK,DWC3_SOURCE,UFS,DISPLAY,FG_GEN3,CLANG\n'
	printf 'expected_defconfig_sha256=%s\n' "$expected_defconfig"
	sha256sum "$defconfig" "$out_dir/.config" "$out_dir/Module.symvers" \
		"$out_dir/vmlinux" "$out_dir/System.map" \
		"$out_dir/arch/arm64/boot/Image" \
		"$out_dir/arch/arm64/boot/Image.gz" \
		"$out_dir/arch/arm64/boot/dts/rmx1901/sdm710.dtb" \
		"$out_dir/r014-overlay46-merged.dtb"
} >"$summary"

printf 'r019 SMB2/SMB5 charger-stack build: PASS\n'
