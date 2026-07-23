#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0

set -euo pipefail

usage() {
	cat >&2 <<'EOF'
Usage: build-m3-boot-image.sh BASE_BOOT KERNEL_IMAGE OUTPUT_DIRECTORY DTB0 ... DTB5

Build and verify a complete 64 MiB RMX1901 Android boot image.  The base
boot's header and ramdisk are preserved, while its kernel payload is replaced
by KERNEL_IMAGE followed by exactly six DTBs in the supplied order.

Required environment:
  AVB_BUILD_FINGERPRINT  Value for com.android.build.boot.fingerprint

Optional environment:
  AVB_BOOT_OS_VERSION    Defaults to 17
  AVB_SALT_HEX           Defaults to the frozen RMX1901 A17 boot salt
  BOOT_PARTITION_SIZE    Defaults to 67108864
  KERNEL_IMAGE_FORMAT    gzip (default) or arm64-image
  RAMDISK_IMAGE          Replace the base boot ramdisk with this file
EOF
}

if [[ $# -ne 9 ]]; then
	usage
	exit 2
fi

base_boot=$1
kernel_image=$2
output_dir=$3
shift 3
dtbs=("$@")

: "${AVB_BUILD_FINGERPRINT:?AVB_BUILD_FINGERPRINT must be set}"
avb_os_version=${AVB_BOOT_OS_VERSION:-17}
avb_salt=${AVB_SALT_HEX:-b804f06f94004fe6e696c4f6231ec8f6b552c11ff1dbc3515a6c213f6db80bb5}
partition_size=${BOOT_PARTITION_SIZE:-67108864}
kernel_format=${KERNEL_IMAGE_FORMAT:-gzip}
ramdisk_image=${RAMDISK_IMAGE:-}

if [[ ! -f $base_boot || ! -f $kernel_image ]]; then
	echo "error: base boot or kernel image is missing" >&2
	exit 1
fi
if [[ -n $ramdisk_image && ! -f $ramdisk_image ]]; then
	echo "error: RAMDISK_IMAGE is missing: $ramdisk_image" >&2
	exit 1
fi

if [[ -e $output_dir ]]; then
	echo "error: output path already exists: $output_dir" >&2
	exit 1
fi

if [[ ! $avb_salt =~ ^[0-9a-fA-F]{64}$ ]]; then
	echo "error: AVB_SALT_HEX must contain exactly 64 hexadecimal digits" >&2
	exit 1
fi

for tool in avbtool cmp fdtget gzip mkbootimg od sha256sum stat unpack_bootimg; do
	if ! command -v "$tool" >/dev/null 2>&1; then
		echo "error: required tool is unavailable: $tool" >&2
		exit 1
	fi
done

case $kernel_format in
	gzip)
		gzip -t "$kernel_image"
		;;
	arm64-image)
		arm64_magic=$(od -An -j 56 -N 4 -tx1 "$kernel_image" | tr -d ' \n')
		if [[ $arm64_magic != 41524d64 ]]; then
			echo "error: kernel image lacks the ARM64 Image magic at offset 56" >&2
			exit 1
		fi
		;;
	*)
		echo "error: KERNEL_IMAGE_FORMAT must be gzip or arm64-image" >&2
		exit 1
		;;
esac
for dtb in "${dtbs[@]}"; do
	if [[ ! -f $dtb ]]; then
		echo "error: DTB is missing: $dtb" >&2
		exit 1
	fi
	fdtget -l "$dtb" / >/dev/null
done

mkdir -p "$output_dir/base-unpack"
unpack_args=()
while IFS= read -r -d '' argument; do
	unpack_args+=("$argument")
done < <(
	unpack_bootimg --boot_img "$base_boot" \
		--out "$output_dir/base-unpack" --format mkbootimg -0
)

kernel_payload="$output_dir/kernel-payload"
cp "$kernel_image" "$kernel_payload"
for dtb in "${dtbs[@]}"; do
	dd if="$dtb" of="$kernel_payload" oflag=append conv=notrunc status=none
done

ramdisk_payload="$output_dir/base-unpack/ramdisk"
if [[ -n $ramdisk_image ]]; then
	ramdisk_payload="$output_dir/custom-ramdisk"
	cp "$ramdisk_image" "$ramdisk_payload"
fi

mkbootimg_args=()
replace_next=
kernel_replaced=false
ramdisk_replaced=false
for argument in "${unpack_args[@]}"; do
	if [[ -n $replace_next ]]; then
		case $replace_next in
			kernel)
				mkbootimg_args+=("$kernel_payload")
				kernel_replaced=true
				;;
			ramdisk)
				mkbootimg_args+=("$ramdisk_payload")
				ramdisk_replaced=true
				;;
		esac
		replace_next=
	elif [[ $argument == --kernel || $argument == --ramdisk ]]; then
		mkbootimg_args+=("$argument")
		replace_next=${argument#--}
	else
		mkbootimg_args+=("$argument")
	fi
done

if [[ -n $replace_next ]]; then
	echo "error: unpack_bootimg returned an incomplete --$replace_next argument" >&2
	exit 1
fi
if ! $kernel_replaced || ! $ramdisk_replaced; then
	echo "error: unpack_bootimg did not return both kernel and ramdisk arguments" >&2
	exit 1
fi

raw_boot="$output_dir/boot-test.raw.img"
# avbtool resolves the hash descriptor's partition name relative to this
# directory during verify_image, so the complete image must be named boot.img.
full_boot="$output_dir/boot.img"
mkbootimg "${mkbootimg_args[@]}" --output "$raw_boot"
cp "$raw_boot" "$full_boot"
avbtool add_hash_footer \
	--image "$full_boot" \
	--partition_name boot \
	--partition_size "$partition_size" \
	--algorithm NONE \
	--hash_algorithm sha256 \
	--salt "$avb_salt" \
	--prop "com.android.build.boot.os_version:$avb_os_version" \
	--prop "com.android.build.boot.fingerprint:$AVB_BUILD_FINGERPRINT"

actual_size=$(stat -c '%s' "$full_boot")
if (( actual_size != partition_size )); then
	echo "error: complete boot image is $actual_size bytes, expected $partition_size" >&2
	exit 1
fi

mkdir "$output_dir/verify-unpack"
unpack_bootimg --boot_img "$full_boot" --out "$output_dir/verify-unpack" \
	--format info
cmp "$kernel_payload" "$output_dir/verify-unpack/kernel"
cmp "$ramdisk_payload" "$output_dir/verify-unpack/ramdisk"
avbtool verify_image --image "$full_boot"

KERNEL_IMAGE_FORMAT=$kernel_format "$(dirname "$0")/split-appended-dtbs.sh" \
	"$output_dir/verify-unpack/kernel" "$output_dir/verify-split"

printf 'raw_boot_bytes=%s\n' "$(stat -c '%s' "$raw_boot")"
printf 'partition_boot_bytes=%s\n' "$actual_size"
sha256sum "$kernel_payload" "$raw_boot" "$full_boot" \
	"$ramdisk_payload"
