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
| M3 device boot | R010 TESTED / R011 BUILD PENDING | r010 confirmed the failed continuous-splash cleanup source and removed the old translation-fault chain, but still panicked. r011 legacy direct-DSI and GPIO10-only TE changes passed review; no r011 boot candidate exists yet. |

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

The M3 boot candidates, results through r010 and the exact write policy are
recorded in `bringup/manifests/M3-boot-candidates-20260723.json`.  r010 is the
currently installed failed candidate.  r011 is still source-only: it must be
committed, rebuilt from a clean tree, packaged and added to the manifest before
it can be considered for a boot-only controlled test.  Recovery, dtbo, vbmeta
and userdata writes remain forbidden.

After a failed boot has returned to Recovery, capture the immutable failure
state before any rollback with `scripts/bringup/capture-m3-recovery-evidence.sh`.
It verifies the candidate boot hash, saves pstore, bootreason, Recovery logs and
a full boot readback, and reads the full rawdump only when its hash changed.
