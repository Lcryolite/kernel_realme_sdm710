#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
set -eu

disk=$1
mode=$(cat /f2fs-mode)
codec=$(cat /f2fs-codec)
read_file=$(cat /f2fs-read-file)
expected_hash=$(cat /f2fs-expected-sha256)
mkdir /mnt

check_payload()
{
	actual_hash=$(sha256sum "$1" | cut -d ' ' -f 1)
	if [ "$actual_hash" != "$expected_hash" ]; then
		echo "F2FS checksum mismatch: $1 actual=$actual_hash expected=$expected_hash" >&2
		stat -c 'inode=%i size=%s blocks=%b' "$1" >&2
		if [ -f /f2fs-payload ]; then
			cmp "$1" /f2fs-payload || :
		fi
		return 1
	fi
}

case "$mode" in
read|corrupt|reject)
	for pass in 1 2; do
		mount -t f2fs -o ro "$disk" /mnt
		if [ "$mode" = corrupt ] || [ "$mode" = reject ]; then
			if cat "/mnt/$read_file" >/dev/null; then
				echo "Unexpected read of corrupt compressed payload" >&2
				exit 1
			fi
		else
			check_payload "/mnt/$read_file"
		fi
		umount /mnt
	done
	echo "F2FS_READ_PASS: mode=$mode remount=passed"
	;;
write)
	mount -t f2fs -o "rw,compress_algorithm=$codec" "$disk" /mnt
	touch /mnt/selected
	chattr +c /mnt/selected
	cat /f2fs-payload >/mnt/selected
	cat /f2fs-payload >/mnt/peer
	mkdir /mnt/inherit
	chattr +c /mnt/inherit
	cat /f2fs-payload >/mnt/inherit/child
	sync
	selected_flags=$(lsattr /mnt/selected | cut -d ' ' -f 1)
	peer_flags=$(lsattr /mnt/peer | cut -d ' ' -f 1)
	child_flags=$(lsattr /mnt/inherit/child | cut -d ' ' -f 1)
	case "$selected_flags" in *c*) ;; *) echo "Missing selected compression flag: $selected_flags" >&2; exit 1 ;; esac
	case "$peer_flags" in *c*) echo "Unselected peer gained compression: $peer_flags" >&2; exit 1 ;; esac
	case "$child_flags" in *c*) ;; *) echo "Missing inherited compression flag: $child_flags" >&2; exit 1 ;; esac
	check_payload /mnt/selected
	check_payload /mnt/peer
	check_payload /mnt/inherit/child
	echo "F2FS_SELECTED_INODE: $(stat -c %i /mnt/selected)"
	echo "F2FS_PEER_INODE: $(stat -c %i /mnt/peer)"
	umount /mnt
	mount -t f2fs -o "rw,compress_algorithm=$codec" "$disk" /mnt
	check_payload /mnt/selected
	check_payload /mnt/peer
	check_payload /mnt/inherit/child
	umount /mnt
	echo "F2FS_WRITE_PASS: codec=$codec selected=verified inherited=verified peer=uncompressed remount=passed"
	;;
lifecycle)
	/f2fs-lifecycle.sh "$disk" "$codec"
	;;
encrypted|encrypted-gc)
	/fscrypt-test session /f2fs-encryption.sh "$disk" "$codec" "$mode"
	;;
checkpoint-write|orphan-write)
	mount -t f2fs -o "rw,compress_algorithm=$codec" "$disk" /mnt
	touch /mnt/checkpoint-selected
	chattr +c /mnt/checkpoint-selected
	cat /f2fs-payload >/mnt/checkpoint-selected
	if [ "$mode" = orphan-write ]; then
		touch /mnt/checkpoint-orphan
		chattr +c /mnt/checkpoint-orphan
		cat /f2fs-payload >/mnt/checkpoint-orphan
		exec 3<>/mnt/checkpoint-orphan
		rm /mnt/checkpoint-orphan
		# This guest child retains the unlinked inode until forced poweroff.
		sleep 60 &
		holder=$!
		[ -e "/proc/$holder/fd/3" ]
		echo "F2FS_ORPHAN_HELD: pid=$holder fd=3"
	fi
	sync
	check_payload /mnt/checkpoint-selected
	echo "F2FS_CHECKPOINT_WRITE_PASS: codec=$codec synced=verified left-mounted=yes"
	# /init powers off without unmounting this filesystem.
	;;
checkpoint-read)
	mount -t f2fs -o "rw,compress_algorithm=$codec" "$disk" /mnt
	check_payload /mnt/checkpoint-selected
	check_payload /mnt/payload
	[ ! -e /mnt/checkpoint-orphan ]
	umount /mnt
	echo "F2FS_CHECKPOINT_READ_PASS: codec=$codec persisted=verified"
	;;
*) echo "Unknown F2FS test mode" >&2; exit 2 ;;
esac
