#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
source_repo=$(git -C "$script_dir" rev-parse --show-toplevel)
out_dir=${OUT_DIR:-$source_repo/out-r022-usb-udc-instrumentation}
defconfig="$source_repo/arch/arm64/configs/vendor/rmx1901_m2_defconfig"
expected_defconfig=4d66954ad1d0777f2e1758feeaf993371e88e60fb223b991f88135615de1f0fb
ufs_dts="$source_repo/arch/arm64/boot/dts/rmx1901/sdm670.dtsi"
dwc3_msm_driver="$source_repo/drivers/usb/dwc3/dwc3-msm.c"
dwc3_gadget_driver="$source_repo/drivers/usb/dwc3/gadget.c"
udc_core="$source_repo/drivers/usb/gadget/udc/core.c"
configfs_driver="$source_repo/drivers/usb/gadget/configfs.c"

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
	die "tracked defconfig hash differs from the r019 SMB2 checkpoint"

grep -Fq 'reg = <0x1d84000 0x3000>, <0x1d90000 0x8000>;' "$ufs_dts" ||
	die "tracked UFS DTS is missing the second ICE MMIO range"
grep -Fq 'reg-names = "ufs_mem", "ufs_ice";' "$ufs_dts" ||
	die "tracked UFS DTS is missing reg-names for the ICE resource"
grep -Fq 'skip gadget vbus connect' "$dwc3_msm_driver" ||
	die "tracked dwc3-msm driver is missing the r021 vbus connect guard"
grep -Fq 'skip gadget vbus disconnect' "$dwc3_msm_driver" ||
	die "tracked dwc3-msm driver is missing the r021 vbus disconnect guard"
grep -Fq 'RMX1901-R022-UDC:' "$dwc3_msm_driver" ||
	die "tracked dwc3-msm driver is missing the r022 instrumentation"
grep -Fq 'RMX1901-R022-UDC:' "$dwc3_gadget_driver" ||
	die "tracked dwc3 gadget driver is missing the r022 instrumentation"
grep -Fq 'RMX1901-R022-UDC:' "$udc_core" ||
	die "tracked UDC core is missing the r022 instrumentation"
grep -Fq 'RMX1901-R022-UDC:' "$configfs_driver" ||
	die "tracked configfs gadget path is missing the r022 instrumentation"

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
grep -Fq 'reg-names = "ufs_mem", "ufs_ice";' \
	"$out_dir/r014-overlay46-merged.dts" ||
	die "merged DTS is missing the named UFS ICE resource"

summary="$out_dir/r022-gate-summary.txt"
{
	printf 'source_commit=%s\n' "$(git -C "$source_repo" rev-parse HEAD)"
	printf 'source_tree_clean=%s\n' \
		"$([[ -z $(git -C "$source_repo" status --porcelain) ]] && printf PASS || printf DIRTY_ALLOWED)"
	printf 'candidate_kind=USB_UDC_INSTRUMENTATION\n'
	printf 'baseline_candidate=B14-M03-r021-usb-vbus-guard-pack1\n'
	printf 'functional_change=usb_udc_registration_and_configfs_bind_instrumentation_only\n'
	printf 'forbidden_functional_changes=DEFCONFIG,RAMDISK,UFS_DT,DISPLAY,FG_GEN3,CLANG\n'
	printf 'expected_defconfig_sha256=%s\n' "$expected_defconfig"
	sha256sum "$defconfig" "$ufs_dts" \
		"$dwc3_msm_driver" "$dwc3_gadget_driver" "$udc_core" \
		"$configfs_driver" "$out_dir/.config" \
		"$out_dir/Module.symvers" "$out_dir/vmlinux" \
		"$out_dir/System.map" "$out_dir/arch/arm64/boot/Image" \
		"$out_dir/arch/arm64/boot/Image.gz" \
		"$out_dir/arch/arm64/boot/dts/rmx1901/sdm710.dtb" \
		"$out_dir/r014-overlay46-merged.dtb"
} >"$summary"

printf 'r022 USB UDC instrumentation build: PASS\n'
