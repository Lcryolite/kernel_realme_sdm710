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
| M3 device boot | R015 BOOT FAIL / AUTOMATIC RECOVERY PASS; R016 STATIC PASS | r014 proved that IRQ-bank indices 0–9 complete and execution stops at index 10, `MDSS_INTF_TEAR_1_INTR` clear offset `0x6e808`; it then entered 900e and did not return to Recovery. r015 removes the SDE 5.x interface-TE banks from the SDM670 SDE 4.1 catalog and bypasses the forced watchdog bite when panic automatic-Recovery is enabled. It did not boot, but avoided the prior 51-second 900e and returned unattended to stable OrangeFox after approximately 146 seconds. r016 preserves that baseline and adds a bounded 90-second diagnostic panic deadline; its two clean builds and A17 boot package pass static gates but have not yet been written or run. |

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

The M3 boot candidates, results through r015 and the exact write policy are
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
The one-write approval is consumed and cleared.  r013 was rebooted at
2026-07-24 03:05:27 +08:00 and Qualcomm 900e was first observed 54 seconds
later.  Sahara captured a 573-line trustworthy KMSG prefix (SHA-256
`ac0325636a9e03fd0e545f81b7fa75c008a01fa2d1b4ff685210c8ea0d281a55`);
the raw log becomes corrupt at line 574 and therefore supplies no trustworthy
SError or panic text.  The trusted sequence proves `drm_vblank_init()` and
`pm_runtime_get_sync()` return zero, enters DRM IRQ install with IRQ 18, enters
MSM/SDE preinstall, and returns zero from SDE core IRQ power enable.  Its last
complete marker is immediately before `sde_clear_all_irqs()` at 4.815979
seconds.  No after-clear marker, disable-all access, `request_irq`, IRQ
postinstall, first handler, DRM device registration or mode reset is reached.
The failure is therefore bounded to the clear-all register loop or an
asynchronous hardware error delivered during that loop.  The Sahara evidence
list SHA-256 is
`4de4ead815d7e5edfd9f43f33172ce62fa1ef336245bb04a18e4c0ad286c0aa8`.
The next single-variable probe is r014: log each IRQ bank index, table ID and
clear offset immediately before and after its unchanged `0xffffffff` write,
then log both sides of the existing `wmb()`.

r014 source commit `6c36cb5da81d61fc061e8e74604541685da89d32`
adds those four per-bank/barrier marker classes.  It also restores the
RMX1901 known-good 4.9 panic restart policy that the 4.14 donor lacked: after
panic notifiers and `kmsg_dump`, panic download mode is disabled, PMIC and
IMEM Recovery reasons are written and a warm reset is requested.  Normal
restart commands are unchanged, and `rmx1901.panic_recovery=0` disables the
bring-up safety path when a Sahara capture is explicitly required.  Two fresh
Clang 11.0.1 + ThinLTO builds are byte-identical; build ID is
`e8591983d70e62c4` and their evidence-list SHA-256 is
`8dbdc4c25d78cab948ceca018e0a786440b6815fc807ab833e5975746e725d41`.
The complete 64 MiB A17 boot image preserves the exact r013 OrangeFox ramdisk
and all six DTBs, passes AVB and unpack/repack verification, and has SHA-256
`183bc4cd74ea223889116081636d62b16ed935788021539fb947fb6bf11818b3`.
At packaging time it was a static candidate only; the later preflight and
explicitly bound write are recorded below.
The fresh 2026-07-24 03:52:58 +08:00 Recovery preflight passed with root ADB,
Android 17, 100% battery, exact r013 boot installed, frozen
recovery/dtbo/vbmeta/rawdump hashes and empty pstore.  Candidate SHA and AVB
checks passed; its evidence-list SHA-256 is
`77fcb72fb2eec9dce93a982e6276c757877deba3832a21c79dda4cceb0629651`.
The preflight performed no device write and does not itself grant approval.
The user's 2026-07-24 request to continue and make the cycle unattended binds
one write authorization to candidate `B14-M03-r014-irq-bank-autorecovery`, boot
SHA-256 `183bc4cd74ea223889116081636d62b16ed935788021539fb947fb6bf11818b3`
and `/dev/block/sde10` only.  The authorization is consumed after the write;
device SHA and a complete 64 MiB host readback must both match before reboot.
The write was completed at 2026-07-24 05:28 +08:00 to `/dev/block/sde10`
only.  Pushed-file SHA, device boot SHA and complete 64 MiB host readback are
all `183bc4cd74ea223889116081636d62b16ed935788021539fb947fb6bf11818b3`,
and byte comparison passed.  Recovery, dtbo, vbmeta and rawdump remain at
their frozen hashes; userdata was untouched.  The write evidence-list SHA-256
is `d4d99d35fada8f48ff1b00bb62e12f0e664b034e9e95ef2c4b28ce46c55f5c34`.
The one-write approval is consumed and cleared.  r014 was rebooted at
2026-07-24 05:32:10 +08:00 and Qualcomm 900e was first observed about 51
seconds later; automatic Recovery did not enumerate.  The trustworthy KMSG is
594 lines (SHA-256
`8750a8ddfc079dbce290704f13208df1072e1cc6bc93bbe020e1ea8c983bbcb9`).
IRQ-bank indices 0–9 each have matching before/after writes.  The final trusted
line is the before-write marker for index 10, table ID
`MDSS_INTF_TEAR_1_INTR`, clear offset `0x0006e808`; there is no index-10
after-write, index-11 marker, `wmb()` marker or r013 after-clear marker.  The
runtime-observation evidence-list SHA-256 is
`4a594449837126af87cd812749ba5a1eab32d3579f467739b54e4f34ad4cf7df`;
the Sahara evidence-list SHA-256 is
`41b2994fb43c0367f9bcb00a0c87901c83fbe12ed773001167c4a2d7c3e2f1d8`.

r015 is the evidence-driven correction.  SDM670 is SDE 4.1 and uses the
ping-pong TE path; separate interface-TE IRQ banks start at SDE 5.0.  Commit
`19dda7fa5a4db0d0496e190084474523937ab3a7` clears only
`MDSS_INTF_TEAR_1_INTR` and `MDSS_INTF_TEAR_2_INTR` from the SDM670 capability
bitmap, restoring the ten-bank topology also present in the known-good 4.9
tree.  Commit `b370467eb4173f2ece4faa4a4bbd2692735917b0` additionally prevents
the forced panic watchdog bite while `rmx1901.panic_recovery` is enabled, so
the existing PMIC/IMEM Recovery reasons proceed through the PS_HOLD reset path.
The escape hatch `rmx1901.panic_recovery=0` preserves the old watchdog/900e
capture behavior.  This improves unattended Linux-panic recovery but cannot
guarantee Recovery when firmware takes a fatal path that bypasses Linux.

Two independent clean Clang 11.0.1 + ThinLTO r015 builds on the Btrfs `/home`
filesystem are byte-identical across config, Module.symvers, vmlinux,
System.map, Image, Image.gz and base/merged DTB.  Build ID is
`bb1c817e86a576c4`; Image.gz SHA-256 is
`277fcc155120f1cd7be9811eb272b0e50fe048dddec454b963aa9d838a7cb933`;
the reproducibility evidence-list SHA-256 is
`8239e64ac26d70c87a296749ff742fabf79481e2b2c6f045bbb2123da47f18f0`.
The complete 64 MiB A17 boot image keeps the exact r014 OrangeFox ramdisk and
six DTBs, passes AVB, unpack/repack and gzip round-trip gates, and has SHA-256
`683ac664dd971541540ac60db967fd6f40dfcddddb289a9e5d7ab5493de6e19e`.
Its candidate SHA-list hash is
`d4bdb4ea378a16274392f9e34421d949af90c0c6e043530d570223b12a917666`.
The 2026-07-24 06:42:50 +08:00 root-ADB Recovery preflight passed with Android
17, 100% battery, exact r014 boot installed, empty pstore, and frozen
recovery/dtbo/vbmeta/rawdump hashes.  Candidate SHA and AVB checks passed; the
preflight evidence-list SHA-256 is
`ce9298d45c4d6da8260535a74a94981496fef6fe0a3404784a5132a4545940b5`.
The first write attempt safely stopped before push or partition access because
the approval flag had been attached to the r011 manifest entry; the manifest
was corrected and republished with r011 false and r015 true.  At 06:47 the
exact r015 image was then written only to `/dev/block/sde10`.  Pushed-file SHA,
device partition SHA and the complete 64 MiB host readback all equal
`683ac664dd971541540ac60db967fd6f40dfcddddb289a9e5d7ab5493de6e19e`,
and byte comparison passed.  Recovery, dtbo, vbmeta and rawdump remain frozen;
userdata was untouched.  The write evidence-list SHA-256 is
`3d48ac8670b1ca788749ca4d0abee0ef838e7aa6882f6806116a989167c8a3d8`.
The one-write authorization is consumed and cleared.  r015 was rebooted at
2026-07-24 06:52:47 +08:00.  The initial 120-second monitor saw no ADB,
Fastboot or Qualcomm 900e, but stable OrangeFox Recovery subsequently appeared
without a human or host recovery command.  Recovery uptime places its kernel
start at approximately 06:55:13, about 146 seconds after the test reboot; the
first host observation was at 06:55:48.  The boot partition still matched
`683ac664…e19e`, rawdump was unchanged, pstore was empty and the power reasons
reported a hard/cold start after PS_HOLD.  The runtime observation-list
SHA-256 is
`591684515ea63dcfb39ff1d927ad74ea82c2e389da0cd679f6295da84bb0d821`;
the automatic-Recovery capture-list SHA-256 is
`d915201d3bfa7ccc39148db2ae22006c7c756abf13c393a9cd74d056c685e3ef`.
This is an operational unattended-Recovery pass and an observable improvement
over r014, but it is still a boot failure.  Empty pstore and unchanged rawdump
mean the evidence cannot attribute the Recovery selection specifically to the
Linux panic PS_HOLD branch, nor prove that the clear-all loop completed.  No
further partition write is approved until a durable pre-reset progress record
can be collected without losing this recovery behavior.

r016 implements that bounded diagnostic record attempt without changing the
DT, ramdisk, kernel config or r015 display fix.  Commit
`dbaf10527d515546628afb5adfbda2c2dc19467e` schedules a delayed-work boot
guard from the Qualcomm restart driver.  Its default deadline is 90 seconds;
if stable root ADB appears first it can be disarmed through
`/sys/module/msm_poweroff/parameters/bringup_boot_guard_disarmed`.  Otherwise
it explicitly panics so the console is passed to kmsg_dump before the r015
Recovery reason and PS_HOLD path.  `rmx1901.boot_guard_seconds=0` disables the
diagnostic guard, values above 600 seconds are rejected, and kdump kernels do
not arm it.  If the scheduler or workqueue itself stalls, the already-observed
approximately 146-second non-Linux fallback remains the final recovery layer.

Two independent clean Clang 11.0.1 + ThinLTO r016 builds are byte-identical
across config, Module.symvers, vmlinux, System.map, Image, Image.gz and
base/merged DTB.  Build ID is `db79ea494c148b5f`; Image.gz SHA-256 is
`b1787bedb1a18d4b280273713e62219f403329e5cd8e8be497a2a34cf93843cf`;
the reproducibility evidence-list SHA-256 is
`923aa690d4fe7e88315ae4742b3f1a0de1ad73cbcf3622a0747ef009b40d2026`.
The complete 64 MiB A17 boot image keeps the exact r015 OrangeFox ramdisk and
six DTBs, passes AVB, unpack/repack, gzip and DTB gates, and has SHA-256
`9c4e3063919f9675358977b32a525f1f3b75fcd6424971f2e95d6671dfd8f57e`.
Its candidate SHA-list hash is
`b10da03ad5bb057bd11d14d7a00c2acd9038bf8c992a8ca6e1a79b4bcd917959`.
r016 is static-pass/not-tested; no partition write is currently approved.

The public `A17-ResukiSU-4.14-bringup` branch uses exact-tree snapshot commits
instead of importing the unrelated 810,594-commit upstream history into the
RMX1901 repository.  Publication state and the exact public snapshot commit
are recorded in the M3 manifest after each evidence checkpoint.

After a failed boot has returned to Recovery, capture the immutable failure
state before any rollback with `scripts/bringup/capture-m3-recovery-evidence.sh`.
It verifies the candidate boot hash, saves pstore, bootreason, Recovery logs and
a full boot readback, and reads the full rawdump only when its hash changed.
