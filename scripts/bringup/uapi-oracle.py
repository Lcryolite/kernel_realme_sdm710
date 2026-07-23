#!/usr/bin/env python3
"""Generate and compare RMX1901 vendor UAPI layout oracles.

The generator asks the pinned Clang frontend to parse the selected exported
headers for one target ABI, then compiles sizeof/offsetof/enum/macro
expressions to LLVM IR.  No target binary is executed on the host.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from typing import Any, Iterable


PREAMBLE = """\
#include <linux/types.h>
#include <linux/ioctl.h>
#include <sys/time.h>
#ifndef __user
#define __user
#endif
#ifndef __packed
#define __packed __attribute__((packed))
#endif
typedef int pid_t;
typedef unsigned int uid_t;
typedef __SIZE_TYPE__ size_t;
typedef __PTRDIFF_TYPE__ ssize_t;
typedef __INTPTR_TYPE__ off_t;
typedef __INT8_TYPE__ int8_t;
typedef __UINT8_TYPE__ uint8_t;
typedef __INT16_TYPE__ int16_t;
typedef __UINT16_TYPE__ uint16_t;
typedef __INT32_TYPE__ int32_t;
typedef __UINT32_TYPE__ uint32_t;
typedef __INT64_TYPE__ int64_t;
typedef __UINT64_TYPE__ uint64_t;
typedef __INTPTR_TYPE__ intptr_t;
typedef __UINTPTR_TYPE__ uintptr_t;
typedef _Bool bool;
"""


CATEGORIES: dict[str, dict[str, Any]] = {
    "binder": {
        "installed": ["linux/android/binder.h"],
        "prefixes": ["BINDER_", "FLAT_BINDER_"],
    },
    "ashmem": {
        "source": ["drivers/staging/android/uapi/ashmem.h"],
        "prefixes": ["ASHMEM_"],
    },
    "ion": {
        "installed": ["linux/ion.h", "linux/msm_ion.h"],
        "prefixes": ["ION_", "TARGET_ION_"],
    },
    "kgsl": {
        "installed": ["linux/msm_kgsl.h"],
        "prefixes": ["KGSL_", "IOCTL_KGSL_"],
    },
    "drm_sde": {
        "installed": ["drm/msm_drm.h", "drm/sde_drm.h"],
        "prefixes": ["DRM_", "MSM_", "SDE_"],
    },
    "camera": {
        "installed_glob": ["media/cam_*.h"],
        "installed": [
            "media/msm_cam_sensor.h",
            "media/msm_camera.h",
            "media/msm_camsensor_sdk.h",
            "media/msmb_camera.h",
        ],
        "prefixes": ["CAM_", "MSM_", "VIDIOC_"],
    },
    "vidc": {
        "installed": [
            "media/msm_vidc.h",
            "media/msm_vidc_private.h",
            "linux/msm_vidc_dec.h",
            "linux/msm_vidc_enc.h",
        ],
        "prefixes": [
            "MSM_VIDC_",
            "V4L2_CID_MPEG_VIDC_",
            "V4L2_PIX_FMT_",
            "VIDIOC_",
        ],
    },
    "qsee": {
        "installed": ["linux/qseecom.h"],
        "prefixes": ["QSEECOM_"],
    },
    "ipa_rmnet": {
        "installed": [
            "linux/ipa_qmi_service_v01.h",
            "linux/msm_ipa.h",
            "linux/msm_rmnet.h",
            "linux/rmnet_data.h",
            "linux/rmnet_ipa_fd_ioctl.h",
        ],
        "prefixes": ["IPA_", "RMNET_", "WWAN_"],
    },
    "audio": {
        "source_glob": ["techpack/audio/include/uapi/**/*.h"],
        "prefixes": ["AUDIO_", "MSM_", "SND_", "SNDRV_"],
    },
    "fscrypt_verity": {
        "installed": ["linux/fs.h", "linux/fscrypt.h", "linux/fsverity.h"],
        "prefixes": ["FS_", "FS_IOC", "FSCRYPT_", "FS_VERITY_", "F2FS_"],
    },
}


TARGETS = {
    "arm64": "aarch64-linux-android",
    "arm32": "arm-linux-androideabi",
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def run(
    command: list[str], source: str, *, check: bool = True
) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        command,
        input=source,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if check and result.returncode:
        raise RuntimeError(
            f"command failed ({result.returncode}): {' '.join(command)}\n"
            f"{result.stderr}"
        )
    return result


def git_head(tree: Path) -> str:
    return subprocess.check_output(
        ["git", "-C", str(tree), "rev-parse", "HEAD"], text=True
    ).strip()


def clang_base(clang: Path, target: str, installed: Path, tree: Path) -> list[str]:
    resource = subprocess.check_output(
        [str(clang), "-print-resource-dir"], text=True
    ).strip()
    return [
        str(clang),
        f"--target={target}",
        "-x",
        "c",
        "-",
        "-nostdinc",
        "-isystem",
        str(Path(resource) / "include"),
        "-I",
        str(Path(__file__).resolve().parent / "uapi-shims"),
        "-I",
        str(installed),
        "-I",
        str(tree / "techpack/audio/include/uapi"),
        "-I",
        str(tree / "techpack/audio/4.0/include/uapi"),
        "-Wno-everything",
    ]


def unique_paths(paths: Iterable[Path]) -> list[Path]:
    seen: set[Path] = set()
    answer: list[Path] = []
    for path in paths:
        resolved = path.resolve()
        if resolved not in seen:
            seen.add(resolved)
            answer.append(resolved)
    return answer


def resolve_headers(
    category: dict[str, Any], tree: Path, installed: Path
) -> tuple[list[Path], list[str]]:
    requested: list[Path] = []
    for relative in category.get("installed", []):
        requested.append(installed / relative)
    for pattern in category.get("installed_glob", []):
        requested.extend(sorted(installed.glob(pattern)))
    for relative in category.get("source", []):
        requested.append(tree / relative)
    for pattern in category.get("source_glob", []):
        requested.extend(sorted(tree.glob(pattern)))

    present: list[Path] = []
    missing: list[str] = []
    for path in unique_paths(requested):
        if path.is_file():
            present.append(path)
        else:
            missing.append(str(path))
    return present, sorted(missing)


def header_label(path: Path, tree: Path, installed: Path) -> str:
    try:
        return f"installed/{path.relative_to(installed)}"
    except ValueError:
        try:
            return f"source/{path.relative_to(tree)}"
        except ValueError:
            return path.name


def include_source(headers: list[Path]) -> str:
    lines = [PREAMBLE.rstrip()]
    lines.extend(f'#include "{path}"' for path in headers)
    return "\n".join(lines) + "\n"


def walk_nodes(node: Any) -> Iterable[dict[str, Any]]:
    if isinstance(node, dict):
        yield node
        for child in node.get("inner", []):
            yield from walk_nodes(child)
    elif isinstance(node, list):
        for child in node:
            yield from walk_nodes(child)


def ast_declarations(
    clang: Path,
    base: list[str],
    source: str,
) -> tuple[dict[str, list[dict[str, Any]]], list[str]]:
    command = base + ["-fsyntax-only", "-Xclang", "-ast-dump=json"]
    result = run(command, source)
    root = json.loads(result.stdout)

    records: dict[str, list[dict[str, Any]]] = {}
    enums: set[str] = set()
    for node in walk_nodes(root):
        kind = node.get("kind")
        if kind == "RecordDecl" and node.get("completeDefinition"):
            tag = node.get("tagUsed")
            name = node.get("name")
            if tag not in {"struct", "union"} or not name:
                continue
            key = f"{tag} {name}"
            fields: list[dict[str, Any]] = []
            for child in node.get("inner", []):
                if child.get("kind") not in {"FieldDecl", "IndirectFieldDecl"}:
                    continue
                if not child.get("name"):
                    continue
                fields.append(
                    {
                        "name": child["name"],
                        "type": child.get("type", {}).get("qualType", ""),
                        "bitfield": bool(child.get("isBitfield")),
                    }
                )
            records.setdefault(key, fields)
        elif kind == "EnumConstantDecl" and node.get("name"):
            enums.add(node["name"])
    return records, sorted(enums)


MACRO_LINE = re.compile(r"^#define ([A-Za-z_][A-Za-z0-9_]*)(.*)$")


def macro_candidates(
    clang: Path,
    base: list[str],
    source: str,
    prefixes: list[str],
) -> list[str]:
    result = run(base + ["-dM", "-E"], source)
    answer: set[str] = set()
    for line in result.stdout.splitlines():
        match = MACRO_LINE.match(line)
        if not match:
            continue
        name, tail = match.groups()
        if tail.startswith("("):
            continue
        body = tail.strip()
        if not body or not any(name.startswith(prefix) for prefix in prefixes):
            continue
        if '"' in body or "{" in body or "}" in body:
            continue
        if body.startswith(("struct ", "union ", "enum ")):
            continue
        answer.add(name)
    return sorted(answer)


def add_measurements(
    records: dict[str, list[dict[str, Any]]],
    enums: list[str],
    macros: list[str],
) -> list[dict[str, str]]:
    measurements: list[dict[str, str]] = []
    for record, fields in sorted(records.items()):
        measurements.append(
            {"kind": "record_size", "name": record, "expression": f"sizeof({record})"}
        )
        for field in fields:
            if field["bitfield"]:
                continue
            measurements.append(
                {
                    "kind": "field_offset",
                    "name": f"{record}.{field['name']}",
                    "expression": f"__builtin_offsetof({record}, {field['name']})",
                }
            )
    measurements.extend(
        {"kind": "enum", "name": name, "expression": name} for name in enums
    )
    measurements.extend(
        {"kind": "macro", "name": name, "expression": name} for name in macros
    )
    return measurements


STDIN_ERROR = re.compile(r"<stdin>:(\d+):\d+: error:")
IR_VALUE = re.compile(
    r"^@(?P<id>oracle_[0-9]{6}) = .*\bconstant i64 (?P<value>-?[0-9]+),",
    re.MULTILINE,
)


def compile_measurements(
    base: list[str],
    source: str,
    measurements: list[dict[str, str]],
) -> tuple[dict[tuple[str, str], int], list[dict[str, str]]]:
    active = list(measurements)
    skipped: list[dict[str, str]] = []
    for _attempt in range(12):
        prefix = source.rstrip().splitlines()
        first_line = len(prefix) + 1
        ids: dict[str, dict[str, str]] = {}
        lines = list(prefix)
        for index, item in enumerate(active):
            oracle_id = f"oracle_{index:06d}"
            ids[oracle_id] = item
            lines.append(
                f"const unsigned long long {oracle_id} = "
                f"(unsigned long long)({item['expression']});"
            )
        compilation = "\n".join(lines) + "\n"
        result = run(base + ["-S", "-emit-llvm", "-O0", "-o", "-"], compilation, check=False)
        if result.returncode == 0:
            values: dict[tuple[str, str], int] = {}
            found: set[str] = set()
            for match in IR_VALUE.finditer(result.stdout):
                oracle_id = match.group("id")
                if oracle_id not in ids:
                    continue
                item = ids[oracle_id]
                values[(item["kind"], item["name"])] = int(match.group("value"))
                found.add(oracle_id)
            missing_ids = sorted(set(ids) - found)
            if missing_ids:
                skipped.extend(ids[oracle_id] for oracle_id in missing_ids)
            return values, skipped

        bad_indexes: set[int] = set()
        for match in STDIN_ERROR.finditer(result.stderr):
            line_number = int(match.group(1))
            index = line_number - first_line
            if 0 <= index < len(active):
                bad_indexes.add(index)
        if not bad_indexes:
            raise RuntimeError(f"header/measurement compile failed:\n{result.stderr}")
        next_active: list[dict[str, str]] = []
        for index, item in enumerate(active):
            if index in bad_indexes:
                skipped.append(item)
            else:
                next_active.append(item)
        active = next_active
    raise RuntimeError("too many measurement error-recovery passes")


def category_oracle(
    name: str,
    config: dict[str, Any],
    tree: Path,
    installed: Path,
    clang: Path,
    target: str,
) -> dict[str, Any]:
    headers, missing = resolve_headers(config, tree, installed)
    if not headers:
        raise RuntimeError(f"{name}: no headers resolved")
    base = clang_base(clang, target, installed, tree)
    record_output: dict[str, Any] = {}
    enum_output: dict[str, int] = {}
    macro_output: dict[str, int] = {}
    skipped_output: list[dict[str, str]] = []
    header_failures: list[dict[str, str]] = []

    for header in headers:
        label = header_label(header, tree, installed)

        source = include_source([header])
        try:
            records, enums = ast_declarations(clang, base, source)
            macros = macro_candidates(clang, base, source, config["prefixes"])
            measurements = add_measurements(records, enums, macros)
            values, skipped = compile_measurements(base, source, measurements)
        except RuntimeError as error:
            header_failures.append({"header": label, "error": str(error)})
            continue

        for item in skipped:
            skipped_output.append({"header": label, **item})
        for record, fields in sorted(records.items()):
            size = values.get(("record_size", record))
            if size is None:
                continue
            field_output: dict[str, int] = {}
            for field in fields:
                offset = values.get(("field_offset", f"{record}.{field['name']}"))
                if offset is not None:
                    field_output[field["name"]] = offset
            record_output[f"{label}::{record}"] = {
                "sizeof": size,
                "offsetof": field_output,
            }
        for enum in enums:
            key = ("enum", enum)
            if key in values:
                enum_output[f"{label}::{enum}"] = values[key]
        for macro in macros:
            key = ("macro", macro)
            if key in values:
                macro_output[f"{label}::{macro}"] = values[key]

    return {
        "headers": [
            {
                "path": header_label(path, tree, installed),
                "sha256": sha256(path),
            }
            for path in headers
        ],
        "missing_headers": [
            header_label(Path(path), tree, installed) for path in missing
        ],
        "header_failures": header_failures,
        "records": record_output,
        "enums": enum_output,
        "macros": macro_output,
        "skipped_expressions": skipped_output,
        "counts": {
            "headers": len(headers),
            "missing_headers": len(missing),
            "header_failures": len(header_failures),
            "records": len(record_output),
            "fields": sum(len(item["offsetof"]) for item in record_output.values()),
            "enums": len(enum_output),
            "macros": len(macro_output),
            "skipped": len(skipped_output),
        },
    }


def generate(args: argparse.Namespace) -> None:
    tree = Path(args.kernel_tree).resolve()
    installed = Path(args.installed_headers).resolve() / "include"
    clang = Path(args.clang).resolve()
    output = Path(args.output).resolve()
    if output.exists():
        raise RuntimeError(f"output already exists: {output}")
    if args.arch not in TARGETS:
        raise RuntimeError(f"unsupported ABI: {args.arch}")

    categories: dict[str, Any] = {}
    for name, config in CATEGORIES.items():
        print(f"UAPI oracle: {args.arch} {name}", file=sys.stderr, flush=True)
        categories[name] = category_oracle(
            name, config, tree, installed, clang, TARGETS[args.arch]
        )

    document = {
        "schema": 1,
        "kernel_tree": tree.name,
        "kernel_commit": git_head(tree),
        "abi": args.arch,
        "target": TARGETS[args.arch],
        "clang": subprocess.check_output([str(clang), "--version"], text=True)
        .splitlines()[0]
        .strip(),
        "categories": categories,
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n")


def flatten(document: dict[str, Any]) -> dict[str, int]:
    result: dict[str, int] = {}
    for category, data in document["categories"].items():
        for record, layout in data["records"].items():
            result[f"{category}/sizeof/{record}"] = layout["sizeof"]
            for field, offset in layout["offsetof"].items():
                result[f"{category}/offsetof/{record}.{field}"] = offset
        for enum, value in data["enums"].items():
            result[f"{category}/constant/{enum}"] = value
        for macro, value in data["macros"].items():
            result[f"{category}/constant/{macro}"] = value
    return result


def compare(args: argparse.Namespace) -> None:
    baseline_path = Path(args.baseline).resolve()
    candidate_path = Path(args.candidate).resolve()
    output = Path(args.output).resolve()
    if output.exists():
        raise RuntimeError(f"output already exists: {output}")
    baseline_document = json.loads(baseline_path.read_text())
    candidate_document = json.loads(candidate_path.read_text())
    if baseline_document["abi"] != candidate_document["abi"]:
        raise RuntimeError("cannot compare different target ABIs")
    baseline = flatten(baseline_document)
    candidate = flatten(candidate_document)
    keys = sorted(set(baseline) | set(candidate))
    changes = []
    for key in keys:
        old = baseline.get(key)
        new = candidate.get(key)
        if old != new:
            changes.append({"key": key, "baseline": old, "candidate": new})
    additions = [change for change in changes if change["baseline"] is None]
    removals = [change for change in changes if change["candidate"] is None]
    value_changes = [
        change
        for change in changes
        if change["baseline"] is not None and change["candidate"] is not None
    ]
    incompatible = removals + value_changes
    document = {
        "schema": 1,
        "abi": baseline_document["abi"],
        "baseline": baseline_path.name,
        "candidate": candidate_path.name,
        "baseline_values": len(baseline),
        "candidate_values": len(candidate),
        "equal_values": sum(
            1 for key in keys if key in baseline and baseline[key] == candidate.get(key)
        ),
        "differences": len(changes),
        "additions": len(additions),
        "removals": len(removals),
        "value_changes": len(value_changes),
        "incompatible_differences": len(incompatible),
        "changes": changes,
        "incompatible_changes": incompatible,
        "pass": not incompatible,
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n")
    print(
        f"{document['abi']} UAPI: {document['incompatible_differences']} "
        f"incompatible, {document['additions']} additions across {len(keys)} keys"
    )


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    subparsers = result.add_subparsers(dest="command", required=True)
    generate_parser = subparsers.add_parser("generate")
    generate_parser.add_argument("--kernel-tree", required=True)
    generate_parser.add_argument("--installed-headers", required=True)
    generate_parser.add_argument("--arch", choices=sorted(TARGETS), required=True)
    generate_parser.add_argument("--clang", required=True)
    generate_parser.add_argument("--output", required=True)
    generate_parser.set_defaults(function=generate)

    compare_parser = subparsers.add_parser("compare")
    compare_parser.add_argument("--baseline", required=True)
    compare_parser.add_argument("--candidate", required=True)
    compare_parser.add_argument("--output", required=True)
    compare_parser.set_defaults(function=compare)
    return result


def main() -> int:
    args = parser().parse_args()
    try:
        args.function(args)
    except (OSError, RuntimeError, subprocess.CalledProcessError, json.JSONDecodeError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
