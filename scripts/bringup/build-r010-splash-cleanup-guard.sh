#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
source_repo=$(git -C "$script_dir" rev-parse --show-toplevel)
out_dir=${OUT_DIR:-$source_repo/out-r010-splash-cleanup-guard}

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

# r010 keeps r009's full context-bank rewrite and changes only the failed
# continuous-splash validation cleanup when no real DSI display has been
# enumerated.  Every cleanup source remains visible so the device trace can
# prove or falsify the probable cleanup-unmap hypothesis.
grep -q 'RMX1901-R010: splash-put request reason=' \
	"$source_repo/drivers/gpu/drm/msm/sde/sde_kms.c" ||
	die "splash cleanup source instrumentation is missing"
grep -q 'RMX1901-R010: splash-put preserved reason=' \
	"$source_repo/drivers/gpu/drm/msm/sde/sde_kms.c" ||
	die "no-DSI splash preservation guard is missing"
grep -q 'cont-splash-validation-failure' \
	"$source_repo/drivers/gpu/drm/msm/sde/sde_kms.c" ||
	die "continuous-splash cleanup reason is missing"
grep -q '"kms-destroy", false' \
	"$source_repo/drivers/gpu/drm/msm/sde/sde_kms.c" ||
	die "KMS destroy must retain its original cleanup semantics"
grep -A1 '"early-map-failure", false' \
	"$source_repo/drivers/gpu/drm/msm/sde/sde_kms.c" >/dev/null ||
	die "early-map failure must retain its original cleanup semantics"
grep -A1 '"cont-splash-validation-failure", true' \
	"$source_repo/drivers/gpu/drm/msm/sde/sde_kms.c" >/dev/null ||
	die "only failed continuous-splash validation may preserve the mapping"
grep -q 'RMX1901-R010: identity-unmap' \
	"$source_repo/drivers/gpu/drm/msm/msm_smmu.c" ||
	die "identity-unmap instrumentation is missing"
grep -q 'RMX1901-R010: cont-splash final' \
	"$source_repo/drivers/gpu/drm/msm/sde/sde_rm.c" ||
	die "continuous-splash resource instrumentation is missing"

if [[ ${VERIFY_ONLY:-0} == 1 ]]; then
	[[ -s $out_dir/vmlinux ]] || die "VERIFY_ONLY requires an existing vmlinux"
else
	OUT_DIR="$out_dir" "$script_dir/build-r009-smmu-context-rewrite.sh"
fi

for marker in \
	'RMX1901-R010: splash-map-state stage=' \
	'RMX1901-R010: splash-put request reason=' \
	'RMX1901-R010: splash-put preserved reason=' \
	'RMX1901-R010: identity-unmap' \
	'RMX1901-R010: cont-splash final' \
	'RMX1901-R009: enable S1 with full context-bank rewrite'; do
	grep -aFq "$marker" "$out_dir/vmlinux" ||
		die "built vmlinux is missing marker: $marker"
done

printf 'r010 splash cleanup guard build: PASS\n'
