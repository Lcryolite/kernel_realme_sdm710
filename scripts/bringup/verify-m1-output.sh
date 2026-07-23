#!/usr/bin/env bash
set -euo pipefail

repo=$(git rev-parse --show-toplevel)
out_dir=${1:-${OUT_DIR:-$repo/out-donor-control}}
baseline="$repo/bringup/baselines/M1-warnings.txt"

for file in \
	.config \
	defconfig \
	build.log \
	arch/arm64/boot/Image \
	arch/arm64/boot/Image.gz \
	vmlinux \
	System.map; do
	[[ -f "$out_dir/$file" ]] || {
		printf 'ERROR: missing %s\n' "$out_dir/$file" >&2
		exit 1
	}
done

if grep -Eiq 'error:|fatal error|^make(\[[0-9]+\])?: \*\*\*' "$out_dir/build.log"; then
	printf 'ERROR: build log contains a fatal diagnostic\n' >&2
	exit 1
fi

grep -Ei 'warning:' "$out_dir/build.log" >"$out_dir/warnings.normalized.txt" || true
diff -u "$baseline" "$out_dir/warnings.normalized.txt"

[[ $(find "$out_dir/arch/arm64/boot/dts" -type f -name '*.dtb' | wc -l) -eq 15 ]]
[[ $(find "$out_dir/arch/arm64/boot/dts" -type f -name '*.dtbo' | wc -l) -eq 23 ]]
[[ $(find "$out_dir" -type f -name '*.ko' | wc -l) -eq 3 ]]
gzip -t "$out_dir/arch/arm64/boot/Image.gz"

sha256sum \
	"$out_dir/.config" \
	"$out_dir/defconfig" \
	"$out_dir/arch/arm64/boot/Image" \
	"$out_dir/arch/arm64/boot/Image.gz" \
	"$out_dir/vmlinux" \
	"$out_dir/System.map" \
	>"$out_dir/SHA256SUMS"

printf 'M1 donor control: PASS\n'
cat "$out_dir/SHA256SUMS"
