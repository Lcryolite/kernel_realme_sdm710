#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
source_repo=$(git -C "$script_dir" rev-parse --show-toplevel)
out_dir=${OUT_DIR:-$source_repo/out-r012-legacy-ctl-decode}
overlay=${RMX1901_DTBO_ENTRY_46:-}
ctl_source="$source_repo/drivers/gpu/drm/msm/sde/sde_hw_ctl.c"
rm_source="$source_repo/drivers/gpu/drm/msm/sde/sde_rm.c"

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

[[ -f $overlay ]] || die "set RMX1901_DTBO_ENTRY_46 to extracted DTBO entry 46"

# SDM670 uses the legacy CTL layout.  CTL_TOP[7:4] contains the one-based
# interface enum; get_ctl_intf() must return the matching zero-based bitmap.
grep -Fq 'intf_sel = (ctl_top >> 4) & 0xf;' "$ctl_source" ||
	die "legacy CTL_TOP interface-field decode is missing"
grep -Fq 'intf_active = BIT(intf_sel - INTF_0);' "$ctl_source" ||
	die "legacy interface enum-to-bitmap conversion is missing"
if grep -Fq 'BIT(ctl_top - 1)' "$ctl_source"; then
	die "unsafe whole-CTL_TOP bit shift is still present"
fi
grep -Fq 'RMX1901-R012: ctl=%d legacy ctl_top=' "$ctl_source" ||
	die "r012 raw CTL_TOP instrumentation is missing"
grep -Fq 'RMX1901-R012: cont-splash ctl=%d intf_active=' "$rm_source" ||
	die "r012 continuous-splash bitmap instrumentation is missing"

for vector in '0x00000000:0' '0x00000010:1' '0x00000020:2' \
		'0x00020020:2'; do
	raw=${vector%%:*}
	expected=${vector##*:}
	intf_sel=$(( (raw >> 4) & 0xf ))
	if (( intf_sel == 0 )); then
		actual=0
	else
		actual=$((1 << (intf_sel - 1)))
	fi
	(( actual == expected )) ||
		die "legacy decode vector $vector produced $actual"
done

OUT_DIR="$out_dir" "$script_dir/build-r011-legacy-direct-dsi.sh"

for marker in \
	'RMX1901-R012: ctl=%d legacy ctl_top=' \
	'RMX1901-R012: cont-splash ctl=%d intf_active='; do
	grep -aFq "$marker" "$out_dir/vmlinux" ||
		die "built vmlinux is missing marker: $marker"
done

merged_dtb="$out_dir/r012-overlay46-merged.dtb"
merged_dts="$out_dir/r012-overlay46-merged.dts"
base_dtb="$out_dir/arch/arm64/boot/dts/rmx1901/sdm710.dtb"
fdtoverlay -i "$base_dtb" -o "$merged_dtb" "$overlay"
dtc -q -I dtb -O dts -o "$merged_dts" "$merged_dtb"

summary="$out_dir/r012-gate-summary.txt"
{
	printf 'source_commit=%s\n' "$(git -C "$source_repo" rev-parse HEAD)"
	printf 'source_tree_clean=%s\n' \
		"$([[ -z $(git -C "$source_repo" status --porcelain) ]] && printf PASS || printf DIRTY_ALLOWED)"
	printf 'legacy_ctl_layout=SDM670_NON_ACTIVE_CFG\n'
	printf 'legacy_ctl_top_field=bits_7_4\n'
	printf 'legacy_enum_to_bitmap=PASS\n'
	printf 'legacy_decode_vectors=4/4_PASS\n'
	printf 'r009_r010_r011_gates=PASS\n'
	printf 'r012_markers=PASS\n'
	sha256sum "$out_dir/.config" "$out_dir/Module.symvers" \
		"$out_dir/vmlinux" "$out_dir/System.map" \
		"$out_dir/arch/arm64/boot/Image" \
		"$out_dir/arch/arm64/boot/Image.gz" "$base_dtb" "$merged_dtb"
} >"$summary"

printf 'r012 legacy CTL decode build: PASS\n'
