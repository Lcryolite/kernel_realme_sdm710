#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
set -euo pipefail

output=$(realpath -m "${1:?Usage: make-f2fs-fixture.sh NEW_DIRECTORY}")
mkfs=${MKFS_F2FS:-mkfs.f2fs}
sload=${SLOAD_F2FS:-sload.f2fs}
features=extra_attr,compression
if [ "${F2FS_ENCRYPTION:-0}" = 1 ]; then
	features+=,encrypt
fi

# Refuse to overwrite an existing image or directory.
mkdir "$output"
mkdir "$output/source"
python3 - "$output/source/payload" "$output/noise" <<'PY'
import pathlib
import random
import sys

pattern = b"F2FS compression backport: cluster and partial-tail verification.\n"
data = (pattern * (98304 // len(pattern) + 1))[:98304]
pathlib.Path(sys.argv[1]).write_bytes(data + bytes(range(31)))
pathlib.Path(sys.argv[2]).write_bytes(random.Random(1901).randbytes(1 << 20))
PY

sha256sum "$output/source/payload" | cut -d ' ' -f 1 >"$output/expected-sha256"
# Upstream sload supports LZ4 fixtures; guest writes select the tested codec.
truncate -s 256M "$output/read-lz4.img"
"$mkfs" -f -O "$features" "$output/read-lz4.img" >"$output/mkfs.log" 2>&1
"$sload" -f "$output/source" -c -a lz4 -L 2 \
	"$output/read-lz4.img" >"$output/sload.log" 2>&1
echo "$output/read-lz4.img"
