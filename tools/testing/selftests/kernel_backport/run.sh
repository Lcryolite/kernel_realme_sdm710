#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
set -euo pipefail

test_dir=$(cd "$(dirname "$0")" && pwd)
output=$(realpath "${1:?Usage: run.sh KERNEL_OUTPUT LOG_FILE}")
log=$(realpath -m "${2:?Usage: run.sh KERNEL_OUTPUT LOG_FILE}")
qemu=${QEMU:-qemu-system-aarch64}
busybox=$(realpath "${BUSYBOX:?Set BUSYBOX to a static AArch64 binary}")
work=$(mktemp -d)
cleanup()
{
	status=$?
	if [ -n "${result_image:-}" ] && [ -f "${fixture_image:-}" ]; then
		cp --reflink=auto "$fixture_image" "$result_image" || status=1
	fi
	rm -rf "$work"
	trap - EXIT
	exit "$status"
}
trap cleanup EXIT

cat >"$work/cpio.list" <<EOF
dir /bin 755 0 0
dir /dev 755 0 0
dir /proc 755 0 0
dir /sys 755 0 0
nod /dev/console 600 0 0 c 5 1
file /bin/busybox $busybox 755 0 0
slink /bin/sh busybox 777 0 0
file /init $test_dir/init.sh 755 0 0
file /expected-release $output/include/config/kernel.release 444 0 0
EOF

fixture_args=()
if [ -n "${F2FS_FIXTURE:-}" ]; then
	fixture=$(realpath "$F2FS_FIXTURE")
	codec=${F2FS_CODEC:-lz4}
	case "$codec" in lz4|zstd) ;; *) exit 2 ;; esac
	test -f "$fixture/read-lz4.img"
	test -f "$fixture/expected-sha256"
	mode=${F2FS_MODE:-read}
	printf '%s\n' "$mode" >"$work/f2fs-mode"
	printf '%s\n' "$codec" >"$work/f2fs-codec"
	printf '%s\n' "${F2FS_READ_FILE:-payload}" >"$work/f2fs-read-file"
	printf 'file /f2fs-expected-sha256 %s/expected-sha256 444 0 0\n' \
		"$fixture" >>"$work/cpio.list"
	printf 'file /f2fs-mode %s/f2fs-mode 444 0 0\n' \
		"$work" >>"$work/cpio.list"
	printf 'file /f2fs-codec %s/f2fs-codec 444 0 0\n' \
		"$work" >>"$work/cpio.list"
	printf 'file /f2fs-read-file %s/f2fs-read-file 444 0 0\n' \
		"$work" >>"$work/cpio.list"
	printf 'file /f2fs-test.sh %s/f2fs-test.sh 755 0 0\n' \
		"$test_dir" >>"$work/cpio.list"
	fixture_image=$(realpath "${F2FS_IMAGE:-$fixture/read-lz4.img}")
	test -f "$fixture_image"
	readonly=on
	case "$mode" in
		read|reject) ;;
		corrupt|write|lifecycle|encrypted|encrypted-gc|checkpoint-write|checkpoint-read|orphan-write)
			cp --reflink=auto "$fixture_image" "$work/fixture.img"
			fixture_image=$work/fixture.img
			readonly=off
			;;
		*) echo "Unsupported F2FS_MODE" >&2; exit 2 ;;
	esac
	if [ "$mode" = corrupt ]; then
		python3 - "$fixture_image" \
			"${F2FS_CLUSTER_BLOCK:?Set the first compressed storage block}" \
			"${F2FS_BAD_CLEN:-0}" "${F2FS_PAYLOAD_FAULT:-length}" <<'PY'
import struct
import sys

with open(sys.argv[1], "r+b") as image:
    offset = int(sys.argv[2]) * 4096
    image.seek(offset)
    length = struct.unpack("<I", image.read(4))[0]
    fault = sys.argv[4]
    if fault == "bad-magic":
        image.seek(offset + 24)
        first = image.read(1)
        image.seek(offset + 24)
        image.write(bytes([first[0] ^ 0xff]))
    elif fault in ("length", "truncated"):
        if fault == "truncated":
            if not 1 < length <= 4096 - 24:
                raise ValueError("expected a valid single-block compressed frame")
            length -= 1
        else:
            length = int(sys.argv[3], 0)
        image.seek(offset)
        image.write(struct.pack("<I", length))
    else:
        raise ValueError("unsupported F2FS_PAYLOAD_FAULT")
PY
	fi
	if [[ "$mode" =~ ^(write|lifecycle|encrypted|encrypted-gc|checkpoint-write|checkpoint-read|orphan-write)$ ]]; then
		requested_result=$(realpath -m "${F2FS_RESULT_IMAGE:?Set a new result image path}")
		test ! -e "$requested_result"
		result_image=$requested_result
		printf 'file /f2fs-payload %s/source/payload 444 0 0\n' \
			"$fixture" >>"$work/cpio.list"
	fi
	if [ "$mode" = lifecycle ] || [ "$mode" = encrypted-gc ]; then
		gc_helper=$(realpath "${F2FS_GC:?Set F2FS_GC to the static GC helper}")
		printf 'file /f2fs-gc %s 755 0 0\n' \
			"$gc_helper" >>"$work/cpio.list"
		printf '%s\n' "${F2FS_GC_START:-6656}" >"$work/f2fs-gc-start"
		printf 'file /f2fs-gc-start %s/f2fs-gc-start 444 0 0\n' \
			"$work" >>"$work/cpio.list"
		printf '%s\n' "${F2FS_DATA_FLUSH:-0}" >"$work/f2fs-data-flush"
		printf 'file /f2fs-data-flush %s/f2fs-data-flush 444 0 0\n' \
			"$work" >>"$work/cpio.list"
		printf 'file /f2fs-noise %s/noise 444 0 0\n' \
			"$fixture" >>"$work/cpio.list"
		printf 'file /f2fs-lifecycle.sh %s/f2fs-lifecycle.sh 755 0 0\n' \
			"$test_dir" >>"$work/cpio.list"
	fi
	if [ "$mode" = encrypted ] || [ "$mode" = encrypted-gc ]; then
		fscrypt_test=$(realpath "${FSCRYPT_TEST:?Set FSCRYPT_TEST to the static guest helper}")
		printf 'file /fscrypt-test %s 755 0 0\n' \
			"$fscrypt_test" >>"$work/cpio.list"
		printf 'file /f2fs-encryption.sh %s/f2fs-encryption.sh 755 0 0\n' \
			"$test_dir" >>"$work/cpio.list"
	fi
	fixture_args=(
		-drive "file=$fixture_image,if=none,format=raw,id=fixture,readonly=$readonly"
		-device virtio-blk-device,drive=fixture,serial=fixture
	)
fi

case "${INITRAMFS_COMPRESSION:-gzip}" in
	gzip) compressor=(gzip -n) ;;
	zstd) compressor=(zstd -q -T1 -3) ;;
	*) echo "Unsupported INITRAMFS_COMPRESSION" >&2; exit 2 ;;
esac
"$output/usr/gen_init_cpio" "$work/cpio.list" |
	"${compressor[@]}" >"$work/initramfs"

fault=${INITRAMFS_FAULT:-none}
case "$fault" in
	none) ;;
	bad-header|truncated)
		[ "${INITRAMFS_COMPRESSION:-gzip}" = zstd ] || {
			echo "INITRAMFS_FAULT requires Zstd" >&2
			exit 2
		}
		python3 - "$work/initramfs" "$fault" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
data = bytearray(path.read_bytes())
if sys.argv[2] == "bad-header":
    data[4] |= 0x08  # Reserved bit in the Zstd frame header descriptor.
else:
    data = data[:len(data) // 2]
path.write_bytes(data)
PY
		;;
	*) echo "Unsupported INITRAMFS_FAULT" >&2; exit 2 ;;
esac

truncate -s 128M "$work/scratch.img"
mkdir -p "$(dirname "$log")"

timeout --foreground "${QEMU_TIMEOUT:-90}" "$qemu" \
	-L "${QEMU_DATA_DIR:-/usr/share/qemu}" \
	-machine virt,gic-version=2,highmem=off -cpu cortex-a57 -accel tcg \
	-m 512 -smp 2 -display none -serial stdio -monitor none \
	-no-reboot -nic none \
	-kernel "$output/arch/arm64/boot/Image" \
	-initrd "$work/initramfs" \
	-append 'earlycon=pl011,0x09000000 console=ttyAMA0 rdinit=/init panic=-1' \
	-drive "file=$work/scratch.img,if=none,format=raw,id=scratch" \
	-device virtio-blk-device,drive=scratch,serial=scratch \
	"${fixture_args[@]}" >"$log" 2>&1 || {
	tail -n 25 "$log"
	exit 1
}

if [ "$fault" != none ]; then
	if ! grep -q 'Initramfs unpacking failed: .*ZSTD' "$log" ||
	   grep -Eq 'KERNEL_BACKPORT_|BUG:|Oops:|Unable to handle kernel|KASAN:' "$log"; then
		tail -n 25 "$log"
		exit 1
	fi
	echo "KERNEL_BACKPORT_REJECT_PASS: $fault"
	exit 0
fi

if grep -Eq 'KERNEL_BACKPORT_FAIL:|BUG:|Oops:|Unable to handle kernel|KASAN:' "$log" ||
   ! grep -q '^KERNEL_BACKPORT_PASS:' "$log"; then
	tail -n 25 "$log"
	exit 1
fi
grep '^KERNEL_BACKPORT_PASS:' "$log"
