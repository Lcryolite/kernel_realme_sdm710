#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
set -eu

disk=${1:?Usage: f2fs-lifecycle.sh DISK CODEC}
codec=${2:?Usage: f2fs-lifecycle.sh DISK CODEC}

fail()
{
	echo "F2FS_LIFECYCLE_FAIL: codec=$codec $*" >&2
	exit 1
}

compare()
{
	cmp -s "$1" "$2" || fail "content mismatch: $3"
}

check_flag()
{
	attributes=$(lsattr "$1") || fail "cannot read attributes: $1"
	# Inspect the attribute column, never characters in the filename.
	flags=${attributes%% *}
	[ -n "$flags" ] || fail "missing attribute column: $1"
	case "$flags" in
	*c*) [ "$2" = selected ] || fail "unselected file gained +c: $1" ;;
	*) [ "$2" = unselected ] || fail "selected file lost +c: $1" ;;
	esac
}

mount_fixture()
{
	options="rw,compress_algorithm=$codec,background_gc=off"
	if [ "$(cat /f2fs-data-flush)" = 1 ]; then
		options="$options,data_flush"
	fi
	mount -t f2fs -o "$options" "$disk" /mnt
}

case "$codec" in
lz4|zstd) ;;
*) fail "unsupported codec" ;;
esac
[ -b "$disk" ] || fail "fixture is not a block device"
[ -d /mnt ] || fail "missing mount point"
[ "$(wc -c </f2fs-payload)" -eq 98335 ] || fail "unexpected payload size"
[ "$(wc -c </f2fs-noise)" -eq 1048576 ] || fail "unexpected noise size"

mount_fixture
: >/mnt/lifecycle-selected
chattr +c /mnt/lifecycle-selected
check_flag /mnt/lifecycle-selected selected
cat /f2fs-payload >/mnt/lifecycle-selected
cp /f2fs-payload /expected
sync
compare /mnt/lifecycle-selected /expected initial-write

dd if=/f2fs-noise of=/mnt/lifecycle-selected bs=1 skip=17 count=8193 \
	seek=16367 conv=notrunc
dd if=/f2fs-noise of=/expected bs=1 skip=17 count=8193 \
	seek=16367 conv=notrunc
sync
compare /mnt/lifecycle-selected /expected partial-overwrite

dd if=/f2fs-noise bs=1 count=8191 >>/mnt/lifecycle-selected
dd if=/f2fs-noise bs=1 count=8191 >>/expected
sync
compare /mnt/lifecycle-selected /expected append

truncate -s 32785 /mnt/lifecycle-selected
truncate -s 32785 /expected
sync
compare /mnt/lifecycle-selected /expected truncate-down
truncate -s 65555 /mnt/lifecycle-selected
truncate -s 65555 /expected
sync
compare /mnt/lifecycle-selected /expected zero-extension

mv /mnt/lifecycle-selected /mnt/lifecycle-renamed
compare /mnt/lifecycle-renamed /expected rename
ln /mnt/lifecycle-renamed /mnt/lifecycle-alias
compare /mnt/lifecycle-alias /expected hardlink
rm /mnt/lifecycle-renamed
compare /mnt/lifecycle-alias /expected unlink-original
sync
umount /mnt
mount_fixture
compare /mnt/lifecycle-alias /expected alias-after-remount
check_flag /mnt/lifecycle-alias selected
rm /mnt/lifecycle-alias
echo "F2FS_LIFECYCLE_PROGRESS: codec=$codec mutations=verified"

: >/mnt/lifecycle-small
chattr +c /mnt/lifecycle-small
dd if=/f2fs-payload of=/mnt/lifecycle-small bs=1 count=127
dd if=/f2fs-payload of=/expected-small bs=1 count=127
: >/mnt/lifecycle-incompressible
chattr +c /mnt/lifecycle-incompressible
cat /f2fs-noise >/mnt/lifecycle-incompressible
cat /f2fs-payload >/mnt/lifecycle-peer
sync
compare /mnt/lifecycle-small /expected-small small-file
compare /mnt/lifecycle-incompressible /f2fs-noise incompressible-file
compare /mnt/lifecycle-peer /f2fs-payload unselected-peer
check_flag /mnt/lifecycle-small selected
check_flag /mnt/lifecycle-incompressible selected
check_flag /mnt/lifecycle-peer unselected

# Cross the inode's address array and multiple direct-node boundaries.
: >/expected-large
repeat=0
while [ "$repeat" -lt 96 ]; do
	cat /f2fs-payload >>/expected-large
	repeat=$((repeat + 1))
done
: >/mnt/lifecycle-large
chattr +c /mnt/lifecycle-large
cat /expected-large >/mnt/lifecycle-large
sync
compare /mnt/lifecycle-large /expected-large compressed-node-boundaries

# The inspected fixture starts compressed storage in main-area segment 5.
# The large file closes that cold segment before this targeted collection.
device=${disk##*/}
echo 1 >"/sys/fs/f2fs/$device/iostat_enable"
before_gc=$(awk '/^fs gc data:/ {print $4}' \
	"/proc/fs/f2fs/$device/iostat_info")
/f2fs-gc range /mnt 6656 512 || fail "targeted GC did not complete"
sync
after_gc=$(awk '/^fs gc data:/ {print $4}' \
	"/proc/fs/f2fs/$device/iostat_info")
[ -n "$before_gc" ] && [ -n "$after_gc" ] || fail "missing GC I/O counters"
[ "$after_gc" -gt "$before_gc" ] || fail "no successful GC data I/O"
compare /mnt/payload /f2fs-payload original-after-gc
compare /mnt/lifecycle-large /expected-large large-after-gc
echo "F2FS_GC_PASS: codec=$codec start_block=6656 blocks=512 data_bytes=$((after_gc - before_gc))"

# This reference lives on the initramfs, independently of the F2FS fixture.
cat /f2fs-noise /f2fs-noise /f2fs-noise /f2fs-noise >/expected-reuse
[ "$(wc -c </expected-reuse)" -eq 4194304 ] || fail "reuse reference size"
iteration=1
while [ "$iteration" -le 72 ]; do
	slot=$(((iteration - 1) % 3))
	file=/mnt/lifecycle-reuse-$slot
	rm -f "$file"
	: >"$file"
	chattr +c "$file"
	cat /expected-reuse >"$file"
	sync
	compare "$file" /expected-reuse "reuse iteration $iteration"
	check_flag "$file" selected
	if [ "$((iteration % 12))" -eq 0 ]; then
		echo "F2FS_LIFECYCLE_PROGRESS: codec=$codec reuse_iterations=$iteration/72 logical_write_mib=$((iteration * 4)) slots=3"
	fi
	iteration=$((iteration + 1))
done

rm /mnt/lifecycle-reuse-0 /mnt/lifecycle-reuse-1 /mnt/lifecycle-reuse-2
sync
umount /mnt
mount_fixture
compare /mnt/lifecycle-small /expected-small small-after-reuse-and-remount
compare /mnt/lifecycle-incompressible /f2fs-noise noise-after-reuse-and-remount
compare /mnt/lifecycle-peer /f2fs-payload peer-after-reuse-and-remount
compare /mnt/lifecycle-large /expected-large large-after-reuse-and-remount
compare /mnt/payload /f2fs-payload original-after-gc-and-remount
check_flag /mnt/lifecycle-small selected
check_flag /mnt/lifecycle-incompressible selected
check_flag /mnt/lifecycle-peer unselected
umount /mnt

# Logical writes exercise reuse; GC activity requires separate kernel evidence.
echo "F2FS_LIFECYCLE_PASS: codec=$codec mutations=verified survivors=verified reuse_iterations=72 logical_write_mib=288 slots=3"
