#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
source_repo=$(git -C "$script_dir" rev-parse --show-toplevel)
out_dir=${OUT_DIR:-$source_repo/out-r023-usb-core-boundary}
defconfig="$source_repo/arch/arm64/configs/vendor/rmx1901_m2_defconfig"
expected_defconfig=4d66954ad1d0777f2e1758feeaf993371e88e60fb223b991f88135615de1f0fb
ufs_dts="$source_repo/arch/arm64/boot/dts/rmx1901/sdm670.dtsi"
usb_common_dts="$source_repo/arch/arm64/boot/dts/rmx1901/sdm845-670-usb-common.dtsi"
dwc3_msm_driver="$source_repo/drivers/usb/dwc3/dwc3-msm.c"
dwc3_gadget_driver="$source_repo/drivers/usb/dwc3/gadget.c"
dwc3_core_driver="$source_repo/drivers/usb/dwc3/core.c"
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
if grep -Fq 'dr_mode = "otg"' "$usb_common_dts"; then
	die "r023 must not add explicit dr_mode to the USB DTS"
fi
if grep -Fq 'maximum-speed = "super-speed"' "$usb_common_dts"; then
	die "r023 must not add maximum-speed to the USB DTS"
fi

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

grep -Fq 'RMX1901-R023-CORE: props' "$dwc3_core_driver" ||
	die "tracked dwc3 core is missing the r023 property log"
grep -Fq 'RMX1901-R023-CORE: core_init enter' "$dwc3_core_driver" ||
	die "tracked dwc3 core is missing the r023 core_init entry log"
grep -Fq 'RMX1901-R023-CORE: dr_mode resolved' "$dwc3_core_driver" ||
	die "tracked dwc3 core is missing the r023 dr_mode resolution log"
grep -Fq 'RMX1901-R023-CORE: gadget gate' "$dwc3_core_driver" ||
	die "tracked dwc3 core is missing the r023 gadget gate log"

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

summary="$out_dir/r023-gate-summary.txt"
{
	printf 'source_commit=%s\n' "$(git -C "$source_repo" rev-parse HEAD)"
	printf 'source_tree_clean=%s\n' \
		"$([[ -z $(git -C "$source_repo" status --porcelain) ]] && printf PASS || printf DIRTY_ALLOWED)"
	printf 'candidate_kind=USB_CORE_BOUNDARY_INSTRUMENTATION\n'
	printf 'baseline_candidate=B14-M03-r022-usb-udc-instrumentation-pack1\n'
	printf 'functional_change=dwc3_probe_and_core_init_boundary_instrumentation_only\n'
	printf 'forbidden_functional_changes=DEFCONFIG,RAMDISK,UFS_DT,USB_DTS_BEHAVIOR,DISPLAY,FG_GEN3,CLANG\n'
	printf 'expected_defconfig_sha256=%s\n' "$expected_defconfig"
	sha256sum "$defconfig" "$ufs_dts" "$usb_common_dts" \
		"$dwc3_msm_driver" "$dwc3_gadget_driver" "$dwc3_core_driver" \
		"$udc_core" "$configfs_driver" "$out_dir/.config" \
		"$out_dir/Module.symvers" "$out_dir/vmlinux" \
		"$out_dir/System.map" "$out_dir/arch/arm64/boot/Image" \
		"$out_dir/arch/arm64/boot/Image.gz" \
		"$out_dir/arch/arm64/boot/dts/rmx1901/sdm710.dtb" \
		"$out_dir/r014-overlay46-merged.dtb"
} >"$summary"

printf 'r023 USB core boundary instrumentation build: PASS\n'
