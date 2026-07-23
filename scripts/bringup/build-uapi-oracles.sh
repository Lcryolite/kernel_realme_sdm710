#!/usr/bin/env bash
set -euo pipefail

expected_baseline=e7a1612ee260c815354c80c13440eaf49e8b30f4
script_repo=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
baseline_tree="${BASELINE_TREE:-/home/lknife/android/kernel_realme_sdm710-lcryolite-a17}"
candidate_tree="${CANDIDATE_TREE:-$script_repo}"
evidence_dir="${EVIDENCE_DIR:-}"
clang="${CLANG_BIN:-/home/lknife/android/toolchains/aosp-android11/clang-r383902/bin/clang}"
oracle="$script_repo/scripts/bringup/uapi-oracle.py"

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

[[ -n $evidence_dir ]] || die "set EVIDENCE_DIR to a new evidence directory"
[[ ! -e $evidence_dir ]] || die "EVIDENCE_DIR must not exist: $evidence_dir"
[[ -x $clang ]] || die "pinned Clang is missing: $clang"
[[ -x $oracle ]] || die "UAPI oracle generator is missing: $oracle"
[[ $(git -C "$baseline_tree" rev-parse HEAD) == "$expected_baseline" ]] ||
	die "4.9 baseline commit changed"
git -C "$baseline_tree" diff --quiet || die "4.9 baseline has tracked changes"
git -C "$candidate_tree" diff --quiet || die "4.14 candidate has tracked changes"

mkdir -p "$evidence_dir"

install_headers() {
	local name=$1
	local tree=$2
	local arch=$3
	local root="$evidence_dir/$name"

	mkdir -p "$root"
	make -C "$tree" O="$root/out" ARCH="$arch" \
		INSTALL_HDR_PATH="$root/installed" headers_install \
		>"$root/headers-install.log" 2>&1
}

install_headers old64 "$baseline_tree" arm64
install_headers old32 "$baseline_tree" arm
install_headers new64 "$candidate_tree" arm64
install_headers new32 "$candidate_tree" arm

"$oracle" generate --kernel-tree "$baseline_tree" \
	--installed-headers "$evidence_dir/old64/installed" --arch arm64 \
	--clang "$clang" --output "$evidence_dir/old64/oracle.json"
"$oracle" generate --kernel-tree "$baseline_tree" \
	--installed-headers "$evidence_dir/old32/installed" --arch arm32 \
	--clang "$clang" --output "$evidence_dir/old32/oracle.json"
"$oracle" generate --kernel-tree "$candidate_tree" \
	--installed-headers "$evidence_dir/new64/installed" --arch arm64 \
	--clang "$clang" --output "$evidence_dir/new64/oracle.json"
"$oracle" generate --kernel-tree "$candidate_tree" \
	--installed-headers "$evidence_dir/new32/installed" --arch arm32 \
	--clang "$clang" --output "$evidence_dir/new32/oracle.json"

for name in old64 old32 new64 new32; do
	failures=$(jq '[.categories[].counts.header_failures] | add' \
		"$evidence_dir/$name/oracle.json")
	[[ $failures == 0 ]] || die "$name has $failures unparsed UAPI headers"
done

"$oracle" compare --baseline "$evidence_dir/old64/oracle.json" \
	--candidate "$evidence_dir/new64/oracle.json" \
	--output "$evidence_dir/diff-arm64.json"
"$oracle" compare --baseline "$evidence_dir/old32/oracle.json" \
	--candidate "$evidence_dir/new32/oracle.json" \
	--output "$evidence_dir/diff-arm32.json"

sha256sum \
	"$evidence_dir/old64/oracle.json" \
	"$evidence_dir/old32/oracle.json" \
	"$evidence_dir/new64/oracle.json" \
	"$evidence_dir/new32/oracle.json" \
	"$evidence_dir/diff-arm64.json" \
	"$evidence_dir/diff-arm32.json" >"$evidence_dir/sha256sums.txt"

printf 'UAPI oracle evidence: %s\n' "$evidence_dir"
for abi in arm64 arm32; do
	jq -r '"\(.abi): incompatible=\(.incompatible_differences) additions=\(.additions) pass=\(.pass)"' \
		"$evidence_dir/diff-$abi.json"
done
