#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
source_repo=$(git -C "$script_dir" rev-parse --show-toplevel)
out_dir=${OUT_DIR:-$source_repo/out-r013-drm-irq-boundary}
overlay=${RMX1901_DTBO_ENTRY_46:-}
msm_source="$source_repo/drivers/gpu/drm/msm/msm_drv.c"
sde_irq_source="$source_repo/drivers/gpu/drm/msm/sde/sde_irq.c"
sde_core_irq_source="$source_repo/drivers/gpu/drm/msm/sde/sde_core_irq.c"

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

[[ -f $overlay ]] || die "set RMX1901_DTBO_ENTRY_46 to extracted DTBO entry 46"

# r013 is a boundary-only diagnostic candidate.  These markers distinguish
# vblank return, runtime PM, DRM IRQ installation, SDE register clearing,
# request_irq/postinstall, DRM registration and the first actual IRQ handler.
for marker in \
	'RMX1901-R013: drm-init stage=before-vblank-init' \
	'RMX1901-R013: drm-init stage=after-vblank-init' \
	'RMX1901-R013: drm-init stage=before-runtime-pm-get' \
	'RMX1901-R013: drm-init stage=after-runtime-pm-get' \
	'RMX1901-R013: drm-init stage=before-irq-install' \
	'RMX1901-R013: drm-init stage=after-irq-install' \
	'RMX1901-R013: drm-init stage=before-drm-dev-register' \
	'RMX1901-R013: drm-init stage=after-drm-dev-register' \
	'RMX1901-R013: drm-init stage=before-mode-config-reset' \
	'RMX1901-R013: drm-init stage=after-mode-config-reset' \
	'RMX1901-R013: irq-handler stage=first-entry' \
	'RMX1901-R013: irq-handler stage=first-return'; do
	grep -Fq "$marker" "$msm_source" ||
		die "missing MSM boundary marker: $marker"
done

for marker in \
	'RMX1901-R013: sde-irq-preinstall stage=entry' \
	'RMX1901-R013: sde-irq-preinstall stage=before-core' \
	'RMX1901-R013: sde-irq-preinstall stage=after-core' \
	'RMX1901-R013: sde-irq-postinstall stage=before-core' \
	'RMX1901-R013: sde-irq-postinstall stage=after-core'; do
	grep -Fq "$marker" "$sde_irq_source" ||
		die "missing SDE IRQ boundary marker: $marker"
done

for marker in \
	'RMX1901-R013: sde-core-irq-preinstall stage=before-power-enable' \
	'RMX1901-R013: sde-core-irq-preinstall stage=after-power-enable' \
	'RMX1901-R013: sde-core-irq-preinstall stage=before-clear-all' \
	'RMX1901-R013: sde-core-irq-preinstall stage=after-clear-all' \
	'RMX1901-R013: sde-core-irq-preinstall stage=before-disable-all' \
	'RMX1901-R013: sde-core-irq-preinstall stage=after-disable-all' \
	'RMX1901-R013: sde-core-irq-preinstall stage=return'; do
	grep -Fq "$marker" "$sde_core_irq_source" ||
		die "missing SDE core IRQ boundary marker: $marker"
done

marker_count=$(grep -hFo 'RMX1901-R013:' \
	"$msm_source" "$sde_irq_source" "$sde_core_irq_source" | wc -l)
[[ $marker_count -eq 37 ]] ||
	die "expected exactly 37 r013 source markers, found $marker_count"

# Preserve the proven r012 CTL decode and every earlier static/build gate.
OUT_DIR="$out_dir" "$script_dir/build-r012-legacy-ctl-decode.sh"

for marker in \
	'RMX1901-R013: drm-init stage=after-vblank-init rc=' \
	'RMX1901-R013: drm-init stage=after-runtime-pm-get rc=' \
	'RMX1901-R013: drm-init stage=before-irq-install irq=' \
	'RMX1901-R013: sde-core-irq-preinstall stage=before-clear-all' \
	'RMX1901-R013: sde-core-irq-preinstall stage=after-clear-all' \
	'RMX1901-R013: sde-core-irq-preinstall stage=before-disable-all' \
	'RMX1901-R013: sde-core-irq-preinstall stage=after-disable-all' \
	'RMX1901-R013: msm-irq-postinstall stage=return rc=' \
	'RMX1901-R013: irq-handler stage=first-entry irq=' \
	'RMX1901-R013: drm-init stage=after-mode-config-reset'; do
	grep -aFq "$marker" "$out_dir/vmlinux" ||
		die "built vmlinux is missing marker: $marker"
done

merged_dtb="$out_dir/r013-overlay46-merged.dtb"
merged_dts="$out_dir/r013-overlay46-merged.dts"
base_dtb="$out_dir/arch/arm64/boot/dts/rmx1901/sdm710.dtb"
fdtoverlay -i "$base_dtb" -o "$merged_dtb" "$overlay"
dtc -q -I dtb -O dts -o "$merged_dts" "$merged_dtb"

summary="$out_dir/r013-gate-summary.txt"
{
	printf 'source_commit=%s\n' "$(git -C "$source_repo" rev-parse HEAD)"
	printf 'source_tree_clean=%s\n' \
		"$([[ -z $(git -C "$source_repo" status --porcelain) ]] && printf PASS || printf DIRTY_ALLOWED)"
	printf 'candidate_kind=BOUNDARY_INSTRUMENTATION_ONLY\n'
	printf 'r013_source_markers=%s/37_PASS\n' "$marker_count"
	printf 'r009_r010_r011_r012_gates=PASS\n'
	printf 'functional_change=NONE_INTENDED\n'
	sha256sum "$out_dir/.config" "$out_dir/Module.symvers" \
		"$out_dir/vmlinux" "$out_dir/System.map" \
		"$out_dir/arch/arm64/boot/Image" \
		"$out_dir/arch/arm64/boot/Image.gz" "$base_dtb" "$merged_dtb"
} >"$summary"

printf 'r013 DRM/IRQ boundary build: PASS\n'
