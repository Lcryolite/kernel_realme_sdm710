#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
source_repo=$(git -C "$script_dir" rev-parse --show-toplevel)
out_dir=${OUT_DIR:-$source_repo/out-r015-sdm670-irq-catalog}
catalog_source="$source_repo/drivers/gpu/drm/msm/sde/sde_hw_catalog.c"
catalog_header="$source_repo/drivers/gpu/drm/msm/sde/sde_hw_catalog.h"
poweroff_source="$source_repo/drivers/power/reset/msm-poweroff.c"

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

# r014 proved that the first ten banks complete and that the first uncompleted
# write is MDSS_INTF_TEAR_1_INTR at 0x6e808.  SDM670 is SDE 4.1 and uses the
# ping-pong TE path; the separate interface-TE banks begin with SDE 5.0.
grep -Fq '#define IS_SDM670_TARGET(rev) IS_SDE_MAJOR_MINOR_SAME((rev), SDE_HW_VER_410)' \
	"$catalog_header" || die "SDM670 is no longer identified as SDE 4.1"
grep -Fq 'IS_SDE_MAJOR_SAME((sde_cfg->hwversion), SDE_HW_VER_500)' \
	"$catalog_source" || die "interface-TE revision gate is missing"

for line in \
	'clear_bit(MDSS_INTF_TEAR_1_INTR, sde_cfg->mdss_irqs);' \
	'clear_bit(MDSS_INTF_TEAR_2_INTR, sde_cfg->mdss_irqs);' \
	'RMX1901-R015: SDM670 interface-TE IRQ banks disabled'; do
	grep -Fq "$line" "$catalog_source" ||
		die "missing r015 SDM670 IRQ catalog line: $line"
done

clear_count=$(sed -n '/IS_SDM670_TARGET(hw_rev)/,/IS_SM8150_TARGET(hw_rev)/p' \
	"$catalog_source" | grep -Fc 'clear_bit(MDSS_INTF_TEAR_')
[[ $clear_count -eq 2 ]] ||
	die "expected exactly two SDM670 interface-TE IRQ capability clears, found $clear_count"

grep -Fq 'WDOG_BITE_ON_PANIC && in_panic && !bringup_panic_recovery' \
	"$poweroff_source" ||
	die "panic auto-Recovery still takes the forced watchdog-bite path"
grep -Fq 'RMX1901-AUTORECOVERY: stage=restart-execute path=ps-hold' \
	"$poweroff_source" || die "panic PS_HOLD execution marker is missing"

# Keep the r014 register-boundary instrumentation and panic safety code so the
# next device run proves that the ten-bank loop reaches its existing barrier.
OUT_DIR="$out_dir" "$script_dir/build-r014-panic-autorecovery.sh"

grep -aFq 'RMX1901-R015: SDM670 interface-TE IRQ banks disabled' \
	"$out_dir/vmlinux" || die "built vmlinux is missing the r015 catalog marker"
grep -aFq 'RMX1901-AUTORECOVERY: stage=restart-execute path=ps-hold' \
	"$out_dir/vmlinux" || die "built vmlinux is missing the panic PS_HOLD marker"

summary="$out_dir/r015-gate-summary.txt"
{
	printf 'source_commit=%s\n' "$(git -C "$source_repo" rev-parse HEAD)"
	printf 'source_tree_clean=%s\n' \
		"$([[ -z $(git -C "$source_repo" status --porcelain) ]] && printf PASS || printf DIRTY_ALLOWED)"
	printf 'candidate_kind=SDM670_IRQ_CATALOG_CORRECTION\n'
	printf 'r014_last_trusted_bank=MDSS_INTF_TEAR_1_INTR_0x6e808\n'
	printf 'sdm670_sde_revision=4.1\n'
	printf 'interface_te_revision_floor=5.0\n'
	printf 'known_good_4_9_irq_bank_count=10\n'
	printf 'candidate_irq_bank_count=10\n'
	printf 'cleared_capabilities=MDSS_INTF_TEAR_1_INTR,MDSS_INTF_TEAR_2_INTR\n'
	printf 'pingpong_te_path=PRESERVED\n'
	printf 'r014_boundary_markers=PRESERVED\n'
	printf 'panic_autorecovery_code=PRESERVED_BUT_NOT_PROVEN_EFFECTIVE\n'
	printf 'panic_forced_watchdog_bite=DISABLED_WHEN_AUTORECOVERY_ENABLED\n'
	printf 'panic_reset_execution=PS_HOLD_WHEN_AUTORECOVERY_ENABLED\n'
	sha256sum "$out_dir/.config" "$out_dir/Module.symvers" \
		"$out_dir/vmlinux" "$out_dir/System.map" \
		"$out_dir/arch/arm64/boot/Image" \
		"$out_dir/arch/arm64/boot/Image.gz" \
		"$out_dir/arch/arm64/boot/dts/rmx1901/sdm710.dtb" \
		"$out_dir/r014-overlay46-merged.dtb"
} >"$summary"

printf 'r015 SDM670 IRQ catalog build: PASS\n'
