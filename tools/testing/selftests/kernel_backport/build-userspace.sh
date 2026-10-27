#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
set -euo pipefail

test_dir=$(cd "$(dirname "$0")" && pwd)
output=$(realpath -m "${1:?Usage: build-userspace.sh OUTPUT_DIRECTORY}")
sysroot=$(realpath "${MUSL_SYSROOT:?Set MUSL_SYSROOT to the ARM64 musl sysroot}")
builtins=$(realpath "${COMPILER_RT_BUILTINS:?Set COMPILER_RT_BUILTINS to an ARM64 archive}")
compiler=${CLANG:-clang}
mkdir -p "$output"

for program in fscrypt-test f2fs-gc; do
	# Startup objects and libc are musl; compiler-rt supplies arithmetic only.
	"$compiler" --target=aarch64-linux-musl --sysroot="$sysroot" \
		-fuse-ld=lld -static -nostdlib -std=gnu11 -O2 \
		-Wall -Wextra -Werror \
		"$sysroot/usr/lib/crt1.o" "$sysroot/usr/lib/crti.o" \
		"$test_dir/$program.c" -L"$sysroot/usr/lib" \
		-Wl,--start-group -lc "$builtins" -Wl,--end-group \
		"$sysroot/usr/lib/crtn.o" \
		-Wl,-Map="$output/$program.map" -o "$output/$program"
	sha256sum "$output/$program"
done
