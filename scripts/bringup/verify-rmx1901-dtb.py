#!/usr/bin/env python3
"""Verify the RMX1901 M2 base DTB and its known-good Android 17 overlay."""

import argparse
import pathlib
import shutil
import subprocess
import tempfile


class GateError(RuntimeError):
    pass


def run(*args: str, allow_failure: bool = False) -> str:
    result = subprocess.run(args, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE)
    if result.returncode and not allow_failure:
        detail = result.stderr.strip() or result.stdout.strip()
        raise GateError(f"{' '.join(args)} failed: {detail}")
    return result.stdout.strip() if result.returncode == 0 else ""


def require_tool(name: str) -> None:
    if not shutil.which(name):
        raise GateError(f"required tool is missing: {name}")


def strings(dtb: pathlib.Path, node: str, prop: str) -> list[str]:
    return run("fdtget", "-t", "s", str(dtb), node, prop).split()


def text(dtb: pathlib.Path, node: str, prop: str) -> str:
    return run("fdtget", "-t", "s", str(dtb), node, prop)


def cells(dtb: pathlib.Path, node: str, prop: str) -> list[int]:
    value = run("fdtget", "-t", "x", str(dtb), node, prop)
    return [int(part, 16) for part in value.split()]


def children(dtb: pathlib.Path, node: str) -> list[str]:
    value = run("fdtget", "-l", str(dtb), node, allow_failure=True)
    return value.splitlines() if value else []


def properties(dtb: pathlib.Path, node: str) -> set[str]:
    value = run("fdtget", "-p", str(dtb), node, allow_failure=True)
    return set(value.splitlines()) if value else set()


def expect_equal(actual, expected, label: str) -> None:
    if actual != expected:
        raise GateError(f"{label}: expected {expected!r}, got {actual!r}")


def symbol_path(dtb: pathlib.Path, symbol: str) -> str:
    return text(dtb, "/__symbols__", symbol)


def status_is_enabled(dtb: pathlib.Path, symbol: str) -> None:
    path = symbol_path(dtb, symbol)
    status = text(dtb, path, "status") if "status" in properties(dtb, path) else "okay"
    if status not in ("ok", "okay"):
        raise GateError(f"{symbol} ({path}) is not enabled: {status}")


def verify_identity(base: pathlib.Path, overlay: pathlib.Path) -> None:
    expect_equal(text(base, "/", "model"),
                 "Qualcomm Technologies, Inc. SDM710 SoC", "base model")
    expect_equal(strings(base, "/", "compatible"), ["qcom,sdm670"],
                 "base compatible")
    expect_equal(cells(base, "/", "qcom,msm-id"), [0x168, 0, 0x189, 0],
                 "base msm-id")
    expect_equal(cells(base, "/", "qcom,board-id"), [0, 0], "base board-id")
    expect_equal(cells(base, "/", "oppo,prjversion"), [1, 18041],
                 "base project")

    expect_equal(text(overlay, "/", "model"),
                 "Qualcomm Technologies, Inc. SDM710 PM660 + PM660A MTP",
                 "overlay model")
    expect_equal(strings(overlay, "/", "compatible"),
                 ["qcom,sdm670-mtp", "qcom,sdm670", "qcom,mtp"],
                 "overlay compatible")
    expect_equal(cells(overlay, "/", "qcom,msm-id"), [0x168, 0, 0x189, 0],
                 "overlay msm-id")
    expect_equal(cells(overlay, "/", "qcom,board-id"), [8, 0],
                 "overlay board-id")
    expect_equal(cells(overlay, "/", "oppo,prjversion"), [1, 18041],
                 "overlay project")


def verify_fixups(base: pathlib.Path, overlay: pathlib.Path) -> int:
    required = properties(overlay, "/__fixups__")
    available = properties(base, "/__symbols__")
    missing = sorted(required - available)
    if missing:
        raise GateError("overlay fixups missing from base symbols: " + ", ".join(missing))
    return len(required)


def combine_cells(parts: list[int]) -> int:
    value = 0
    for part in parts:
        value = (value << 32) | part
    return value


def verify_reserved_memory(dtb: pathlib.Path, label: str) -> int:
    root = "/reserved-memory"
    address_cells = cells(dtb, root, "#address-cells")[0]
    size_cells = cells(dtb, root, "#size-cells")[0]
    stride = address_cells + size_cells
    intervals: list[tuple[int, int, str]] = []
    ramoops = None

    for child in children(dtb, root):
        path = f"{root}/{child}"
        if "reg" not in properties(dtb, path):
            continue
        values = cells(dtb, path, "reg")
        if len(values) % stride:
            raise GateError(f"{label} {path}: malformed reg cells {values}")
        for offset in range(0, len(values), stride):
            start = combine_cells(values[offset:offset + address_cells])
            size = combine_cells(values[offset + address_cells:offset + stride])
            if size == 0:
                raise GateError(f"{label} {path}: zero-sized reserved region")
            intervals.append((start, start + size, path))
            if "compatible" in properties(dtb, path) and \
                    "ramoops" in strings(dtb, path, "compatible"):
                ramoops = (start, size)

    intervals.sort()
    for previous, current in zip(intervals, intervals[1:]):
        if current[0] < previous[1]:
            raise GateError(
                f"{label} reserved-memory overlap: {previous[2]} "
                f"[{previous[0]:#x}, {previous[1]:#x}) and {current[2]} "
                f"[{current[0]:#x}, {current[1]:#x})")

    expect_equal(ramoops, (0xB7E00000, 0x00400000), f"{label} ramoops")
    return len(intervals)


def verify_platform_nodes(dtb: pathlib.Path) -> None:
    expected = {
        "pdc": "qcom,pdc-sdm670",
        "clock_rpmh": "qcom,rpmh-clk-sdm670",
        "apps_rsc": "qcom,tcs-drv",
        "tlmm": "qcom,sdm670-pinctrl",
        "ufshc_mem": "qcom,ufshc",
        "spmi_bus": "qcom,spmi-pmic-arb",
    }
    for symbol, compatible in expected.items():
        path = symbol_path(dtb, symbol)
        if compatible not in strings(dtb, path, "compatible"):
            raise GateError(f"{symbol} ({path}) lacks {compatible}")
        status_is_enabled(dtb, symbol)

    ufsphy_path = symbol_path(dtb, "ufsphy_mem")
    if "qcom,ufs-phy-qmp-v3" not in strings(dtb, ufsphy_path, "compatible"):
        raise GateError(f"ufsphy_mem ({ufsphy_path}) lacks qcom,ufs-phy-qmp-v3")
    status_is_enabled(dtb, "ufsphy_mem")
    status_is_enabled(dtb, "ufs_phy_gdsc")
    expect_equal(strings(dtb, "/soc/interrupt-controller@17a00000", "compatible"),
                 ["arm,gic-v3"], "GIC compatible")
    expect_equal(strings(dtb, "/soc/timer", "compatible"),
                 ["arm,armv8-timer"], "architected timer compatible")


def verify_usb_nodes(dtb: pathlib.Path) -> None:
    qusb_path = symbol_path(dtb, "qusb_phy0")
    expect_equal(strings(dtb, qusb_path, "compatible"),
                 ["qcom,qusb2phy-v2"], "qusb compatible")
    expect_equal(
        cells(dtb, qusb_path, "qcom,qusb-phy-reg-offset"),
        [0x240, 0x1A0, 0x210, 0x230, 0x0A8, 0x254,
         0x198, 0x27C, 0x280, 0x284, 0x288, 0x2A0],
        "qusb reg offsets",
    )

    usb0_path = symbol_path(dtb, "usb0")
    if "qcom,num-gsi-evt-buffs" in properties(dtb, usb0_path):
        expect_equal(
            cells(dtb, usb0_path, "qcom,gsi-reg-offset"),
            [0x0FC, 0x110, 0x120, 0x130, 0x144, 0x1A4],
            "usb0 gsi reg offsets",
        )
    primary_dwc3_path = f"{usb0_path}/dwc3@a600000"
    expect_equal(text(dtb, primary_dwc3_path, "dr_mode"),
                 "otg", "primary dwc3 dr_mode")
    expect_equal(text(dtb, primary_dwc3_path, "maximum-speed"),
                 "high-speed", "primary dwc3 maximum-speed")


def verify_ufs_nodes(dtb: pathlib.Path) -> None:
    ufshc_path = symbol_path(dtb, "ufshc_mem")
    expect_equal(
        cells(dtb, ufshc_path, "reg"),
        [0x1D84000, 0x3000, 0x1D90000, 0x8000],
        "ufshc reg",
    )
    expect_equal(
        strings(dtb, ufshc_path, "reg-names"),
        ["ufs_mem", "ufs_ice"],
        "ufshc reg-names",
    )
    if "ufs-qcom-crypto" not in properties(dtb, ufshc_path):
        raise GateError(f"ufshc_mem ({ufshc_path}) is missing ufs-qcom-crypto")

    ufs_ice_path = symbol_path(dtb, "ufs_ice")
    if "qcom,ice" not in strings(dtb, ufs_ice_path, "compatible"):
        raise GateError(f"ufs_ice ({ufs_ice_path}) lacks qcom,ice")
    expect_equal(cells(dtb, ufs_ice_path, "reg"), [0x1D90000, 0x8000],
                 "ufs_ice reg")
    status_is_enabled(dtb, "ufs_ice")


def round_trip(dtb: pathlib.Path, directory: pathlib.Path) -> None:
    dts = directory / "roundtrip.dts"
    rebuilt = directory / "roundtrip.dtb"
    run("dtc", "-q", "-I", "dtb", "-O", "dts", "-o", str(dts), str(dtb))
    run("dtc", "-q", "-I", "dts", "-O", "dtb", "-o", str(rebuilt), str(dts))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("base_dtb", type=pathlib.Path)
    parser.add_argument("overlay_dtbo", type=pathlib.Path)
    args = parser.parse_args()

    for tool in ("fdtget", "fdtoverlay", "dtc"):
        require_tool(tool)
    if not args.base_dtb.is_file() or not args.overlay_dtbo.is_file():
        raise GateError("base DTB or overlay DTBO does not exist")

    verify_identity(args.base_dtb, args.overlay_dtbo)
    fixup_count = verify_fixups(args.base_dtb, args.overlay_dtbo)
    base_regions = verify_reserved_memory(args.base_dtb, "base")

    with tempfile.TemporaryDirectory(prefix="rmx1901-dtb-gate-") as temp:
        directory = pathlib.Path(temp)
        merged = directory / "merged.dtb"
        run("fdtoverlay", "-i", str(args.base_dtb), "-o", str(merged),
            str(args.overlay_dtbo))
        merged_regions = verify_reserved_memory(merged, "merged")
        verify_platform_nodes(merged)
        verify_usb_nodes(merged)
        verify_ufs_nodes(merged)
        round_trip(merged, directory)

    print("RMX1901 DTB gate: PASS")
    print(f"overlay fixups satisfied: {fixup_count}")
    print(f"reserved-memory regions: base={base_regions}, merged={merged_regions}")
    print("GIC/timer/RPMh/PDC/pinctrl/SPMI/UFS nodes: PASS")
    print("USB DT compatibility gate: PASS")
    print("UFS ICE DT compatibility gate: PASS")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except GateError as error:
        raise SystemExit(f"RMX1901 DTB gate: FAIL: {error}")
