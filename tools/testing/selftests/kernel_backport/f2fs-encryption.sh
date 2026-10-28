#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
set -eu

disk=$1
codec=$2
mode=${3:-encrypted}

fail()
{
	echo "F2FS_ENCRYPTION_FAIL: codec=$codec $*" >&2
	exit 1
}

mount_fixture()
{
	mount_options="rw,compress_algorithm=$codec"
	if [ "$mode" = encrypted-gc ]; then
		mount_options="$mount_options,background_gc=off"
	fi
	mount -t f2fs -o "$mount_options" "$disk" /mnt
}

check_plain_files()
{
	cmp -s /mnt/plain-selected /f2fs-payload || fail "unencrypted compressed file"
	cmp -s /mnt/plain-peer /f2fs-payload || fail "ordinary file"
}

rebuild_expected()
{
	cp /f2fs-payload /expected-encrypted
	printf 'encrypted partial update' >/encryption-patch
	dd if=/encryption-patch of=/expected-encrypted bs=1 seek=16380 conv=notrunc
	cat /encryption-patch >>/expected-encrypted
	truncate -s 65555 /expected-encrypted
}

if [ "$mode" = encrypted-gc ]; then
	gc_start=$(cat /f2fs-gc-start)
	case "$gc_start" in ''|*[!0-9]*) fail "invalid GC start block" ;; esac
	[ "$(wc -c </f2fs-noise)" -eq 1048576 ] || fail "GC noise size"
	rebuild_expected
	/fscrypt-test add-known-key
	mount_fixture
	/fscrypt-test verify-policy /mnt/encrypted/selected
	cmp -s /mnt/encrypted/selected /expected-encrypted || fail "GC input contents"
	flags=$(lsattr /mnt/encrypted/selected | cut -d ' ' -f 1)
	case "$flags" in *c*) ;; *) fail "GC input compression flag" ;; esac
	[ ! -e /mnt/encrypted/gc-fill ] || fail "GC filler already exists"

	# Close the active data segment without modifying the selected file.
	: >/mnt/encrypted/gc-fill
	chattr +c /mnt/encrypted/gc-fill
	iteration=0
	while [ "$iteration" -lt 9 ]; do
		cat /f2fs-noise >>/mnt/encrypted/gc-fill
		iteration=$((iteration + 1))
	done
	/fscrypt-test verify-policy /mnt/encrypted/gc-fill
	[ "$(wc -c </mnt/encrypted/gc-fill)" -eq 9437184 ] || fail "GC filler size"
	sync
	umount /mnt
	mount_fixture

	device=${disk##*/}
	echo 1 >"/sys/fs/f2fs/$device/iostat_enable"
	before_gc=$(awk '/^fs gc data:/ {print $4}' \
		"/proc/fs/f2fs/$device/iostat_info")
	[ -n "$before_gc" ] || fail "missing initial GC counter"
	/f2fs-gc range /mnt "$gc_start" 512 || fail "encrypted targeted GC"
	sync
	after_gc=$(awk '/^fs gc data:/ {print $4}' \
		"/proc/fs/f2fs/$device/iostat_info")
	[ -n "$after_gc" ] || fail "missing final GC counter"
	[ "$after_gc" -gt "$before_gc" ] || fail "no encrypted-test GC data I/O"
	umount /mnt
	mount_fixture
	cmp -s /mnt/encrypted/selected /expected-encrypted || fail "selected after GC"
	cmp -s /mnt/encrypted/peer /f2fs-payload || fail "encrypted peer after GC"
	cmp -s /mnt/encrypted/inherit/child /f2fs-payload || fail "inherited after GC"
	check_plain_files
	echo "F2FS_ENCRYPTED_INODE: $(stat -c %i /mnt/encrypted/selected)"
	umount /mnt
	/fscrypt-test remove-key
	# Host before/after slot mappings and ciphertext bytes prove relocation.
	echo "F2FS_ENCRYPTED_GC_PASS: codec=$codec start_block=$gc_start blocks=512 data_bytes=$((after_gc - before_gc)) contents=verified selected-relocation=host-check-required"
	exit 0
fi
[ "$mode" = encrypted ] || fail "unsupported encryption test mode"

/fscrypt-test add-known-key
mount_fixture
mkdir /mnt/encrypted
/fscrypt-test set-policy /mnt/encrypted
touch /mnt/encrypted/selected /mnt/plain-selected
chattr +c /mnt/encrypted/selected /mnt/plain-selected
cat /f2fs-payload >/mnt/encrypted/selected
cat /f2fs-payload >/mnt/encrypted/peer
cat /f2fs-payload >/mnt/plain-selected
cat /f2fs-payload >/mnt/plain-peer
mkdir /mnt/encrypted/inherit
chattr +c /mnt/encrypted/inherit
cat /f2fs-payload >/mnt/encrypted/inherit/child
/fscrypt-test verify-policy /mnt/encrypted/selected
/fscrypt-test verify-policy /mnt/encrypted/peer
flags=$(lsattr /mnt/encrypted/selected | cut -d ' ' -f 1)
case "$flags" in *c*) ;; *) fail "compression flag missing" ;; esac
flags=$(lsattr /mnt/encrypted/peer | cut -d ' ' -f 1)
case "$flags" in *c*) fail "unselected encrypted file gained compression" ;; esac
flags=$(lsattr /mnt/encrypted/inherit/child | cut -d ' ' -f 1)
case "$flags" in *c*) ;; *) fail "encrypted inheritance flag missing" ;; esac
/fscrypt-test verify-policy /mnt/encrypted/inherit/child

# Mutate persisted compressed ciphertext, not only dirty plaintext cache pages.
sync
umount /mnt
mount_fixture
cmp -s /mnt/encrypted/selected /f2fs-payload || fail "initial encrypted remount"
cmp -s /mnt/encrypted/inherit/child /f2fs-payload || fail "encrypted inheritance"

rebuild_expected
dd if=/encryption-patch of=/mnt/encrypted/selected bs=1 seek=16380 conv=notrunc
cat /encryption-patch >>/mnt/encrypted/selected
truncate -s 65555 /mnt/encrypted/selected
sync
cmp -s /mnt/encrypted/selected /expected-encrypted || fail "encrypted mutations"
cmp -s /mnt/encrypted/peer /f2fs-payload || fail "encrypted uncompressed file"
check_plain_files
umount /mnt

# Full unmounts evict inode-cached v1 keys before each access check.
/fscrypt-test remove-key
mount_fixture
if cat /mnt/encrypted/selected >/without-key; then
	fail "missing key allowed file access"
fi
if touch /mnt/encrypted/forbidden; then
	fail "missing key allowed file creation"
fi
check_plain_files
umount /mnt

/fscrypt-test add-wrong-key
mount_fixture
# v1 does not authenticate key material; only plaintext recovery is forbidden.
if cmp -s /mnt/encrypted/selected /expected-encrypted; then
	fail "wrong key recovered plaintext"
fi
check_plain_files
umount /mnt
/fscrypt-test remove-key

/fscrypt-test add-known-key
mount_fixture
/fscrypt-test verify-policy /mnt/encrypted/selected
cmp -s /mnt/encrypted/selected /expected-encrypted || fail "restored key contents"
cmp -s /mnt/encrypted/peer /f2fs-payload || fail "restored uncompressed contents"
cmp -s /mnt/encrypted/inherit/child /f2fs-payload || fail "restored inherited contents"
check_plain_files
echo "F2FS_ENCRYPTED_INODE: $(stat -c %i /mnt/encrypted/selected)"
umount /mnt
/fscrypt-test remove-key
echo "F2FS_ENCRYPTION_PASS: codec=$codec mutations=verified missing-key=denied wrong-key=denied restored-key=verified"
