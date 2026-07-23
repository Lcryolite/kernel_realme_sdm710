# RMX1901 Linux 4.14 bring-up

This directory contains machine-readable evidence and gates for the staged
RMX1901 Android 17 Linux 4.14 bring-up.  A successful build is not a flashable
release.  Device writes remain forbidden until the matching milestone gate is
explicitly passed.

The source of truth is split deliberately:

- Linux 4.14 framework: fixed `android_kernel_qcom_sm8150` donor commit.
- RMX1901 hardware and vendor ABI facts: the existing Linux 4.9 device tree,
  runtime evidence and userspace headers.
- Recovery and rollback facts: the read-back images recorded by the M0
  manifest.

## Current gates

| Milestone | State | Meaning |
| --- | --- | --- |
| M0 recovery safety | PASS | Two read-backs, two physical disks, byte/hash match, known-good r38 identified. |
| M0 UAPI oracle | PASS | All 35,664 measured 4.9 values match on arm64 and arm32; 2,745 candidate-only additions are permitted. |
| M1 donor control | PASS | Clean Image/Image.gz/dtbs/modules build reproduced with pinned tools. |
| M2 SDM670 static port | PASS | The current d13ec62 candidate passes two clean, byte-identical builds plus config, warning, certificate and DT gates. |
| M3 device boot | R013 FLASHED / FULL READBACK PASS / PREBOOT | r012 proved the legacy `CTL_TOP[7:4]` fix and passed continuous-splash validation before a trustworthy CPU2 SError. r013 preserves that behavior and adds 37 boundary markers around vblank, runtime PM, SDE IRQ register access, `request_irq`, first IRQ handling, DRM registration and mode reset. The boot-only write, device SHA and complete 64 MiB host readback pass; repeated-write approval is cleared pending runtime evidence. |

## Reproduction

Fetch and verify the pinned toolchain:

```sh
scripts/bringup/fetch-aosp-android11-toolchain.sh
```

Run an empty-output donor control build:

```sh
git worktree add ../kernel-qcom-sm8150-m1-control \
  dbc6d0dab1093092d15c64ffd79a713ba214c107
SOURCE_REPO="$(realpath ../kernel-qcom-sm8150-m1-control)" \
OUT_DIR="$(realpath ../kernel-qcom-sm8150-m1-control)/out-donor-control" \
JOBS=6 scripts/bringup/build-donor-control.sh
```

For byte-identical Image/vmlinux output, set `REPRO_SIGNING_KEY_PEM` to the
same non-production test PEM for every run.  Without it, the donor deliberately
generates a fresh module-signing certificate and embeds that certificate in the
kernel keyring; `System.map` remains reproducible, while Image and vmlinux do
not.  Never publish or reuse the local M1 test private key for releases.

The helper lives on the bring-up branch but builds `SOURCE_REPO`, which must be
a clean worktree at the exact donor commit.  It refuses a non-empty output
directory and any other source HEAD.  It does not package or flash anything.

Run the M2 static-port build with the extracted, known-good project 18041
overlay and the same non-production signing key used for reproducibility:

```sh
RMX1901_DTBO_ENTRY_46=/path/to/entry.dtbo.46 \
REPRO_SIGNING_KEY_PEM=/path/to/signing_key.pem \
OUT_DIR="$PWD/out-m2-static" \
JOBS=6 scripts/bringup/build-m2-static.sh
```

The M2 helper validates the exact defconfig and tools, builds Image, Image.gz,
all configured DTBs and modules, rejects warnings outside the M1 baseline,
checks gzip round-trip, verifies the project overlay's 179 fixups, checks the
reserved-memory map and leaves device flashing disabled.  It also fixes
Clang's debug compilation directory and verifies the pinned test certificate
was not replaced by a build-time random key.  These two inputs are required
for byte-identical ThinLTO, kallsyms and kernel keyring output across different
`O=` directories.

The original static checkpoint is recorded in
`bringup/manifests/M2-static-build-20260723.json`.  The current d13ec62
candidate's hashes and two-clean-build comparison are recorded separately in
`bringup/manifests/M2-current-candidate-d13ec62-20260723.json`.  These are
host-side static gates only; they are not permission to package or flash the
kernel.

Generate the dual-ABI vendor UAPI evidence in a new directory:

```sh
EVIDENCE_DIR=/path/to/new-uapi-evidence \
  scripts/bringup/build-uapi-oracles.sh
```

The UAPI gate compiles each exported header independently for arm64 and arm32
and records `sizeof`, `offsetof`, enum values, heap IDs and ioctl-related
macros.  Candidate-only additions are allowed; removal or mutation of any 4.9
value is incompatible.  The frozen baseline and passing final comparison are
recorded in `bringup/manifests/M0-uapi-oracle-20260723.json`.  Both ABIs report
zero removals and zero value/layout changes.  This closes the vendor UAPI gate
but does not authorize packaging or flashing; boot-image and DTB selection
still need independent validation.

The compatibility series restores the measured 4.9 ION, fscrypt/verity, KGSL,
DRM/SDE, audio, VIDC, camera and IPA/RMNET interfaces while retaining
candidate-only interfaces where they do not mutate a baseline value.  IPA QMI
keeps the legacy userspace layout and its required 16-bit wire encoding as
separate concerns.  All 35,664 baseline values now match on both ABIs.

The M3 boot candidates, results through r012 and the exact write policy are
recorded in `bringup/manifests/M3-boot-candidates-20260723.json`.  r010 is the
previous diagnostic mapping checkpoint.  r011 was packaged, statically
verified and device-tested.  Its fresh Recovery preflight, boot-only write,
device SHA and full 64 MiB host readback passed.  Runtime logs then proved the
exact direct DSI selection, resources, component publication, post-bind marker
and DRM bound path; `real_dsi=1` and the GPIO54 errors are gone.  The device
still entered 900e after about 59 seconds because the next boundary remains
open: every CTL reports `intf_sel=0`, validation remains `actual=0 expected=1
rc=-22`, and one `invalid vsync source selection` error remains.  The approved
candidate is cleared; Recovery, dtbo, vbmeta and userdata writes remain
forbidden and unchanged.  r012 restores the 4.9 legacy CTL interface-field
semantics while preserving the newer bitmap API, and adds a raw `CTL_TOP`
marker.  Two clean builds are byte-identical and the 64 MiB boot package passes
AVB, unpack/repack, ramdisk and six-DTB gates.  Its boot SHA-256 is
`12595057d7e662c9211a66d480cbc67f4326c5908c7f6c190792e3cff65862cd`;
the 2026-07-24 Recovery preflight, boot-only write, device SHA and complete 64
MiB host readback all passed.  Runtime KMSG then proved CTL0 raw
`0x00020020` decodes to INTF2/bitmap `0x2`, continuous-splash validation passes
with `actual=1 expected=1 rc=0`, and the valid splash mapping remains present.
The next failure is a trustworthy CPU2 SError at 4.749989 seconds, immediately
after DRM vblank initialization; the device entered 900e after 51 seconds.  The
trusted 566-line KMSG prefix has SHA-256
`7b6e85680000f390f5821c4a354a99fca9dd3e7aba6e82dbb54713b6203d8b84`;
the full Sahara evidence-list hash is
`26232b9c0718208523f6dc97d6ea465dde1bca1b0c93f1d311d277064dcd0acd`.
No candidate is approved for another write; r013 is limited to boundary
instrumentation around vblank, runtime PM, IRQ install, device registration and
mode-config reset.  Source commit `603134d8422f0242c736cefb96fcc0d5ed06f21b`
contains 37 tagged probes and no intended functional change.  Two clean Clang
11.0.1 + ThinLTO builds are byte-identical across config, Module.symvers,
vmlinux, System.map, Image, Image.gz, base/merged DTB and signing key; build ID
is `fc6fc3377b1585b9`.  The r013 64 MiB boot image preserves the exact r012
OrangeFox ramdisk and all six DTBs, passes AVB Android 17 and unpack/repack
checks, and has SHA-256
`ed1e688b4ddf2f519611f0b1d9f24d978e06e0bc8fb9b65b4e8f5c75759c6589`.
Its candidate SHA list is
`0febd25d6c51f7febc395fe075188ebc6e9ff1e888664eb3cc57fb9238e59b97`;
the reproducibility evidence list is
`71723827fd8668967e10ea86452fd029f28ef50a0e80adc3689165e3275fa963`.
A fresh full Recovery preflight passed at 2026-07-24 02:50 +08:00: root ADB,
Android 17 Recovery, 100% battery, the exact tested r012 boot installed, empty
pstore, and frozen recovery/dtbo/vbmeta/rawdump hashes.  Its evidence-list
SHA-256 is
`a81bce955178deb6d00369269c5d9ee35389dda14cb6ec089a2aa1f86b6df360`.
The preflight was read-only.  The separately approved r013 image was then
written only to `/dev/block/sde10`; the pushed file, device partition SHA and
complete 64 MiB host readback all equal
`ed1e688b4ddf2f519611f0b1d9f24d978e06e0bc8fb9b65b4e8f5c75759c6589`.
Recovery, dtbo, vbmeta and rawdump hashes remained frozen and userdata was not
touched.  The write/readback evidence-list SHA-256 is
`747368a35c4f8427ecf21a1ee3b25c7ef2a8a2b29447644e9c6c11ef2799ea04`.
The one-write approval is consumed and cleared; r013 has not yet been rebooted.

The public `A17-ResukiSU-4.14-bringup` branch uses exact-tree snapshot commits
instead of importing the unrelated 810,594-commit upstream history into the
RMX1901 repository.  r013 source snapshot
`8c3f63e461ba5f1307978e46096b88e798567db7` has tree
`16a8a939ada3d953661d3fd0db95f8f2ce4cbd62`, byte-for-byte identical to the
local r013 runtime source commit `603134d8422f0242c736cefb96fcc0d5ed06f21b`.

After a failed boot has returned to Recovery, capture the immutable failure
state before any rollback with `scripts/bringup/capture-m3-recovery-evidence.sh`.
It verifies the candidate boot hash, saves pstore, bootreason, Recovery logs and
a full boot readback, and reads the full rawdump only when its hash changed.
