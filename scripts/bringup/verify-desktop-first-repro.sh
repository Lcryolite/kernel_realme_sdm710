#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
source_repo=$(git -C "$script_dir" rev-parse --show-toplevel)
first_out=${FIRST_OUT_DIR:-$source_repo/out-desktop-first-clean1}
second_out=${SECOND_OUT_DIR:-$source_repo/out-desktop-first-clean2}
build_script="$script_dir/build-desktop-first.sh"
summary="$source_repo/desktop-first-repro-summary.txt"

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

[[ "$first_out" != "$second_out" ]] || die "clean build output directories must differ"
[[ ! -e "$first_out" ]] || die "first output path already exists: $first_out"
[[ ! -e "$second_out" ]] || die "second output path already exists: $second_out"

OUT_DIR="$first_out" "$build_script"
OUT_DIR="$second_out" "$build_script"

artifacts=(
	.config
	Module.symvers
	vmlinux
	System.map
	arch/arm64/boot/Image
	arch/arm64/boot/Image.gz
	arch/arm64/boot/dts/rmx1901/sdm710.dtb
	r014-overlay46-merged.dtb
)
for relative_path in "${artifacts[@]}"; do
	first_path="$first_out/$relative_path"
	second_path="$second_out/$relative_path"
	[[ -f "$first_path" && -f "$second_path" ]] ||
		die "reproducibility artifact is missing: $relative_path"
	cmp "$first_path" "$second_path" ||
		die "clean builds differ: $relative_path"
done

{
	printf 'candidate_kind=DESKTOP_FIRST\n'
	printf 'first_output=%s\n' "$first_out"
	printf 'second_output=%s\n' "$second_out"
	printf 'comparison=PASS\n'
	printf 'source_commit=%s\n' "$(git -C "$source_repo" rev-parse HEAD)"
	for relative_path in "${artifacts[@]}"; do
		sha256sum "$first_out/$relative_path"
	done
} >"$summary"

printf 'desktop-first reproducibility: PASS\n'
printf 'summary: %s\n' "$summary"
