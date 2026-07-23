#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0

set -euo pipefail

usage() {
	cat >&2 <<'EOF'
Usage: capture-m3-recovery-evidence.sh BUILD_ID OUTPUT_DIRECTORY

Capture read-only RMX1901 evidence after a candidate boot attempt returns to
Recovery.  The script never flashes, clears pstore/rawdump, wipes data or
reboots the device.

Required environment:
  EXPECTED_BOOT_SHA256       SHA-256 of the candidate currently in boot
  BASELINE_RAWDUMP_SHA256    SHA-256 captured before the boot attempt
  RECOVERY_ENTRY_KIND        manual or automatic

Optional environment:
  EXPECTED_BOOTMODE          ro.bootmode expected with Recovery ADB;
                             defaults to recovery, permits reboot for a
                             recovery ramdisk started through normal boot
EOF
}

if [[ $# -ne 2 ]]; then
	usage
	exit 2
fi

build_id=$1
output_dir=$2
: "${EXPECTED_BOOT_SHA256:?EXPECTED_BOOT_SHA256 must be set}"
: "${BASELINE_RAWDUMP_SHA256:?BASELINE_RAWDUMP_SHA256 must be set}"
: "${RECOVERY_ENTRY_KIND:?RECOVERY_ENTRY_KIND must be set to manual or automatic}"
expected_bootmode=${EXPECTED_BOOTMODE:-recovery}

if [[ $RECOVERY_ENTRY_KIND != manual && $RECOVERY_ENTRY_KIND != automatic ]]; then
	echo "error: RECOVERY_ENTRY_KIND must be manual or automatic" >&2
	exit 1
fi
if [[ $expected_bootmode != recovery && $expected_bootmode != reboot ]]; then
	echo "error: EXPECTED_BOOTMODE must be recovery or reboot" >&2
	exit 1
fi
if [[ ! $EXPECTED_BOOT_SHA256 =~ ^[0-9a-f]{64}$ ||
	! $BASELINE_RAWDUMP_SHA256 =~ ^[0-9a-f]{64}$ ]]; then
	echo "error: expected hashes must be lowercase SHA-256 strings" >&2
	exit 1
fi
if [[ -e $output_dir ]]; then
	echo "error: output path already exists: $output_dir" >&2
	exit 1
fi
for tool in adb sha256sum stat; do
	if ! command -v "$tool" >/dev/null 2>&1; then
		echo "error: required tool is unavailable: $tool" >&2
		exit 1
	fi
done

state=$(adb get-state 2>/dev/null || true)
mode=$(adb shell getprop ro.bootmode 2>/dev/null | tr -d '\r')
uid=$(adb shell id -u 2>/dev/null | tr -d '\r')
if [[ $state != recovery || $mode != "$expected_bootmode" || $uid != 0 ]]; then
	echo "error: root Recovery ADB with bootmode=$expected_bootmode is required (state=$state mode=$mode uid=$uid)" >&2
	exit 1
fi

boot_device=$(adb shell readlink -f /dev/block/by-name/boot | tr -d '\r')
rawdump_device=$(adb shell readlink -f /dev/block/by-name/rawdump | tr -d '\r')
boot_bytes=$(adb shell blockdev --getsize64 /dev/block/by-name/boot | tr -d '\r')
rawdump_bytes=$(adb shell blockdev --getsize64 /dev/block/by-name/rawdump | tr -d '\r')
boot_sha=$(adb shell sha256sum /dev/block/by-name/boot | awk '{print $1}' | tr -d '\r')
rawdump_sha=$(adb shell sha256sum /dev/block/by-name/rawdump | awk '{print $1}' | tr -d '\r')

if [[ $boot_bytes != 67108864 || $rawdump_bytes != 134217728 ]]; then
	echo "error: unexpected boot/rawdump partition size" >&2
	exit 1
fi
if [[ $boot_sha != "$EXPECTED_BOOT_SHA256" ]]; then
	echo "error: boot partition does not contain the declared candidate" >&2
	exit 1
fi

mkdir -p "$output_dir/pstore" "$output_dir/recovery-logs"
captured_at=$(date --iso-8601=seconds)

{
	printf 'build_id=%s\n' "$build_id"
	printf 'captured_at=%s\n' "$captured_at"
	printf 'recovery_entry_kind=%s\n' "$RECOVERY_ENTRY_KIND"
	printf 'adb_state=%s\n' "$state"
	printf 'bootmode=%s\n' "$mode"
	printf 'adb_uid=%s\n' "$uid"
	printf 'battery_percent=%s\n' \
		"$(adb shell cat /sys/class/power_supply/battery/capacity | tr -d '\r')"
	printf 'boot_device=%s\n' "$boot_device"
	printf 'boot_bytes=%s\n' "$boot_bytes"
	printf 'boot_sha256=%s\n' "$boot_sha"
	printf 'rawdump_device=%s\n' "$rawdump_device"
	printf 'rawdump_bytes=%s\n' "$rawdump_bytes"
	printf 'rawdump_before_sha256=%s\n' "$BASELINE_RAWDUMP_SHA256"
	printf 'rawdump_after_sha256=%s\n' "$rawdump_sha"
	if [[ $rawdump_sha == "$BASELINE_RAWDUMP_SHA256" ]]; then
		printf 'rawdump_changed=false\n'
	else
		printf 'rawdump_changed=true\n'
	fi
} >"$output_dir/state.txt"

adb exec-out 'cat /proc/cmdline' >"$output_dir/recovery-cmdline.txt"
adb shell 'getprop ro.boot.bootreason; getprop sys.boot.reason; getprop ro.boot.boot_recovery; cat /sys/power/boot_reason 2>/dev/null || true; cat /proc/sys/kernel/boot_reason 2>/dev/null || true' \
	>"$output_dir/bootreason.txt"
adb shell 'cat /sys/power/pon_reason 2>/dev/null || true; cat /sys/power/poff_reason 2>/dev/null || true' \
	>"$output_dir/power-reasons.txt"
adb shell 'dmesg 2>/dev/null || true' >"$output_dir/recovery-dmesg.txt"

mapfile -t pstore_files < <(
	adb shell 'find /sys/fs/pstore -maxdepth 1 -type f -print 2>/dev/null' |
		tr -d '\r'
)
for remote_file in "${pstore_files[@]}"; do
	[[ -n $remote_file ]] || continue
	name=${remote_file##*/}
	adb exec-out "cat '$remote_file'" >"$output_dir/pstore/$name"
done

for remote_file in /tmp/recovery.log /cache/recovery/last_log \
	/cache/recovery/last_kmsg; do
	if adb shell "test -f '$remote_file'"; then
		name=${remote_file##*/}
		adb exec-out "cat '$remote_file'" \
			>"$output_dir/recovery-logs/$name"
	fi
done

adb exec-out 'cat /dev/block/by-name/boot' >"$output_dir/boot-readback.img"
if [[ $(stat -c '%s' "$output_dir/boot-readback.img") != 67108864 ]]; then
	echo "error: boot readback is not exactly 64 MiB" >&2
	exit 1
fi
host_boot_sha=$(sha256sum "$output_dir/boot-readback.img" | cut -d' ' -f1)
if [[ $host_boot_sha != "$EXPECTED_BOOT_SHA256" ]]; then
	echo "error: host boot readback does not match the candidate" >&2
	exit 1
fi

if [[ $rawdump_sha != "$BASELINE_RAWDUMP_SHA256" ]]; then
	adb exec-out 'cat /dev/block/by-name/rawdump' >"$output_dir/rawdump.img"
	if [[ $(stat -c '%s' "$output_dir/rawdump.img") != 134217728 ]]; then
		echo "error: rawdump readback is not exactly 128 MiB" >&2
		exit 1
	fi
	host_rawdump_sha=$(sha256sum "$output_dir/rawdump.img" | cut -d' ' -f1)
	if [[ $host_rawdump_sha != "$rawdump_sha" ]]; then
		echo "error: host rawdump readback changed during capture" >&2
		exit 1
	fi
fi

find "$output_dir" -type f ! -name SHA256SUMS -print0 |
	sort -z | xargs -0 sha256sum >"$output_dir/SHA256SUMS"
printf 'capture_pass build_id=%s boot=%s rawdump_before=%s rawdump_after=%s pstore_files=%d\n' \
	"$build_id" "$boot_sha" "$BASELINE_RAWDUMP_SHA256" "$rawdump_sha" \
	"${#pstore_files[@]}"
