#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
set -euo pipefail

test_dir=$(cd "$(dirname "$0")" && pwd)
kernel_root=$(cd "$test_dir/../../../.." && pwd)
output=$(realpath -m "${1:?Usage: build.sh OUTPUT_DIRECTORY}")

make_args=(
	-C "$kernel_root" "O=$output" ARCH=arm64
	CC=clang HOSTCC=clang HOSTCXX=clang++ LD=ld.lld
	AR=llvm-ar NM=llvm-nm OBJCOPY=llvm-objcopy
	OBJDUMP=llvm-objdump STRIP=llvm-strip
	LLVM_IAS=1
	"CROSS_COMPILE=${CROSS_COMPILE:-aarch64-linux-gnu-}"
	"CROSS_COMPILE_ARM32=${CROSS_COMPILE_ARM32:-arm-linux-gnueabi-}"
	CLANG_TRIPLE_ARM32=arm-linux-gnueabi-
)

mkdir -p "$output"
make "${make_args[@]}" KCONFIG_ALLCONFIG="$test_dir/qemu.config" allnoconfig
make "${make_args[@]}" -j"${JOBS:-4}" Image
