#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
source_repo=$(git -C "$script_dir" rev-parse --show-toplevel)
out_dir=${OUT_DIR:-$source_repo/out-desktop-first-rmx1901}
baseline_ref=${BASELINE_REF:-origin/a17-resukisu-linux-4.14-unfinished}
display_dts="$source_repo/arch/arm64/boot/dts/rmx1901/sdm670-sde.dtsi"
poweroff_source="$source_repo/drivers/power/reset/msm-poweroff.c"
summary="$out_dir/desktop-first-gate-summary.txt"
manifest="$out_dir/desktop-first-manifest.json"
llvm_bin_dir=${LLVM_BIN_DIR:-}
dtc_bin=${DTC_BIN:-}
fdtget_bin=${FDTGET_BIN:-}
fdtoverlay_bin=${FDTOVERLAY_BIN:-}

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

[[ -d "$source_repo/.git" || -f "$source_repo/.git" ]] ||
	die "source repository is not a Git worktree"
[[ -f "$display_dts" ]] || die "display DTS is missing: $display_dts"
[[ -f "$poweroff_source" ]] || die "poweroff source is missing: $poweroff_source"
[[ ! -e "$out_dir" ]] || die "output path already exists: $out_dir"
[[ -n "$llvm_bin_dir" ]] || die "LLVM_BIN_DIR is required; use the pinned LLVM 22 CI toolchain"
[[ -x "$llvm_bin_dir/clang" && -x "$llvm_bin_dir/ld.lld" ]] ||
	die "LLVM_BIN_DIR must contain clang and ld.lld: $llvm_bin_dir"

[[ -n "$dtc_bin" ]] || dtc_bin=$(command -v dtc || true)
[[ -n "$fdtget_bin" ]] || fdtget_bin=$(command -v fdtget || true)
[[ -n "$fdtoverlay_bin" ]] || fdtoverlay_bin=$(command -v fdtoverlay || true)
[[ -x "$dtc_bin" ]] || die "DTC_BIN is missing; install device-tree-compiler"
[[ -x "$fdtget_bin" ]] || die "FDTGET_BIN is missing; install device-tree-compiler"
[[ -x "$fdtoverlay_bin" ]] || die "FDTOVERLAY_BIN is missing; install device-tree-compiler"

clang_version=$("$llvm_bin_dir/clang" -dumpversion)
[[ "$clang_version" == 22.* ]] || die "desktop-first requires LLVM 22, found $clang_version"
cross_compile=${CROSS_COMPILE:-aarch64-linux-gnu-}
cross_compile_arm32=${CROSS_COMPILE_ARM32:-arm-linux-gnueabi-}
command -v "${cross_compile}elfedit" >/dev/null 2>&1 ||
	die "missing ${cross_compile}elfedit"
command -v "${cross_compile_arm32}ld" >/dev/null 2>&1 ||
	die "missing ${cross_compile_arm32}ld"
desktop_kcflags=${KCFLAGS:-}
case " $desktop_kcflags " in
	*' -Wno-error=implicit-enum-enum-cast '*) ;;
	*) desktop_kcflags="$desktop_kcflags -Wno-error=implicit-enum-enum-cast" ;;
esac
export LLVM_BIN_DIR="$llvm_bin_dir"
export DTC_BIN="$dtc_bin"
export FDTGET_BIN="$fdtget_bin"
export FDTOVERLAY_BIN="$fdtoverlay_bin"
export CROSS_COMPILE="$cross_compile"
export CROSS_COMPILE_ARM32="$cross_compile_arm32"
export KCFLAGS="$desktop_kcflags"
export PATH="$llvm_bin_dir:$(dirname "$dtc_bin"):$(dirname "$fdtget_bin"):$(dirname "$fdtoverlay_bin"):$PATH"

grep -Fq 'vdd-supply = <&mdss_core_gdsc>;' "$display_dts" ||
	die "sde_rscc no longer retains the mdss_core_gdsc owner"
if grep -Fq 'sde-vdd-supply = <&mdss_core_gdsc>;' "$display_dts"; then
	die "MDP still declares the duplicate sde-vdd supply"
fi
if grep -Fq 'qcom,supply-name = "sde-vdd";' "$display_dts"; then
	die "MDP still declares the duplicate sde-vdd platform supply"
fi
grep -Fq '#define RMX1901_BOOT_GUARD_DEFAULT_SECONDS	0' "$poweroff_source" ||
	die "desktop-first boot guard default is not disabled"

git -C "$source_repo" diff --check

# Reuse the verified r024 host-side build gates. This keeps the validated
# USB/UFS baseline while adding only the desktop-first changes.
OUT_DIR="$out_dir" "$script_dir/build-r024-usb-otg-dts.sh"

artifacts=(
	"$out_dir/.config"
	"$out_dir/Module.symvers"
	"$out_dir/vmlinux"
	"$out_dir/System.map"
	"$out_dir/arch/arm64/boot/Image"
	"$out_dir/arch/arm64/boot/Image.gz"
	"$out_dir/arch/arm64/boot/dts/rmx1901/sdm710.dtb"
	"$out_dir/r014-overlay46-merged.dtb"
)
for artifact in "${artifacts[@]}"; do
	[[ -f "$artifact" ]] || die "build artifact is missing: $artifact"
done

source_commit=$(git -C "$source_repo" rev-parse HEAD)
source_tree_state=clean
[[ -z $(git -C "$source_repo" status --porcelain) ]] || source_tree_state=dirty

{
	printf 'source_commit=%s\n' "$source_commit"
	printf 'baseline_ref=%s\n' "$baseline_ref"
	printf 'source_tree_state=%s\n' "$source_tree_state"
	printf 'candidate_kind=DESKTOP_FIRST\n'
	printf 'functional_changes=display_gdsc_single_owner,boot_guard_default_disabled\n'
	printf 'toolchain=LLVM_%s,device-tree-compiler\n' "$clang_version"
	printf 'compiler_compatibility_flags=-Wno-error=implicit-enum-enum-cast\n'
	printf 'preserved_baseline=USB_OTG_DTS,UFS_ICE,SMB2,panic_recovery,Android17_ramdisk\n'
	printf 'forbidden_changes=vendor,system,ramdisk,userdata,recovery,dtbo,vbmeta,public_uapi,ioctl,toolchain\n'
	printf 'boot_guard_default_seconds=0\n'
	printf 'device_write_scope=boot_only\n'
	printf 'device_acceptance=adb_online,sys_boot_completed_1,launcher_visible,touch_input\n'
	sha256sum "${artifacts[@]}"
} >"$summary"

hash_for() {
	sha256sum "$1" | awk '{print $1}'
}

mkdir -p "$out_dir"
{
	printf '{\n'
	printf '  "schema_version": 1,\n'
	printf '  "candidate_kind": "DESKTOP_FIRST",\n'
	printf '  "source_commit": "%s",\n' "$source_commit"
	printf '  "baseline_ref": "%s",\n' "$baseline_ref"
	printf '  "source_tree_state": "%s",\n' "$source_tree_state"
	printf '  "functional_changes": ["display_gdsc_single_owner", "boot_guard_default_disabled"],\n'
	printf '  "toolchain": "LLVM_%s + device-tree-compiler",\n' "$clang_version"
	printf '  "compiler_compatibility_flags": ["-Wno-error=implicit-enum-enum-cast"],\n'
	printf '  "preserved_baseline": ["USB_OTG_DTS", "UFS_ICE", "SMB2", "panic_recovery", "Android17_ramdisk"],\n'
	printf '  "forbidden_changes": ["vendor", "system", "ramdisk", "userdata", "recovery", "dtbo", "vbmeta", "public_uapi", "ioctl", "toolchain"],\n'
	printf '  "boot_guard_default_seconds": 0,\n'
	printf '  "device_write_scope": "boot_only",\n'
	printf '  "artifacts": {\n'
	printf '    "config": "%s",\n' "$(hash_for "$out_dir/.config")"
	printf '    "module_symvers": "%s",\n' "$(hash_for "$out_dir/Module.symvers")"
	printf '    "vmlinux": "%s",\n' "$(hash_for "$out_dir/vmlinux")"
	printf '    "system_map": "%s",\n' "$(hash_for "$out_dir/System.map")"
	printf '    "image": "%s",\n' "$(hash_for "$out_dir/arch/arm64/boot/Image")"
	printf '    "image_gz": "%s",\n' "$(hash_for "$out_dir/arch/arm64/boot/Image.gz")"
	printf '    "sdm710_dtb": "%s",\n' "$(hash_for "$out_dir/arch/arm64/boot/dts/rmx1901/sdm710.dtb")"
	printf '    "overlay46_merged_dtb": "%s"\n' "$(hash_for "$out_dir/r014-overlay46-merged.dtb")"
	printf '  },\n'
	printf '  "device_acceptance": {\n'
	printf '    "adb_online": null,\n'
	printf '    "sys_boot_completed": null,\n'
	printf '    "launcher_visible": null,\n'
	printf '    "touch_input": null\n'
	printf '  }\n'
	printf '}\n'
} >"$manifest"

printf 'desktop-first build: PASS\n'
printf 'gate summary: %s\n' "$summary"
printf 'manifest: %s\n' "$manifest"
