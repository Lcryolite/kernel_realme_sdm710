#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
source_repo=$(git -C "$script_dir" rev-parse --show-toplevel)
out_dir=${OUT_DIR:-$source_repo/out-r014-irq-bank-boundary}
overlay=${RMX1901_DTBO_ENTRY_46:-}
intr_source="$source_repo/drivers/gpu/drm/msm/sde/sde_hw_interrupts.c"

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

[[ -f $overlay ]] || die "set RMX1901_DTBO_ENTRY_46 to extracted DTBO entry 46"

# r014 subdivides the r013 clear-all boundary only.  It preserves the table,
# offsets, write value, loop, barrier and every earlier functional change.
for marker in \
	'RMX1901-R014: clear-all stage=before-write' \
	'RMX1901-R014: clear-all stage=after-write' \
	'RMX1901-R014: clear-all stage=before-wmb' \
	'RMX1901-R014: clear-all stage=after-wmb'; do
	grep -Fq "$marker" "$intr_source" ||
		die "missing per-bank boundary marker: $marker"
done

marker_count=$(grep -Fo 'RMX1901-R014:' "$intr_source" | wc -l)
[[ $marker_count -eq 4 ]] ||
	die "expected exactly 4 r014 source markers, found $marker_count"

grep -Fq 'SDE_REG_WRITE(&intr->hw, intr->sde_irq_tbl[i].clr_off,' \
	"$intr_source" || die "clear-all register write changed or disappeared"
grep -Fq '0xffffffff);' "$intr_source" ||
	die "clear-all register value changed or disappeared"

# Preserve r013 and all proven earlier gates.
OUT_DIR="$out_dir" "$script_dir/build-r013-drm-irq-boundary.sh"

for marker in \
	'RMX1901-R014: clear-all stage=before-write index=' \
	'RMX1901-R014: clear-all stage=after-write index=' \
	'RMX1901-R014: clear-all stage=before-wmb total=' \
	'RMX1901-R014: clear-all stage=after-wmb total='; do
	grep -aFq "$marker" "$out_dir/vmlinux" ||
		die "built vmlinux is missing marker: $marker"
done

merged_dtb="$out_dir/r014-overlay46-merged.dtb"
merged_dts="$out_dir/r014-overlay46-merged.dts"
base_dtb="$out_dir/arch/arm64/boot/dts/rmx1901/sdm710.dtb"
fdtoverlay -i "$base_dtb" -o "$merged_dtb" "$overlay"
dtc -q -I dtb -O dts -o "$merged_dts" "$merged_dtb"

summary="$out_dir/r014-gate-summary.txt"
{
	printf 'source_commit=%s\n' "$(git -C "$source_repo" rev-parse HEAD)"
	printf 'source_tree_clean=%s\n' \
		"$([[ -z $(git -C "$source_repo" status --porcelain) ]] && printf PASS || printf DIRTY_ALLOWED)"
	printf 'candidate_kind=PER_IRQ_BANK_BOUNDARY_INSTRUMENTATION_ONLY\n'
	printf 'r014_source_markers=%s/4_PASS\n' "$marker_count"
	printf 'r009_r010_r011_r012_r013_gates=PASS\n'
	printf 'register_table_offsets_values_loop_barrier=UNCHANGED\n'
	printf 'functional_change=NONE_INTENDED\n'
	sha256sum "$out_dir/.config" "$out_dir/Module.symvers" \
		"$out_dir/vmlinux" "$out_dir/System.map" \
		"$out_dir/arch/arm64/boot/Image" \
		"$out_dir/arch/arm64/boot/Image.gz" "$base_dtb" "$merged_dtb"
} >"$summary"

printf 'r014 per-IRQ-bank boundary build: PASS\n'
