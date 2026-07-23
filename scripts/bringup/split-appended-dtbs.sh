#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0

set -euo pipefail

usage() {
	cat >&2 <<'EOF'
Usage: split-appended-dtbs.sh KERNEL_PAYLOAD OUTPUT_DIRECTORY

Split an RMX1901 boot kernel payload into its kernel image and consecutive
appended DTBs.  The output directory must not already exist.

Optional environment:
  KERNEL_IMAGE_FORMAT    gzip (default) or arm64-image
EOF
}

if [[ $# -ne 2 ]]; then
	usage
	exit 2
fi

payload=$1
output_dir=$2
kernel_format=${KERNEL_IMAGE_FORMAT:-gzip}

if [[ ! -f $payload ]]; then
	echo "error: kernel payload does not exist: $payload" >&2
	exit 1
fi

if [[ -e $output_dir ]]; then
	echo "error: output path already exists: $output_dir" >&2
	exit 1
fi

for tool in dd fdtget grep gzip od sha256sum stat; do
	if ! command -v "$tool" >/dev/null 2>&1; then
		echo "error: required tool is unavailable: $tool" >&2
		exit 1
	fi
done

case $kernel_format in
	gzip)
		image_name=Image.gz
		;;
	arm64-image)
		image_name=Image
		;;
	*)
		echo "error: KERNEL_IMAGE_FORMAT must be gzip or arm64-image" >&2
		exit 1
		;;
esac

payload_size=$(stat -c '%s' "$payload")
if (( payload_size < 40 )); then
	echo "error: kernel payload is too small" >&2
	exit 1
fi

scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT

read_be32() {
	local file=$1
	local offset=$2
	local -a bytes

	read -r -a bytes <<<"$(od -An -j "$offset" -N 4 -tu1 "$file")"
	if [[ ${#bytes[@]} -ne 4 ]]; then
		return 1
	fi
	printf '%u\n' "$((
		(bytes[0] << 24) |
		(bytes[1] << 16) |
		(bytes[2] << 8) |
		bytes[3]
	))"
}

validate_chain() {
	local start=$1
	local position=$start
	local index=0
	local total_size
	local end
	local magic
	local probe

	while (( position < payload_size )); do
		magic=$(od -An -j "$position" -N 4 -tx1 "$payload" | tr -d ' \n')
		[[ $magic == d00dfeed ]] || return 1
		total_size=$(read_be32 "$payload" "$((position + 4))") || return 1
		(( total_size >= 40 )) || return 1
		end=$((position + total_size))
		(( end <= payload_size )) || return 1

		probe="$scratch/probe-$index.dtb"
		dd if="$payload" of="$probe" bs=1 skip="$position" \
			count="$total_size" status=none
		fdtget -l "$probe" / >/dev/null 2>&1 || return 1

		position=$end
		index=$((index + 1))
	done

	(( position == payload_size && index > 0 ))
}

mapfile -t magic_offsets < <(
	LC_ALL=C grep -aob $'\xD0\x0D\xFE\xED' "$payload" |
		cut -d: -f1
)

dtb_start=
for offset in "${magic_offsets[@]}"; do
	if validate_chain "$offset"; then
		dtb_start=$offset
		break
	fi
done

if [[ -z $dtb_start ]]; then
	echo "error: no consecutive appended-DTB chain reaches the payload end" >&2
	exit 1
fi

mkdir "$output_dir"
image_path="$output_dir/$image_name"
dd if="$payload" of="$image_path" bs=1 count="$dtb_start" status=none
if [[ $kernel_format == gzip ]]; then
	gzip -t "$image_path"
else
	arm64_magic=$(od -An -j 56 -N 4 -tx1 "$image_path" | tr -d ' \n')
	if [[ $arm64_magic != 41524d64 ]]; then
		echo "error: extracted kernel lacks the ARM64 Image magic" >&2
		exit 1
	fi
fi

position=$dtb_start
index=0
while (( position < payload_size )); do
	total_size=$(read_be32 "$payload" "$((position + 4))")
	entry="$output_dir/entry.dtb.$index"
	dd if="$payload" of="$entry" bs=1 skip="$position" \
		count="$total_size" status=none
	compatible=$(fdtget -t s "$entry" / compatible 2>/dev/null | tr '\n' ',' | sed 's/,$//')
	model=$(fdtget -t s "$entry" / model 2>/dev/null || true)
	digest=$(sha256sum "$entry" | cut -d' ' -f1)
	printf 'dtb[%d] offset=%d bytes=%d sha256=%s compatible=%s model=%s\n' \
		"$index" "$position" "$total_size" "$digest" \
		"${compatible:-<missing>}" "${model:-<missing>}"
	position=$((position + total_size))
	index=$((index + 1))
done

image_digest=$(sha256sum "$image_path" | cut -d' ' -f1)
printf '%s bytes=%d sha256=%s\n' "$image_name" "$dtb_start" "$image_digest"
printf 'appended_dtbs=%d payload_bytes=%d\n' "$index" "$payload_size"
