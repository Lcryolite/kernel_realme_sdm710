#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0

set -u

script_dir=$(cd "$(dirname "$0")" && pwd)
source_repo=$(git -C "$script_dir" rev-parse --show-toplevel)
out_dir=${OUT_DIR:-$source_repo/device-evidence-desktop-first}
serial=${ANDROID_SERIAL:-}
adb_bin=${ADB:-adb}

mkdir -p "$out_dir"
adb_args=()
[[ -n "$serial" ]] && adb_args+=( -s "$serial" )

adb_cmd() {
	"$adb_bin" "${adb_args[@]}" "$@"
}

wait_for_device() {
	local timeout_seconds=${WAIT_TIMEOUT_SECONDS:-180}
	if command -v timeout >/dev/null 2>&1; then
		timeout "$timeout_seconds" "$adb_bin" "${adb_args[@]}" wait-for-device
	else
		adb_cmd wait-for-device
	fi
}

capture() {
	local name=$1
	shift
	if "$@" >"$out_dir/$name" 2>&1; then
		printf '%s=PASS\n' "$name" >>"$out_dir/collection-summary.txt"
	else
		printf '%s=FAIL\n' "$name" >>"$out_dir/collection-summary.txt"
	fi
}

{
	printf 'desktop-first device evidence\n'
	printf 'serial=%s\n' "${serial:-auto}"
	printf 'collected_at=%s\n' "$(date -Is)"
} >"$out_dir/collection-summary.txt"

capture wait-for-device wait_for_device
capture device-state adb_cmd get-state
capture properties adb_cmd shell getprop
capture boot-completion adb_cmd shell getprop sys.boot_completed
capture boot-reason adb_cmd shell getprop ro.boot.bootreason
capture kernel-release adb_cmd shell uname -a
capture cmdline adb_cmd shell cat /proc/cmdline
capture logcat-all adb_cmd logcat -b all -d
capture dmesg adb_cmd shell dmesg
capture surfaceflinger adb_cmd shell dumpsys SurfaceFlinger
capture display adb_cmd shell dumpsys display
capture input-devices adb_cmd shell getevent -lp
capture storage adb_cmd shell sh -c 'ls -l /dev/block/by-name; echo ---; ls -l /sys/class/block; echo ---; dmesg | grep -iE "ufs|ufshc|scsi|by-name|ice"'
capture usb-udc adb_cmd shell sh -c 'ls -l /sys/class/udc; echo ---; getprop | grep -iE "usb|adb"'

if adb_cmd exec-out screencap -p >"$out_dir/screencap.png" 2>"$out_dir/screencap.err"; then
	echo 'screencap=PASS' >>"$out_dir/collection-summary.txt"
else
	echo 'screencap=FAIL' >>"$out_dir/collection-summary.txt"
fi

printf 'evidence_dir=%s\n' "$out_dir" >>"$out_dir/collection-summary.txt"
printf 'desktop-first device collection complete: %s\n' "$out_dir"
