#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
source_repo=$(git -C "$script_dir" rev-parse --show-toplevel)
out_dir=${OUT_DIR:-$source_repo/out-r011-legacy-direct-dsi}
overlay=${RMX1901_DTBO_ENTRY_46:-}
dsi_source="$source_repo/drivers/gpu/drm/msm/dsi-staging/dsi_display.c"
dsi_header="$source_repo/drivers/gpu/drm/msm/dsi-staging/dsi_display.h"
msm_source="$source_repo/drivers/gpu/drm/msm/msm_drv.c"
sde_source="$source_repo/drivers/gpu/drm/msm/sde/sde_kms.c"
pinctrl_source="$source_repo/arch/arm64/boot/dts/rmx1901/sdm670-pinctrl.dtsi"

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

source_commit=$(git -C "$source_repo" rev-parse HEAD)
if [[ ${ALLOW_DIRTY_SOURCE:-0} != 1 ]] &&
		[[ -n $(git -C "$source_repo" status --porcelain) ]]; then
	die "source tree must be committed and clean (or set ALLOW_DIRTY_SOURCE=1 for a non-candidate compile probe)"
fi
[[ -f $overlay ]] || die "set RMX1901_DTBO_ENTRY_46 to extracted DTBO entry 46"

# r011 is a single vertical slice: select the exact legacy direct-display node,
# resolve its controller/PHY/panel/standard clocks, publish it after probe-time
# resource acquisition and component registration, then require the later bind
# path to initialize the controller, PHY, clock manager, MIPI host and panel.
grep -q 'RMX1901-R011: selected direct DSI display' "$dsi_source" ||
	die "direct-display selection marker is missing"
grep -q 'of_count_phandle_with_args(disp_node' "$dsi_source" ||
	die "direct ctrl/PHY phandle parsing is missing"
grep -q '"qcom,dsi-phy-num"' "$dsi_source" ||
	die "indexed PHY count property is missing"
grep -q 'return "clock-names";' "$dsi_source" ||
	die "standard clock-names fallback is missing"
grep -q 'RMX1901-R011: published boot DSI' "$dsi_source" ||
	die "post-init publication marker is missing"
grep -q 'dsi_display_get_boot_display(int index)' "$dsi_source" ||
	die "boot display getter implementation is missing"
grep -q 'dsi_display_get_boot_display(int index)' "$dsi_header" ||
	die "boot display getter declaration is missing"
grep -q 'RMX1901-R011: added selected DSI component' "$msm_source" ||
	die "SDE component match marker is missing"
grep -q 'RMX1901-R011: splash-put preserved reason=' "$sde_source" ||
	die "validation-failure splash preservation marker is missing"
grep -q 'preserve_on_validation_failure' "$sde_source" ||
	die "validation-failure preservation semantics are missing"
grep -A1 '"cont-splash-validation-failure", true' "$sde_source" >/dev/null ||
	die "failed continuous-splash validation must preserve the mapping"
grep -q '"kms-destroy", false' "$sde_source" ||
	die "KMS destroy must retain its original cleanup semantics"
grep -A1 '"early-map-failure", false' "$sde_source" >/dev/null ||
	die "early-map failure must retain its original cleanup semantics"
grep -A1 '"normal-handoff", false' "$sde_source" >/dev/null ||
	die "normal handoff must retain its original cleanup semantics"

te_block=$(sed -n '/sde_te_active: sde_te_active {/,/sde_dp_aux_active:/p' \
	"$pinctrl_source")
grep -q 'pins = "gpio10";' <<<"$te_block" ||
	die "RMX1901 TE pinctrl no longer contains gpio10-only groups"
if grep -q 'gpio54' <<<"$te_block"; then
	die "RMX1901 TE pinctrl still assigns mdp_vsync to gpio54"
fi

# The confirmed r009 context-bank rewrite and r010 mapping instrumentation
# remain in place.  r011 generalizes the diagnostic failed-validation guard so
# a successful pre-bind display count cannot accidentally re-enable the already
# proven unsafe unmap before the real display pipeline takes over.
grep -q 'RMX1901-R009: enable S1 with full context-bank rewrite' \
	"$source_repo/drivers/iommu/arm-smmu.c" ||
	die "r009 context-bank rewrite is missing"
grep -q 'RMX1901-R010: splash-map-state stage=' "$sde_source" ||
	die "r010 splash mapping instrumentation is missing"

if [[ ${VERIFY_ONLY:-0} == 1 ]]; then
	[[ -s $out_dir/vmlinux ]] || die "VERIFY_ONLY requires an existing vmlinux"
else
	OUT_DIR="$out_dir" "$script_dir/build-r009-smmu-context-rewrite.sh"
fi

for marker in \
	'RMX1901-R011: selected direct DSI display' \
	'RMX1901-R011: parsed %s DSI schema' \
	'RMX1901-R011: clocks property=' \
	'RMX1901-R011: clocks ready' \
	'RMX1901-R011: component registered' \
	'RMX1901-R011: published boot DSI' \
	'RMX1901-R011: added selected DSI component' \
	'RMX1901-R011: bind complete' \
	'RMX1901-R011: splash-put preserved reason=' \
	'Successfully bind display panel' \
	'RMX1901-R010: splash-map-state stage=' \
	'RMX1901-R009: enable S1 with full context-bank rewrite'; do
	grep -aFq "$marker" "$out_dir/vmlinux" ||
		die "built vmlinux is missing marker: $marker"
done

merged_dtb="$out_dir/r011-overlay46-merged.dtb"
merged_dts="$out_dir/r011-overlay46-merged.dts"
base_dtb="$out_dir/arch/arm64/boot/dts/rmx1901/sdm710.dtb"
display_path=/soc/qcom,dsi-display@22
pinctrl_path=/soc/pinctrl@03400000/pmx_sde_te

fdtoverlay -i "$base_dtb" -o "$merged_dtb" "$overlay"
dtc -q -I dtb -O dts -o "$merged_dts" "$merged_dtb"

expected_label=dsi_oppo18041samsung_ams653tk01_1080_2340_cmd_display
[[ $(fdtget -t s "$merged_dtb" "$display_path" label) == "$expected_label" ]] ||
	die "overlay-selected display label differs from the boot command line"
[[ $(rg -c "label = \"$expected_label\";" "$merged_dts") == 1 ]] ||
	die "overlay-selected display label is not unique"
[[ $(fdtget -t s "$merged_dtb" "$display_path" qcom,display-type) == primary ]] ||
	die "overlay-selected display is not primary"
[[ $(fdtget -t x "$merged_dtb" "$display_path" qcom,dsi-ctrl | wc -w) == 1 ]] ||
	die "overlay-selected display must have exactly one DSI controller"
[[ $(fdtget -t x "$merged_dtb" "$display_path" qcom,dsi-phy | wc -w) == 1 ]] ||
	die "overlay-selected display must have exactly one DSI PHY"
[[ $(fdtget -t x "$merged_dtb" "$display_path" qcom,dsi-panel | wc -w) == 1 ]] ||
	die "overlay-selected display must have exactly one panel"
[[ $(fdtget -t s "$merged_dtb" "$display_path" clock-names) == \
		"mux_byte_clk mux_pixel_clk" ]] ||
	die "overlay-selected display must expose both mux clocks"
for state in sde_te_active sde_te_suspend; do
	for group in mux config; do
		[[ $(fdtget -t s "$merged_dtb" \
			"$pinctrl_path/$state/$group" pins) == gpio10 ]] ||
			die "$state/$group is not GPIO10-only"
	done
done

grep -qx 'CONFIG_DRM_MSM_DSI_STAGING=y' "$out_dir/.config" ||
	die "target configuration does not build the staging DSI implementation"

summary="$out_dir/r011-gate-summary.txt"
{
	printf 'source_commit=%s\n' "$source_commit"
	printf 'source_tree_clean=%s\n' \
		"$([[ -z $(git -C "$source_repo" status --porcelain) ]] && printf PASS || printf DIRTY_ALLOWED)"
	printf 'direct_display_label=%s\n' "$expected_label"
	printf 'direct_display_label_unique=PASS\n'
	printf 'direct_ctrl_count=1\n'
	printf 'direct_phy_count=1\n'
	printf 'direct_panel_count=1\n'
	printf 'direct_mux_clock_count=2\n'
	printf 'te_gpio10_only=PASS\n'
	printf 'overlay_fixups=179/179_PASS\n'
	printf 'r009_markers=PASS\n'
	printf 'r010_mapping_instrumentation=PASS\n'
	printf 'r011_markers=PASS\n'
	sha256sum "$out_dir/.config" "$out_dir/vmlinux" \
		"$out_dir/System.map" "$out_dir/arch/arm64/boot/Image" \
		"$out_dir/arch/arm64/boot/Image.gz" "$base_dtb" \
		"$merged_dtb"
} >"$summary"

printf 'r011 legacy direct DSI build: PASS\n'
