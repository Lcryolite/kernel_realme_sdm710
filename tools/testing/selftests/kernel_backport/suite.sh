#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
set -euo pipefail

test_dir=$(cd "$(dirname "$0")" && pwd)
kernel=$(realpath "${1:?Usage: suite.sh KERNEL_OUTPUT NEW_RESULTS_DIRECTORY}")
results=$(realpath -m "${2:?Usage: suite.sh KERNEL_OUTPUT NEW_RESULTS_DIRECTORY}")
fixture=$(realpath "${F2FS_FIXTURE:?Set F2FS_FIXTURE to an encryption-enabled fixture}")
fsck=${FSCK_F2FS:-fsck.f2fs}
dump=${DUMP_F2FS:-dump.f2fs}
inject=${INJECT_F2FS:-inject.f2fs}
f2fs_libs=${F2FS_LD_LIBRARY_PATH:-${LD_LIBRARY_PATH:-}}
: "${FSCRYPT_TEST:?Set FSCRYPT_TEST to the static guest helper}"
: "${F2FS_GC:?Set F2FS_GC to the static GC helper}"

# Every mutation happens in a fresh output or in run.sh's private copy.
mkdir "$results"
exec > >(tee "$results/suite.log") 2>&1
trap 'echo "SUITE_FAIL: line=$LINENO"' ERR
cp "$kernel/.config" "$results/kernel.config"
cp "$kernel/include/config/kernel.release" "$results/kernel.release"
sha256sum "$kernel/arch/arm64/boot/Image" "$fixture/read-lz4.img" \
	"$FSCRYPT_TEST" "$F2FS_GC" >"$results/inputs.sha256"

native()
{
	env LD_LIBRARY_PATH="$f2fs_libs" "$@"
}

run_case()
{
	local name=$1
	shift
	printf 'CASE: %s\n' "$name"
	printf '%q ' env "$@" bash "$test_dir/run.sh" "$kernel" \
		"$results/$name.log" >>"$results/commands.sh"
	printf '\n' >>"$results/commands.sh"
	env "$@" bash "$test_dir/run.sh" "$kernel" "$results/$name.log"
}

check_image()
{
	local name=$1
	native "$fsck" --dry-run -f "$results/$name.img" \
		>"$results/$name-fsck.log" 2>&1
	if grep -Eq '\[Fail|\[FIX|\[Fix|ASSERT|Wrong segment type|corruption was found' \
		"$results/$name-fsck.log"; then
		cat "$results/$name-fsck.log"
		return 1
	fi
}

native python3 "$test_dir/make-zstd-fixture.py" "$fixture" \
	"$results/independent-zstd.img"

run_case gzip F2FS_FIXTURE= INITRAMFS_COMPRESSION=gzip INITRAMFS_FAULT=none
run_case zstd-initramfs F2FS_FIXTURE= INITRAMFS_COMPRESSION=zstd INITRAMFS_FAULT=none
for fault in bad-header truncated; do
	run_case "zstd-$fault" F2FS_FIXTURE= INITRAMFS_COMPRESSION=zstd \
		INITRAMFS_FAULT="$fault"
done

for codec in lz4 zstd; do
	input=$fixture/read-lz4.img
	[ "$codec" != zstd ] || input=$results/independent-zstd.img
	common=(F2FS_FIXTURE="$fixture" F2FS_CODEC="$codec" F2FS_IMAGE="$input"
		F2FS_READ_FILE=payload F2FS_DATA_FLUSH=0
		INITRAMFS_COMPRESSION=gzip INITRAMFS_FAULT=none)
	run_case "$codec-read" "${common[@]}" F2FS_MODE=read
	for length in 0 0xffffffff; do
		run_case "$codec-length-$length" "${common[@]}" F2FS_MODE=corrupt \
			F2FS_CLUSTER_BLOCK=6656 F2FS_BAD_CLEN="$length" F2FS_PAYLOAD_FAULT=length
	done
	run_case "$codec-frame-truncated" "${common[@]}" F2FS_MODE=corrupt \
		F2FS_CLUSTER_BLOCK=6656 F2FS_PAYLOAD_FAULT=truncated
	if [ "$codec" = zstd ]; then
		run_case zstd-frame-bad-magic "${common[@]}" F2FS_MODE=corrupt \
			F2FS_CLUSTER_BLOCK=6656 F2FS_PAYLOAD_FAULT=bad-magic
	fi
	for mode in write lifecycle encrypted; do
		run_case "$codec-$mode" "${common[@]}" F2FS_MODE="$mode" \
			F2FS_RESULT_IMAGE="$results/$codec-$mode.img" QEMU_TIMEOUT=600
		check_image "$codec-$mode"
	done
	# Compare the same encrypted inode's storage slots across actual GC.
	ino=$(sed -n 's/^F2FS_ENCRYPTED_INODE: \([0-9]*\).*/\1/p' \
		"$results/$codec-encrypted.log")
	test -n "$ino"
	printf 'N\n' | native "$dump" -i "$ino" "$results/$codec-encrypted.img" \
		>"$results/$codec-encrypted-before.dump"
	start=$(python3 "$test_dir/check-gc-move.py" "$results/$codec-encrypted-before.dump")
	run_case "$codec-encrypted-gc" "${common[@]}" F2FS_MODE=encrypted-gc \
		F2FS_IMAGE="$results/$codec-encrypted.img" F2FS_GC_START="$start" \
		F2FS_RESULT_IMAGE="$results/$codec-encrypted-gc.img" QEMU_TIMEOUT=600
	printf 'N\n' | native "$dump" -i "$ino" "$results/$codec-encrypted-gc.img" \
		>"$results/$codec-encrypted-after.dump"
	python3 "$test_dir/check-gc-move.py" "$results/$codec-encrypted-before.dump" \
		--before-image "$results/$codec-encrypted.img" \
		--after-dump "$results/$codec-encrypted-after.dump" \
		--after-image "$results/$codec-encrypted-gc.img" \
		>"$results/$codec-encrypted-gc-movement.json"
	check_image "$codec-encrypted-gc"
	# Force the checkpoint data-flush path as well as normal writeback.
	run_case "$codec-data-flush" "${common[@]}" F2FS_MODE=lifecycle \
		F2FS_DATA_FLUSH=1 F2FS_RESULT_IMAGE="$results/$codec-data-flush.img" \
		QEMU_TIMEOUT=600
	check_image "$codec-data-flush"
	for mode in checkpoint orphan; do
		run_case "$codec-$mode-write" "${common[@]}" F2FS_MODE="$mode-write" \
			F2FS_RESULT_IMAGE="$results/$codec-$mode-dirty.img"
		run_case "$codec-$mode-read" "${common[@]}" F2FS_MODE=checkpoint-read \
			F2FS_IMAGE="$results/$codec-$mode-dirty.img" \
			F2FS_RESULT_IMAGE="$results/$codec-$mode-read.img"
		check_image "$codec-$mode-read"
	done
done

# The fixture conversion above validates the exact inode/address layout used
# by these metadata cases. Inject only into fresh disposable copies.
for case_name in extra-size algorithm small-cluster large-cluster compress-flags misplaced-marker plain-marker; do
	image=$results/$case_name.img
	read_file=payload
	source=$fixture/read-lz4.img
	[ "$case_name" != plain-marker ] || source=$results/lz4-write.img
	cp --reflink=auto "$source" "$image"
	args=(--node --nid 4 --mb i_addr --idx 8)
	case "$case_name" in
		extra-size) args=(--node --nid 4 --mb i_extra_isize); value=24 ;;
		algorithm) value=0x2ff ;;
		small-cluster) value=1 ;;
		large-cluster) value=0x901 ;;
		compress-flags) value=0x10201 ;;
		misplaced-marker)
			native "$inject" --node --nid 4 --mb i_addr --idx 9 --val 6656 \
				"$image" >"$results/$case_name-head-inject.log" 2>&1
			args=(--node --nid 4 --mb i_addr --idx 11); value=0xfffffffe ;;
		plain-marker)
			peer=$(sed -n 's/^F2FS_PEER_INODE: \([0-9]*\).*/\1/p' "$results/lz4-write.log")
			test -n "$peer"
			args=(--node --nid "$peer" --mb i_addr --idx 9)
			value=0xfffffffe; read_file=peer ;;
	esac
	native "$inject" "${args[@]}" --val "$value" "$image" \
		>"$results/$case_name-inject.log" 2>&1
	run_case "$case_name" F2FS_FIXTURE="$fixture" F2FS_IMAGE="$image" \
		F2FS_MODE=reject F2FS_READ_FILE="$read_file" INITRAMFS_FAULT=none
done

sha256sum "$results"/*.img >"$results/images.sha256"
echo 'SUITE_PASS: startup codecs lifecycle checkpoint orphan encryption corrupt-input'
