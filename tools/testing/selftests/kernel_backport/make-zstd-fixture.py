#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""Transform this test's sload LZ4 fixture using an independent Zstd encoder.

This is a transformed upstream-format fixture, NOT an sload-native Zstd volume.
Only inode 4's six single-block, 16 KiB compressed clusters are supported.
DUMP_F2FS and INJECT_F2FS select native tools; their library path is inherited.
The new image receives an adjacent .json provenance and validation report.
"""

import argparse
import ctypes
import ctypes.util
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import struct
import subprocess
import sys

BLOCK = 4096
HEADER = 24
CLUSTER = 16384
CLUSTERS = 6
PAYLOAD_SIZE = CLUSTERS * CLUSTER + 31
COMPRESS_ADDR = 0xFFFFFFFE
RESERVED_ADDR = 0xFFFFFFFF


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha256(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def tool_command(variable, default):
    command = shlex.split(os.environ.get(variable, default))
    require(command, f"{variable} must name an executable")
    return command


def run_tool(command, answer=""):
    result = subprocess.run(command, input=answer, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            timeout=30)
    require(result.returncode == 0,
            f"tool failed ({result.returncode}): {shlex.join(command)}\n{result.stdout}")
    return result.stdout


def layout(dump, algorithm):
    """Validate the known native dump format; do not parse filesystem bytes."""
    require("Node ID [0x4:4] is inode" in dump, "expected inode 4")
    require(re.search(r"^i_name\s+\[payload\]$", dump, re.M),
            "inode 4 must be named payload")

    def field(name):
        match = re.search(rf"^{name}\s+\[0x\s*([0-9a-f]+)\s*:\s*(\d+)\]",
                          dump, re.M)
        require(match is not None, f"missing inode field {name}")
        value = int(match[1], 16)
        require(value == int(match[2]), f"inconsistent inode field {name}")
        return value

    expected = {
        "i_size": PAYLOAD_SIZE, "i_blocks": 26, "i_flags": 4,
        "i_advise": 0, "i_extra_isize": 36, "i_compr_blocks": 18,
        "i_compress_algorithm": algorithm, "i_log_cluster_size": 2,
        "i_compress_flag": 0,
    }
    for name, value in expected.items():
        require(field(name) == value, f"unexpected {name}; expected {value}")

    rows = []
    pattern = r"^i_addr\[0x([0-9a-f]+)\]([^\[\n]*)\[0x\s*([0-9a-f]+)\s*:\s*(\d+)\]"
    for match in re.finditer(pattern, dump, re.M):
        value = int(match[3], 16)
        require(value == int(match[4]), "inconsistent address row")
        rows.append((int(match[1], 16), match[2].strip(), value))
    base = field("i_extra_isize") // 4
    require(len(rows) == 25 and [row[0] for row in rows] == list(range(base, base + 25)),
            "expected 24 cluster slots followed by one partial-tail block")
    markers = [index for index, row in enumerate(rows) if row[1] == "cluster flag"]
    require(markers == list(range(0, 24, 4)), "expected six four-page clusters")
    addresses = []
    for index in markers:
        require(rows[index][2] == COMPRESS_ADDR, "invalid cluster marker")
        require(rows[index + 1][1] == "", "expected one storage block per cluster")
        require(all(row[1:] == ("reserved flag", RESERVED_ADDR)
                    for row in rows[index + 2:index + 4]),
                "expected two reserved slots after each storage block")
        addresses.append(rows[index + 1][2])
    require(rows[-1][1] == "", "partial tail must be an ordinary block")
    tail = rows[-1][2]
    require(addresses == list(range(6656, 6662)) and tail == 6662,
            "fixture storage layout changed; update inspected GC/corruption offsets")
    require(len(set(addresses + [tail])) == 7, "storage addresses must be distinct")
    require(all(0 < address < COMPRESS_ADDR for address in addresses + [tail]),
            "invalid physical storage address")
    return addresses, tail


def codecs():
    libraries = {}
    for name in ("lz4", "zstd"):
        soname = ctypes.util.find_library(name)
        require(soname is not None, f"host lib{name} is unavailable")
        libraries[name] = ctypes.CDLL(soname)
    lz4, zstd = libraries["lz4"], libraries["zstd"]
    lz4.LZ4_versionString.restype = ctypes.c_char_p
    lz4.LZ4_decompress_safe.argtypes = [ctypes.c_void_p, ctypes.c_void_p,
                                       ctypes.c_int, ctypes.c_int]
    lz4.LZ4_decompress_safe.restype = ctypes.c_int
    zstd.ZSTD_versionString.restype = ctypes.c_char_p
    zstd.ZSTD_compressBound.argtypes = [ctypes.c_size_t]
    zstd.ZSTD_compressBound.restype = ctypes.c_size_t
    zstd.ZSTD_compress.argtypes = [ctypes.c_void_p, ctypes.c_size_t,
                                   ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int]
    zstd.ZSTD_compress.restype = ctypes.c_size_t
    zstd.ZSTD_decompress.argtypes = [ctypes.c_void_p, ctypes.c_size_t,
                                     ctypes.c_void_p, ctypes.c_size_t]
    zstd.ZSTD_decompress.restype = ctypes.c_size_t
    zstd.ZSTD_isError.argtypes = [ctypes.c_size_t]
    zstd.ZSTD_isError.restype = ctypes.c_uint
    zstd.ZSTD_getErrorName.argtypes = [ctypes.c_size_t]
    zstd.ZSTD_getErrorName.restype = ctypes.c_char_p
    return lz4, zstd


def check_zstd(zstd, result):
    require(not zstd.ZSTD_isError(result),
            f"Zstd error: {zstd.ZSTD_getErrorName(result).decode()}")


def read_block(stream, address, image_size):
    require((address + 1) * BLOCK <= image_size, "storage block exceeds image")
    stream.seek(address * BLOCK)
    block = stream.read(BLOCK)
    require(len(block) == BLOCK, "short storage-block read")
    return block


def convert(fixture, output):
    source = fixture / "read-lz4.img"
    report_path = output.with_name(output.name + ".json")
    require(not os.path.lexists(output) and not os.path.lexists(report_path),
            "refusing to overwrite output image or provenance")
    payload = (fixture / "source/payload").read_bytes()
    require(len(payload) == PAYLOAD_SIZE, "expected a 98335-byte source payload")
    require(source.is_file(), "input image must be a regular file")
    dump_tool = tool_command("DUMP_F2FS", "dump.f2fs")
    inject_tool = tool_command("INJECT_F2FS", "inject.f2fs")
    dump_version = run_tool(dump_tool + ["-V"]).strip()
    inject_version = run_tool(inject_tool + ["-V"]).strip()
    before = run_tool(dump_tool + ["-i", "4", str(source)], answer="N\n")
    addresses, tail_address = layout(before, 1)
    image_size = source.stat().st_size
    lz4, zstd = codecs()
    replacements, clusters = [], []
    with source.open("rb") as stream:
        for index, address in enumerate(addresses):
            block = read_block(stream, address, image_size)
            clen = struct.unpack_from("<I", block)[0]
            require(0 < clen <= BLOCK - HEADER and block[4:HEADER] == bytes(20),
                    f"invalid LZ4 header in cluster {index}")
            raw = ctypes.create_string_buffer(CLUSTER)
            decoded = lz4.LZ4_decompress_safe(block[HEADER:HEADER + clen], raw,
                                             clen, CLUSTER)
            expected = payload[index * CLUSTER:(index + 1) * CLUSTER]
            require(decoded == CLUSTER and raw.raw == expected,
                    f"LZ4 source mismatch in cluster {index}")
            frame = ctypes.create_string_buffer(zstd.ZSTD_compressBound(CLUSTER))
            size = zstd.ZSTD_compress(frame, len(frame), raw, CLUSTER, 1)
            check_zstd(zstd, size)
            require(0 < size <= BLOCK - HEADER, f"Zstd cluster {index} exceeds one block")
            check = ctypes.create_string_buffer(CLUSTER)
            decoded = zstd.ZSTD_decompress(check, CLUSTER, frame, size)
            check_zstd(zstd, decoded)
            require(decoded == CLUSTER and check.raw == expected,
                    f"Zstd round-trip mismatch in cluster {index}")
            replacements.append(struct.pack("<I", size) + bytes(20) +
                                frame.raw[:size] + bytes(BLOCK - HEADER - size))
            clusters.append({"index": index, "storage_block": address,
                             "lz4_bytes": clen, "zstd_bytes": size})
        tail = read_block(stream, tail_address, image_size)
        require(tail[:31] == payload[CLUSTERS * CLUSTER:], "partial-tail mismatch")

    source_hash = sha256(source)
    created_image = created_report = False
    try:
        with output.open("xb") as destination:
            created_image = True
            with source.open("rb") as original:
                shutil.copyfileobj(original, destination)
            for address, block in zip(addresses, replacements):
                destination.seek(address * BLOCK)
                destination.write(block)
        injection = inject_tool + ["--node", "--nid", "4", "--mb", "i_addr",
                                   "--idx", "8", "--val", "0x202", str(output)]
        injection_log = run_tool(injection)
        after = run_tool(dump_tool + ["-i", "4", str(output)], answer="N\n")
        require(layout(after, 2) == (addresses, tail_address),
                "injection changed the upstream storage layout")
        require(output.stat().st_size == image_size, "image size changed")
        with output.open("rb") as stream:
            for address, replacement in zip(addresses, replacements):
                require(read_block(stream, address, image_size) == replacement,
                        "rewritten cluster verification failed")
            require(read_block(stream, tail_address, image_size) == tail,
                    "uncompressed partial-tail block changed")
        require(sha256(source) == source_hash, "source image changed during conversion")
        report = {
            "fixture_kind": "Transformed upstream-format fixture with independent host Zstd encoder; NOT sload-native Zstd",
            "source_image": str(source), "source_image_sha256": source_hash,
            "output_image": str(output), "output_image_sha256": sha256(output),
            "payload_sha256": hashlib.sha256(payload).hexdigest(),
            "image_bytes": image_size, "inode": 4, "log_cluster_size": 2,
            "compression_algorithm": 2, "compression_flags": 0, "zstd_level": 1,
            "clusters": clusters, "preserved_tail_block": tail_address,
            "host_codecs": {"lz4": lz4.LZ4_versionString().decode(),
                            "zstd": zstd.ZSTD_versionString().decode()},
            "tools": {"dump": dump_tool, "dump_version": dump_version,
                      "inject": inject_tool, "inject_version": inject_version},
            "inject_command": injection,
            "checks": {"source_lz4_decode_matches_payload": True,
                       "zstd_round_trip_matches_payload": True,
                       "inode_address_and_count_layout_preserved": True,
                       "source_image_unchanged": True,
                       "guest_read": "unverified"},
            "tool_output": {"dump_before": before, "inject": injection_log,
                            "dump_after": after},
        }
        with report_path.open("x") as stream:
            created_report = True
            json.dump(report, stream, indent=2)
            stream.write("\n")
    except Exception:
        if created_report:
            report_path.unlink()
        if created_image:
            output.unlink()
        raise
    print(f"ZSTD_FIXTURE_READY: clusters=6 level=1 image={output} provenance={report_path}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("fixture_directory", type=Path)
    parser.add_argument("new_output_image", type=Path)
    args = parser.parse_args()
    try:
        convert(args.fixture_directory.resolve(), args.new_output_image.absolute())
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        print(f"ZSTD_FIXTURE_ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
