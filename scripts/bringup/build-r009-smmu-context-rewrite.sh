#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
source_repo=$(git -C "$script_dir" rev-parse --show-toplevel)
out_dir=${OUT_DIR:-$source_repo/out-r009-smmu-context-rewrite}

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

# Keep r009 to one runtime change: restore the known-good 4.9 full context-bank
# rewrite when the display domain leaves EARLY_MAP.  The extra logs only make
# the map, domain and fault state observable in the next crash dump.
grep -q 'RMX1901-R009: enable S1 with full context-bank rewrite' \
	"$source_repo/drivers/iommu/arm-smmu.c" ||
	die "full context-bank rewrite marker is missing"
grep -q 'arm_smmu_write_context_bank(smmu, cfg->cbndx' \
	"$source_repo/drivers/iommu/arm-smmu.c" ||
	die "full context-bank rewrite call is missing"
grep -q 'RMX1901-R009: identity-map' \
	"$source_repo/drivers/gpu/drm/msm/msm_smmu.c" ||
	die "identity-map instrumentation is missing"
grep -q 'RMX1901-R009: SDE MMU domain=' \
	"$source_repo/drivers/gpu/drm/msm/sde/sde_kms.c" ||
	die "SDE MMU instrumentation is missing"

if [[ ${VERIFY_ONLY:-0} == 1 ]]; then
	[[ -s $out_dir/vmlinux ]] || die "VERIFY_ONLY requires an existing vmlinux"
else
	OUT_DIR="$out_dir" "$script_dir/build-r007-ramoops-probe.sh"
fi

for marker in \
	'RMX1901-R009: enable S1 with full context-bank rewrite' \
	'RMX1901-R009: identity-map' \
	'RMX1901-R009: fault secure=' \
	'RMX1901-R009: SDE MMU domain='; do
	grep -aFq "$marker" "$out_dir/vmlinux" ||
		die "built vmlinux is missing marker: $marker"
done

printf 'r009 SMMU context rewrite build: PASS\n'
