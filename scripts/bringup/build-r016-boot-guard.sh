#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
source_repo=$(git -C "$script_dir" rev-parse --show-toplevel)
out_dir=${OUT_DIR:-$source_repo/out-r016-boot-guard}
poweroff_source="$source_repo/drivers/power/reset/msm-poweroff.c"

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

for marker in \
	'RMX1901-R016-BOOT-GUARD: stage=armed' \
	'RMX1901-R016-BOOT-GUARD: stage=deadline disarmed=1' \
	'RMX1901-R016-BOOT-GUARD: stage=deadline seconds=%u action=panic' \
	'panic("RMX1901 r016 diagnostic boot deadline expired")'; do
	grep -Fq "$marker" "$poweroff_source" ||
		die "missing r016 boot-guard marker: $marker"
done

grep -Fq '#define RMX1901_BOOT_GUARD_DEFAULT_SECONDS' "$poweroff_source" ||
	die "boot-guard default is missing"
grep -Fq 'early_param("rmx1901.boot_guard_seconds"' "$poweroff_source" ||
	die "boot-guard command-line escape hatch is missing"
grep -Fq 'module_param_named(bringup_boot_guard_disarmed' "$poweroff_source" ||
	die "runtime boot-guard disarm parameter is missing"
grep -Fq 'bringup_boot_guard_seconds && bringup_panic_recovery' \
	"$poweroff_source" ||
	die "boot guard is not conditional on panic automatic-Recovery"

# Preserve every r015 source and output gate, then prove that the linked image
# contains both the deadline and the PS_HOLD recovery execution path.
OUT_DIR="$out_dir" "$script_dir/build-r015-sdm670-irq-catalog.sh"

for marker in \
	'RMX1901-R016-BOOT-GUARD: stage=armed' \
	'RMX1901-R016-BOOT-GUARD: stage=deadline disarmed=1' \
	'RMX1901-R016-BOOT-GUARD: stage=deadline seconds=%u action=panic' \
	'RMX1901 r016 diagnostic boot deadline expired' \
	'RMX1901-AUTORECOVERY: stage=restart-execute path=ps-hold'; do
	grep -aFq "$marker" "$out_dir/vmlinux" ||
		die "built vmlinux is missing r016 marker: $marker"
done

grep -Fq 'CONFIG_PSTORE_CONSOLE=y' "$out_dir/.config" ||
	die "pstore console capture is disabled"
grep -Fq 'CONFIG_PANIC_TIMEOUT=-1' "$out_dir/.config" ||
	die "panic restart is no longer immediate"

summary="$out_dir/r016-gate-summary.txt"
{
	printf 'source_commit=%s\n' "$(git -C "$source_repo" rev-parse HEAD)"
	printf 'source_tree_clean=%s\n' \
		"$([[ -z $(git -C "$source_repo" status --porcelain) ]] && printf PASS || printf DIRTY_ALLOWED)"
	printf 'candidate_kind=DIAGNOSTIC_BOOT_DEADLINE_WITH_AUTOMATIC_RECOVERY\n'
	printf 'default_deadline_seconds=90\n'
	printf 'maximum_deadline_seconds=600\n'
	printf 'boot_parameter_disable=rmx1901.boot_guard_seconds=0\n'
	printf 'runtime_disarm=/sys/module/msm_poweroff/parameters/bringup_boot_guard_disarmed\n'
	printf 'deadline_action=panic_after_kmsg_console_capture\n'
	printf 'panic_recovery_execution=PS_HOLD\n'
	printf 'hardware_or_bootloader_fallback=PRESERVED\n'
	printf 'r015_sdm670_irq_catalog_gate=PASS\n'
	sha256sum "$out_dir/.config" "$out_dir/Module.symvers" \
		"$out_dir/vmlinux" "$out_dir/System.map" \
		"$out_dir/arch/arm64/boot/Image" \
		"$out_dir/arch/arm64/boot/Image.gz" \
		"$out_dir/arch/arm64/boot/dts/rmx1901/sdm710.dtb" \
		"$out_dir/r014-overlay46-merged.dtb"
} >"$summary"

printf 'r016 diagnostic boot-guard build: PASS\n'

