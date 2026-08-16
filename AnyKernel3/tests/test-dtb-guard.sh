#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Load the AnyKernel functions without running setup_ak.  The production
# script is sourced by anykernel.sh, while this test only exercises the DTB
# parser contract.
sed '/^[[:space:]]*setup_ak;[[:space:]]*$/d' "$ROOT/tools/ak3-core.sh" > "$TMP/core.sh"
mkdir -p "$TMP/bin" "$TMP/verify"

cat > "$TMP/bin/magiskboot" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" != dtb || "${3:-}" != print ]]; then
  exit 2
fi

case "$(basename "$2")" in
  good)
    cat <<'REPORT'
Loading dtbs from [good]
Printing dtb.0000
│  │  [boot_devices]: ["soc/1d84000.ufshc"]
Printing dtb.0001
│  │  [boot_devices]: ["soc/7c4000.sdhci"]
Printing dtb.0002
│  │  [boot_devices]: ["soc/1d84000.ufshc"]
Printing dtb.0003
│  │  [boot_devices]: ["soc/1d84000.ufshc"]
Printing dtb.0004
│  │  [boot_devices]: ["soc/1d84000.ufshc"]
Printing dtb.0005
│  │  [boot_devices]: ["soc/1d84000.ufshc"]
REPORT
    ;;
  wrong-order)
    cat <<'REPORT'
Loading dtbs from [wrong-order]
Printing dtb.0000
│  │  [boot_devices]: ["soc/7c4000.sdhci"]
Printing dtb.0001
│  │  [boot_devices]: ["soc/1d84000.ufshc"]
Printing dtb.0002
│  │  [boot_devices]: ["soc/1d84000.ufshc"]
Printing dtb.0003
│  │  [boot_devices]: ["soc/1d84000.ufshc"]
Printing dtb.0004
│  │  [boot_devices]: ["soc/1d84000.ufshc"]
Printing dtb.0005
│  │  [boot_devices]: ["soc/1d84000.ufshc"]
REPORT
    ;;
  malformed)
    echo 'Failed to process dtb' >&2
    exit 1
    ;;
  *)
    exit 3
    ;;
esac
EOF
chmod 755 "$TMP/bin/magiskboot"

touch "$TMP/good" "$TMP/wrong-order" "$TMP/malformed"

OUTFD=1
AKHOME="$TMP"
BIN="$TMP/bin"
DTB_VERIFY_DIR="$TMP/verify"
export OUTFD AKHOME BIN DTB_VERIFY_DIR
# shellcheck disable=SC1090
set +u
source "$TMP/core.sh" 1
set -u
# The production UI loop intentionally relies on an unset positional
# parameter to terminate; keep nounset enabled for the test itself without
# changing that installer behavior.
ui_print() { :; }

good=$(dtb_group_info "$TMP/good" good)
[[ "$good" == '6|soc/1d84000.ufshc' ]]

wrong=$(dtb_group_info "$TMP/wrong-order" wrong-order)
[[ "$wrong" == '6|soc/7c4000.sdhci' ]]
[[ "${wrong#*|}" != 'soc/1d84000.ufshc' ]]

if (dtb_group_info "$TMP/malformed" malformed); then
  echo "malformed DTB unexpectedly accepted" >&2
  exit 1
fi

if grep -q 'strings.*kernel_dtb' "$ROOT/tools/ak3-core.sh"; then
  echo "DTB selection still depends on strings(1)" >&2
  exit 1
fi

echo "DTB guard tests passed"
