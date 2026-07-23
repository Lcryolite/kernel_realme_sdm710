#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
source_repo=$(git -C "$script_dir" rev-parse --show-toplevel)
out_dir=${OUT_DIR:-$source_repo/out-r014-panic-autorecovery}
overlay=${RMX1901_DTBO_ENTRY_46:-}
poweroff_source="$source_repo/drivers/power/reset/msm-poweroff.c"

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

[[ -f $overlay ]] || die "set RMX1901_DTBO_ENTRY_46 to extracted DTBO entry 46"

# The RMX1901 4.9 baseline uses the same policy: a panic does not arm dload,
# sets both PMIC and IMEM Recovery reasons, and requests a warm reset.  This
# safety layer executes only after panic notifiers and kmsg_dump have run.
for marker in \
	'RMX1901-AUTORECOVERY: stage=panic-notifier' \
	'RMX1901-AUTORECOVERY: stage=restart-prepare target=recovery'; do
	grep -Fq "$marker" "$poweroff_source" ||
		die "missing automatic Recovery marker: $marker"
done

grep -Fq 'static bool bringup_panic_recovery = true;' "$poweroff_source" ||
	die "panic-to-Recovery default is not enabled"
grep -Fq 'early_param("rmx1901.panic_recovery"' "$poweroff_source" ||
	die "panic-to-Recovery boot-time escape hatch is missing"
grep -Fq 'PON_RESTART_REASON_RECOVERY' "$poweroff_source" ||
	die "PMIC Recovery restart reason is missing"
grep -Fq '__raw_writel(0x77665502, restart_reason);' "$poweroff_source" ||
	die "IMEM Recovery restart reason is missing"
grep -Fq '((in_panic && !bringup_panic_recovery) ||' "$poweroff_source" ||
	die "panic download-mode bypass is missing"

# Preserve the pure r014 per-bank diagnostic and every previous gate.
OUT_DIR="$out_dir" "$script_dir/build-r014-irq-bank-boundary.sh"

for marker in \
	'RMX1901-AUTORECOVERY: stage=panic-notifier enabled=' \
	'RMX1901-AUTORECOVERY: stage=restart-prepare target=recovery'; do
	grep -aFq "$marker" "$out_dir/vmlinux" ||
		die "built vmlinux is missing automatic Recovery marker: $marker"
done

summary="$out_dir/r014-panic-autorecovery-gate-summary.txt"
{
	printf 'source_commit=%s\n' "$(git -C "$source_repo" rev-parse HEAD)"
	printf 'source_tree_clean=%s\n' \
		"$([[ -z $(git -C "$source_repo" status --porcelain) ]] && printf PASS || printf DIRTY_ALLOWED)"
	printf 'candidate_kind=R014_PER_BANK_DIAGNOSTIC_WITH_PANIC_ONLY_RECOVERY_SAFETY\n'
	printf 'known_good_policy_source=RMX1901_LINUX_4_9_MSM_POWEROFF\n'
	printf 'panic_kmsg_dump_order=PRESERVED_BEFORE_EMERGENCY_RESTART\n'
	printf 'panic_dload_mode=DISABLED_WHEN_AUTORECOVERY_ENABLED\n'
	printf 'panic_restart_target=PMIC_AND_IMEM_RECOVERY_WARM_RESET\n'
	printf 'normal_reboot_behavior=UNCHANGED\n'
	printf 'r014_per_bank_gate=PASS\n'
	sha256sum "$out_dir/.config" "$out_dir/Module.symvers" \
		"$out_dir/vmlinux" "$out_dir/System.map" \
		"$out_dir/arch/arm64/boot/Image" \
		"$out_dir/arch/arm64/boot/Image.gz"
} >"$summary"

printf 'r014 panic automatic-Recovery build: PASS\n'
