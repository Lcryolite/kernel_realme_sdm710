#!/bin/sh
# SPDX-License-Identifier: GPL-2.0

/bin/busybox --install -s /bin
export PATH=/bin

fail()
{
	echo "KERNEL_BACKPORT_FAIL: $*"
	poweroff -f
	exit 1
}

disk_by_serial()
{
	for serial in /sys/block/vd*/serial; do
		[ "$(cat "$serial")" = "$1" ] || continue
		disk=${serial%/serial}
		echo "/dev/${disk##*/}"
		return 0
	done
	return 1
}

mount -t proc proc /proc || fail "mount proc"
mount -t sysfs sysfs /sys || fail "mount sysfs"
mount -t devtmpfs devtmpfs /dev || fail "mount devtmpfs"

expected=$(cat /expected-release) || fail "read expected release"
actual=$(uname -r) || fail "uname"
[ "$actual" = "$expected" ] ||
	fail "reported release '$actual', expected '$expected'"
scratch=$(disk_by_serial scratch) || fail "disposable virtio disk is unavailable"
[ -b "$scratch" ] || fail "disposable virtio disk is not a block device"

if [ -f /f2fs-expected-sha256 ]; then
	fixture=$(disk_by_serial fixture) || fail "F2FS fixture is unavailable"
	/f2fs-test.sh "$fixture" || fail "F2FS test"
fi

echo "KERNEL_BACKPORT_PASS: release=$actual disposable-disk=present"
poweroff -f
