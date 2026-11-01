#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""Verify raw compressed storage relocation using native dump.f2fs output."""

import argparse
import hashlib
import json
from pathlib import Path
import re


def compressed_slots(path):
    text = path.read_text()

    def field(name):
        match = re.search(rf"^{name}\s+\[0x\s*([0-9a-f]+)\s*:", text, re.M)
        if match is None:
            raise ValueError(f"missing {name} in {path}")
        return int(match[1], 16)

    cluster = 1 << field("i_log_cluster_size")
    if not 4 <= cluster <= 256:
        raise ValueError("invalid cluster size")
    rows = {}
    for match in re.finditer(r"^i_addr\[0x([0-9a-f]+)\]([^\[\n]*)"
                            r"\[0x\s*([0-9a-f]+)\s*:", text, re.M):
        rows[int(match[1], 16)] = (match[2].strip(), int(match[3], 16))
    slots = {}
    for index, (label, value) in rows.items():
        if label != "cluster flag":
            continue
        if value != 0xfffffffe:
            raise ValueError("invalid marker")
        for slot in range(index + 1, index + cluster):
            label, address = rows[slot]
            if label == "reserved flag":
                break
            if label or not 0 < address < 0xfffffffe:
                raise ValueError("invalid compressed storage slot")
            slots[slot] = address
    if not slots:
        raise ValueError("no compressed storage slots")
    identity = tuple(field(name) for name in
                     ("i_size", "i_flags", "i_advise", "i_compr_blocks",
                      "i_compress_algorithm", "i_log_cluster_size"))
    return identity, slots


def block(stream, address):
    stream.seek(address * 4096)
    data = stream.read(4096)
    if len(data) != 4096:
        raise ValueError("short block read")
    return data


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("before_dump", type=Path)
    parser.add_argument("--before-image", type=Path)
    parser.add_argument("--after-dump", type=Path)
    parser.add_argument("--after-image", type=Path)
    args = parser.parse_args()
    identity, before = compressed_slots(args.before_dump)
    # The suite's fixed mkfs fixture uses 512-block aligned segments.
    start = min(before.values()) // 512 * 512
    if not any((args.before_image, args.after_dump, args.after_image)):
        print(start)
        return
    if not all((args.before_image, args.after_dump, args.after_image)):
        parser.error("verification requires both images and the after dump")
    after_identity, after = compressed_slots(args.after_dump)
    if identity != after_identity or before.keys() != after.keys():
        raise ValueError("GC changed compressed inode metadata or slot layout")
    moved = []
    with args.before_image.open("rb") as source, args.after_image.open("rb") as dest:
        for slot, address in before.items():
            old, new = block(source, address), block(dest, after[slot])
            if old != new:
                raise ValueError(f"GC changed stored bytes for logical slot {slot}")
            if start <= address < start + 512:
                if start <= after[slot] < start + 512:
                    raise ValueError(f"slot {slot} did not move outside target segment")
                moved.append({"slot": slot, "before": address, "after": after[slot],
                              "ciphertext_sha256": hashlib.sha256(old).hexdigest()})
    if not moved:
        raise ValueError("no compressed slots moved")
    print(json.dumps({"result": "GC_STORAGE_MOVE_PASS", "start": start,
                      "blocks": 512, "unchanged_ciphertext": moved}, indent=2))


if __name__ == "__main__":
    main()
