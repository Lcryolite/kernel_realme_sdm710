# Backport validation record

The scoped implementation and isolated validation are complete. The final
matrix passed 38/38 cases and the full RMX1901 build produced Image.gz.
Hardware ICE runtime and actual-phone userspace compatibility remain
`unverified`. Stage results below are retained separately from final evidence.

## Inputs and boundary

- Repository: `Lcryolite/kernel_realme_sdm710`, branch `stock-next`.
- Base revision: `4f25c4009ed2d63281d3e2ec30de542812fd5837`.
- Source: the base plus the local backport changes. No remote Git write or
  real-device boot/flash has been performed.
- Device configuration: `RMX1901_defconfig`; isolated configuration:
  [qemu.config](qemu.config). See [README.md](README.md) for exact commands,
  toolchain inputs, and configuration differences.
- Runtime tests execute the modified ARM64 kernel under QEMU TCG, with static
  ARM64 BusyBox and disposable virtio block images. Host F2FS is not used to
  establish kernel behavior.
- Local logs live in `/home/lknife/Projects/kernel_rmx1901/build/`.

## Reported release (#15)

The executable regression first failed with
`reported release '6.18.0-rmxdiag176', expected '4.9.337-rmx1901-test+'`
in `release-red-executed.log`. After replacing the substitution with
`UTS_RELEASE`, `release-green.log` recorded:

```text
KERNEL_BACKPORT_PASS: release=4.9.337-rmx1901-test+ disposable-disk=present
```

The full device build passed in `device-release-green-build.log`, producing
`4.9.337-LineageOS+` and retaining `Image.gz`. Its Image.gz SHA256 was
`39efeba8e7713e7824aa7ebfd6072e7842d6dd50b1e011a3e1233ae75e9ddd89`;
effective configuration SHA256 was
`753cafa002aa1df9b415798170aa9bed9c654cb8a146d4138a9b362ae3c01108`.
`AnyKernel3/tests/test-dtb-guard.sh` passed.

The isolated boot needed the existing RMX1901 physical ramoops writes and
schedx object to be limited to `CONFIG_PRODUCT_REALME_SDM710`. The device
configuration still enables this symbol. The guest retains an existing
`fsync_enabled: Invalid permissions 0755` sysfs warning, also observed before
the release/compression changes. Actual-phone userspace compatibility is
`unverified`.

## Zstd startup unpacking (#16)

The adapter originates from Linux v5.10
[`lib/decompress_unzstd.c`](https://github.com/torvalds/linux/blob/v5.10/lib/decompress_unzstd.c),
blob `790abc472f5bea5ba3186aa199b7ac55ace5edce`. It uses this tree's existing
Zstd library API. Compatibility changes use `ULONG_MAX`/`unsigned long` and
treat an empty refill as truncated input, avoiding an EOF retry loop. The
window-size comment was corrected to 128 MiB.

| Test | Result | Log |
| --- | --- | --- |
| Valid Zstd initramfs before adapter | Expected failure: junk in compressed archive | `zstd-red.log` |
| Valid Zstd initramfs after adapter | Passed; extracted init executed | `zstd-green.log` |
| Existing gzip initramfs | Passed | `gzip-regression.log` |
| Reserved frame-header bit set | Controlled rejection | `zstd-bad-header.log` |
| Input truncated halfway | Controlled rejection | `zstd-truncated.log` |

Negative cases require an explicit Zstd unpacking error, no test userspace
success marker, and no observed BUG/Oops/KASAN-style memory-fault diagnostic.
A QEMU timeout is a failure, not an accepted rejection. These runs do not
constitute exhaustive malformed-input fuzzing or a memory-safety proof.

The combined device build in `device-zstd-f2fs-read-build.log` passed with
`CONFIG_RD_ZSTD=y`, `CONFIG_DECOMPRESS_ZSTD=y`, and
`CONFIG_ZSTD_DECOMPRESS=y`. Its Image.gz SHA256 was
`8e686d682517aa04fbfe67b6a679ef51475e2493ece9e02104195411d7f3e34f`;
effective configuration SHA256 was
`d119f3f5cb17718ba16b12da4b8bf50acd56efc587d73e8948b158d93fabe9a5`.

## F2FS reader progress (#17)

The fixture was produced independently by f2fs-tools 1.17.0 with
`extra_attr,compression`, LZ4, and log cluster size 2. Its 98,335-byte payload
spans full compressed clusters and an ordinary partial tail. Expected SHA256:
`48da549ce3adda601fa5adf27ce4d53e0432a1a29f02780db28d90709760ee50`.
The tool's consistency check passed after fixture creation.

| Test | Result | Log |
| --- | --- | --- |
| Original reader | Expected failure: extra attribute size 36 exceeds 24 | `f2fs-lz4-read-red-serial.log` |
| Backported reader, including unmount/mount | Payload hash passed twice | `f2fs-lz4-read-green.log` |
| Compressed length zero | Read rejected across unmount/mount | `f2fs-bad-clen-zero.log` |
| Compressed length `0xffffffff` | Read rejected across unmount/mount | `f2fs-bad-clen-large.log` |
| Initial writer guard | Writes rejected after mount/remount attempts | `f2fs-read-guards-confirmed.log` |
| Explicit new compressed-file write | Expected failure at read-only guard | `f2fs-write-red.log` |

Corruption tests modify a private image copy at the first compressed storage
block (6656 for this inspected fixture). They never alter the source fixture.
BusyBox may retry a failed writable mount as read-only; the guard test checks
actual write rejection instead of interpreting mount's exit status alone.

The read-stage QEMU Image SHA256 was
`8a535350f7dc12ea288820e25a203f7f1a56d4759367ff10f902926ef0d6456d`;
configuration SHA256 was
`cb21352ca42e6e5995f320d29424290b7cf9f23a496e4d4c02449c001362dde1`.

## LZ4 selected writes (#18)

`f2fs-write-reserve.log` passed creation of explicitly selected compressed
files, directory inheritance, an unselected ordinary peer, byte comparison,
and full unmount/mount. `f2fs-write-reserve-inode5.log` independently reports
algorithm 1, log cluster size 2, six compressed clusters, `i_blocks=26`, and
`i_compr_blocks=18`. Native liblz4 decoded all six storage blocks
6663 through 6668 to the corresponding 16,384-byte input slices; the ordinary
31-byte tail also matched. This checks the stored format independently of
the backported reader.

The inspected `f2fs-write-reserve.img` SHA256 is
`c91215ea3f4dd701cccf52acc3402e9247460500475377cfaed56b2ae75622a5`.
The device build in `device-f2fs-write-reserve-fix.log` passed with release
`4.9.337-LineageOS+`; its Image.gz SHA256 was
`e136fd4430ed8148f2739f5b9beebbbeb9795da86d5d93aebfc5f69e305642c2`.

Compressed files retain logical block reservations. This backport does not
implement `F2FS_IOC_RELEASE_COMPRESS_BLOCKS` or
`F2FS_IOC_RESERVE_COMPRESS_BLOCKS`; `df` and quota accounting are not promised
to expose the physical compression savings immediately. Existing files are
not automatically converted. Synchronous cluster-read performance has not
been measured.

## Lifecycle, relocation, and recovery (#19)

The guest compares each operation against an independent expected file in
the RAM filesystem. Coverage includes partial overwrite across a cluster
boundary, append, truncate, zero extension, rename, hard link, unlink, and
full unmount/mount. It also checks small files, incompressible selected files,
unselected peers, and a 9,440,160-byte selected file spanning the inode/direct
node boundary. The reuse loop rotates three files for exactly 72 iterations
of 4 MiB writes: 288 MiB of logical writes on a 256 MiB disposable image.
This write volume alone is not evidence that compressed data moved during GC.

| Test | Observed result | Log |
| --- | --- | --- |
| Mutation and space reuse | All comparisons and surviving files passed | `f2fs-lifecycle-green-2.log` |
| Explicit closed-segment GC followed by reuse | GC data counter increased by 2,068,480 bytes; lifecycle passed | `f2fs-lifecycle-gc.log` |
| `data_flush` variant | GC and lifecycle passed | `f2fs-data-flush.log` |
| Dirty checkpoint before recovery support | Expected mount rejection requiring recovery | `f2fs-checkpoint-read-red.log` |
| Synced checkpoint recovery | Persisted bytes passed after a new boot | `f2fs-checkpoint-read-green.log` |
| Open, unlinked compressed inode at poweroff | Held descriptor recorded; recovery and persisted bytes passed | `f2fs-orphan-write.log`, `f2fs-orphan-read.log` |

For the explicit GC test, the fixture's first cold segment begins at block
6656 and contains 512 blocks. The ioctl helper reports completion separately
from proof of movement. The guest's F2FS `fs gc data` counter increased by
2,068,480 bytes. Native inode inspection then found the six original
compressed storage blocks moved from 6656..6661 to 7680..7685 in
`f2fs-lifecycle-gc-inode4.log`. Native liblz4 independently decoded all six
relocated clusters and the ordinary tail matched the source. Together with
the remount comparisons, these observations establish compressed data
relocation for this fixture; a successful ioctl alone would not establish it.

The inspected `f2fs-lifecycle-gc.img` SHA256 is
`a0181e9949c331552737377e2b40c3c22a6fab23b43892a6360612d1623e2b30`.
The device build in `device-f2fs-recovery-build.log` passed; its Image.gz
SHA256 was
`e655e4bc642e0a1aa2dd1b6326a6032f1d20ce02c36048086afdd95f3366b8fc`.

Checkpoint and orphan tests sync the file data, leave the filesystem mounted,
and power off the isolated guest before a new boot. They cover that recovery
sequence, not arbitrary write interruption, exhaustive fault injection, or
durability of unsynced writes. `f2fs-orphan-read-fsck.log` reports zero
unreachable NAT entries after recovery.

### Offline consistency checks

The original checker commands used f2fs-tools 1.17.0
`fsck.f2fs --dry-run -f IMAGE`. In that version, `Info: Force to fix corruption`
is printed while parsing `-f`/`-y`, before any corruption is found
([upstream main.c](https://kernel.googlesource.com/pub/scm/linux/kernel/git/jaegeuk/f2fs-tools/+/1.17.0/fsck/main.c)).
`[FSCK] fixing SIT types` is also an unconditional heading; a disallowed
segment-type mismatch produces a separate `Wrong segment type` diagnostic
([upstream fsck.c](https://kernel.googlesource.com/pub/scm/linux/kernel/git/jaegeuk/f2fs-tools/+/1.17.0/fsck/fsck.c)).
Dry-run returns before device writes, although checks can still adjust
in-memory state
([upstream libf2fs_io.c](https://kernel.googlesource.com/pub/scm/linux/kernel/git/jaegeuk/f2fs-tools/+/1.17.0/lib/libf2fs_io.c)).
Neither heading alone is a corruption finding or evidence of a disk repair.

To check independently of forced-fix mode, each image below was copied
privately and checked again using `fsck.f2fs --dry-run` without `-f`. All four
runs exited 0, all integrity-result rows reported `[Ok..]`, and no `Fix:`,
`[Fail]`, assertion, or segment-type mismatch was reported. Source and private
copy SHA256 values were identical before and after each check. Commands,
hashes, and exit codes are recorded in `fsck-independent-dry-run-audit.json`.
The temporary copies were discarded; original images were not repaired.

| Image | Original checker log | Independent no-`-f` log |
| --- | --- | --- |
| `f2fs-write-reserve.img` | `f2fs-write-reserve-fsck.log` | `f2fs-write-reserve-fsck-independent-dry-run.log` |
| `f2fs-lifecycle-green-2.img` | `f2fs-lifecycle-green-2-fsck.log` | `f2fs-lifecycle-green-2-fsck-independent-dry-run.log` |
| `f2fs-lifecycle-gc.img` | `f2fs-lifecycle-gc-fsck.log` | `f2fs-lifecycle-gc-fsck-independent-dry-run.log` |
| `f2fs-orphan-read.img` | `f2fs-orphan-read-fsck.log` | `f2fs-orphan-read-fsck-independent-dry-run.log` |

## Zstd filesystem stage (#20)

[make-zstd-fixture.py](make-zstd-fixture.py) first decodes and checks the native
LZ4 fixture, then transforms its six clusters using host libzstd 1.5.7 at
level 1 and changes the compression algorithm with native `inject.f2fs`.
This is an upstream-format fixture with an independent Zstd encoder, not a
volume encoded natively by `sload.f2fs`. Its source layout, addresses, counts,
ordinary tail, codec versions, and tool commands are recorded in
`f2fs-zstd-independent.img.json`. The image SHA256 is
`dbc91c38259782bd2281604d1c675990419b9bccd7575e10edba9887f0d6b770`.

| Test | Observed result | Log |
| --- | --- | --- |
| Independent Zstd fixture | Payload comparison and unmount/mount passed | `f2fs-zstd-independent-green.log` |
| Selected writes and inheritance | Selected bytes, unselected peer, and remount passed | `f2fs-zstd-write-green.log` |
| Lifecycle and explicit GC | All comparisons passed; GC data increased by 2,068,480 bytes | `f2fs-zstd-lifecycle.log` |
| Orphan/checkpoint sequence | Synced mounted writer and next-boot recovery passed | `f2fs-zstd-orphan-write.log`, `f2fs-zstd-orphan-read.log` |

The independent-read log retains the generic reader's legacy
`fixture=lz4` marker; the supplied image's inspected algorithm is 2 (Zstd).
Native libzstd 1.5.7 separately decoded the six kernel-written clusters from
`f2fs-zstd-write-green.img`, using addresses from
`f2fs-zstd-write-green-inode5.log`. Every 16,384-byte slice matched the source;
reserved header bytes and storage padding were zero. The corresponding
`f2fs-zstd-{write-green,lifecycle,orphan-read}-fsck.log` files report all
integrity checks `[Ok..]` without fix diagnostics under `--dry-run -f`.

An intermediate incremental build encountered duplicate Zstd symbols from a
stale decoder-only thin archive. Removing that generated archive allowed the
rebuild to proceed; this was an output-directory artifact, not a source
Makefile error. Final acceptance uses fresh output directories.

## Static helpers and software fscrypt (#21)

The first NDK r30 static Bionic helper aborted before its CLI on this 4.9
kernel with `arc4random data MADV_WIPEONFORK failed` in
`f2fs-encrypted-red.log`. Targeting Android API 21 did not make that current
static libc compatible. The replacement uses verified Alpine v3.22 AArch64
`musl-dev` 1.2.5-r13 and `linux-headers` 6.14.2-r0, explicit musl startup
objects and libc, and only the required freestanding compiler builtins from
the available NDK archive. No Bionic startup or libc is linked.

Package signatures, index/package hashes, compiler revision, build command,
and output hash are recorded in
`/home/lknife/Projects/kernel_rmx1901/tools/musl-aarch64/provenance.json`.
[build-userspace.sh](build-userspace.sh) documents the reproducible static
build route. The musl helper executed session-keyring creation, test-key
addition, and policy setup on the actual changed 4.9 guest; the original
compression/encryption guard then produced the expected feature failure in
`f2fs-encrypted-red-musl.log`. That run established helper compatibility,
separately from the later encrypted-compression implementation.

| Codec | Persisted encrypted mutation and key tests | Artifact |
| --- | --- | --- |
| LZ4 | Passed | `f2fs-lz4-encrypted-persisted.log`, `f2fs-lz4-encrypted-persisted.img` |
| Zstd | Passed | `f2fs-zstd-encrypted-persisted.log`, `f2fs-zstd-encrypted-persisted.img` |

Both runs identify software `xts(aes-generic)` and
`cts(cbc(aes-generic))` implementations. The v1 policy uses AES-256-XTS for
contents and AES-256-CTS for filenames. Tests sync and fully unmount before
mutating persisted compressed ciphertext, then check partial overwrite,
append, truncate, encrypted-directory inheritance, ordinary encrypted
peers, and unencrypted files. Full unmounts between key changes discard
inode-cached keys. Removing the key denies read and creation; a wrong key
does not recover expected plaintext; restoring the test key restores all
expected content. V1 fscrypt does not authenticate key material, so the
wrong-key test does not claim that every attempted read must return an error.

## Hardware integration (#22)

The vendor ICE path retains the inode mapping and compressed storage slot
index on temporary pages. `f2fs_submit_page_write()` derives the DUN from
that compressed page and retains the existing mergeability, key selection,
encryption-skip, and request handling. Software encryption uses a bounce
page after compression; ICE uses the compressed storage page directly.
Reads use the existing decryption completion before decompression. GC's
metadata-page path relocates stored bytes without changing their logical
encryption identity. Direct I/O on compressed files always falls back to
buffered I/O, including hardware-encrypted files.

Relevant implementation paths are `fs/f2fs/{compress.c,data.c,f2fs.h,gc.c}`,
`include/linux/fscrypt.h:PG_DUN`, `fs/crypto/fscrypt_ice.c`, and the existing
`security/pfe/{pfk.c,pfk_f2fs.c}`. The device configuration builds
`PFK`, `CRYPTO_DEV_QCOM_ICE`, `SCSI_UFS_QCOM_ICE`, and
`MMC_SDHCI_MSM_ICE` in. The final linked vmlinux contains the compression,
codec, startup decoder, and `pfk_load_key_start` symbols. This establishes
compilation and source-path integration, not ICE hardware behavior.

## Review regression and final matrix (#23)

Independent Spec review found that F2FS I/O tracing stores a PID in
`page_private`, which the initial compressed-page classifier interpreted
as a pointer. Enabling `F2FS_IO_TRACE` reproduced an Oops at address `0x3f`
in `f2fs-io-trace-red.log`; this was a real kernel failure, not an accepted
negative test. The original test Image is retained as
`qemu-io-trace-red.Image`. The classifier now requires `PagePrivate2`, set
only on owned compressed temporary pages and cleared on all release paths,
before interpreting the private pointer. The same write/ordinary-peer/
inheritance/remount case passed in `f2fs-io-trace-green.log`.

Spec review also identified that invalid outer lengths did not exercise
the filesystem codec's rejection path. The final suite additionally sets a
valid compressed frame's length to its original length minus one for both
codecs, and damages Zstd frame magic without changing its valid length.
Each case requires read failure on two separate mounts. These tests are
separate from the startup archive rejection cases.

The final QEMU configuration retains `F2FS_IO_TRACE=y`, `F2FS_CHECK_FS=y`,
and the tracing dependencies. All final cases use the post-fix kernel at
`build/qemu-trace/arch/arm64/boot/Image`. The complete suite exited 0 and
reported `SUITE_PASS` in `build/final-trace-suite/suite.log`:

| Acceptance area | Final result | Evidence under `build/final-trace-suite/` |
| --- | --- | --- |
| Actual generated release | Passed in every successful guest | `kernel.release`, serial pass markers |
| Zstd initramfs, gzip regression, bad/truncated startup input | Passed | `gzip.log`, `zstd-initramfs.log`, `zstd-bad-header.log`, `zstd-truncated.log` |
| Independent LZ4/Zstd format reads | Passed | `lz4-read.log`, `zstd-read.log`, `independent-zstd.img.json` |
| Explicit selection, directory inheritance, ordinary peer | Passed for both codecs | `*-write.log` |
| Overwrite, append, truncate, small/incompressible data, links, delete/reuse | Passed for both codecs | `*-lifecycle.log` |
| GC, checkpoint data flushing | Passed for both codecs | `*-lifecycle.log`, `*-data-flush.log` |
| Dirty checkpoint and orphan recovery over two boots | Passed for both codecs | `*-checkpoint-{write,read}.log`, `*-orphan-{write,read}.log` |
| Software fscrypt, persisted mutations, inherited policy, key lifecycle, ordinary encrypted files | Passed for both codecs | `*-encrypted.log` |
| Encrypted compressed storage relocation | Passed for both codecs | `*-encrypted-gc.log`, `*-encrypted-{before,after}.dump`, `*-encrypted-gc-movement.json` |
| Corrupt lengths and actual codec frame errors | Controlled rejection | `*-length-*.log`, `*-frame-truncated.log`, `zstd-frame-bad-magic.log` |
| Invalid inode metadata and misplaced markers | Controlled rejection | `extra-size.log`, `algorithm.log`, `small-cluster.log`, `large-cluster.log`, `compress-flags.log`, `misplaced-marker.log`, `plain-marker.log` |
| Offline image consistency | All 14 outputs passed; no actual fix/failure diagnostics | `*-fsck.log` |
| ICE hardware execution and phone userspace | `unverified` | No suitable hardware runtime test within the authorized boundary |

The encrypted GC test closes the selected data segment using a separate
encrypted filler file, forces targeted GC, then fully unmounts and rereads
the selected file and controls. Native before/after dumps prove that two
selected compressed storage slots moved outside the target segment for each
codec. Every selected compressed slot's stored bytes remain identical across
the operation, including slots outside that segment. The movement JSON
records the physical addresses and ciphertext SHA256 values. Counters alone
are not used to claim selected-file relocation.

The final suite contains 38 guest boots/cases. Its `commands.sh` records
case-specific invocations, `inputs.sha256` pins input artifacts, and
`images.sha256` pins retained positive and intentionally corrupt images.
The suite did not report BUG/Oops/KASAN-style faults. No exhaustive fuzzing,
low-memory, throughput, concurrent-workload, or arbitrary power-cut claim
is made. The known baseline sysfs permissions warning remains; the trace
configuration also emits the kernel's normal trace_printk/debug warning.

Independent Standards review found no blocking violation and retained one
nonblocking suggestion about the size of the codec/read/writeback functions.
Independent Spec review closed both findings after source and runtime
rechecks. Shell syntax checks, `git diff --check`, and
`AnyKernel3/tests/test-dtb-guard.sh` passed. Validation covers the combined
final source; intermediate commit trees were not separately rebuilt.

## Final build artifacts

The full device build started in a fresh `build/device-final` directory
(`device-final-build.log`), then rebuilt all requested targets after the
review fix (`device-io-trace-fix-build.log`). The isolated tracing build
started in fresh `build/qemu-trace`, with the review fix rebuilt in
`qemu-trace-green-build.log`. A source-side generated-header directory was
preserved outside the source tree before that fresh build; generated header
shadowing otherwise caused the initial trace build to fail before compilation.

Both use the compiler/cross prefixes documented in README, an empty
environment, `LC_ALL=C`, `TZ=UTC`, `TMPDIR=/tmp`, and these explicit build
identity values:

```text
KBUILD_BUILD_USER=builder
KBUILD_BUILD_HOST=isolated
KBUILD_BUILD_TIMESTAMP=Tue Oct 27 00:00:00 UTC 2026
KBUILD_BUILD_VERSION=1
```

For exact reproduction, use the README commands with those identity values,
device output `build/device-final`, isolated output `build/qemu-trace`, and
suite output `build/final-trace-suite` (choose a new suite directory on rerun).
Final rebuilds used `JOBS=4`; the initial tracing build used `JOBS=6`.
The device script used `REQUIRE_CLANG_MAJOR=24`,
`CLANG_TRIPLE_ARM32=arm-linux-gnueabi-`, and its default disabled ThinLTO,
Polly, extra optimization, and tuning switches. Byte-for-byte rebuild
reproducibility has not been independently demonstrated.

| Artifact relative to workspace | SHA256 |
| --- | --- |
| `build/device-final/arch/arm64/boot/Image.gz` | `7aeb57e0ae032a15b2b2bc5fd102546a4b57aee05381974d3980c9b76e0aea71` |
| `build/device-final/vmlinux` | `70438b01460ee0ee9bb7a39797cc31b1fd199c6559071c5800676ae6af3ba2f1` |
| `build/device-final/.config` | `d80dbd46bebfbb6ed58a59b3cee88e79fb9da45575aac5faf176ec4f9c03a8ae` |
| `build/qemu-trace/arch/arm64/boot/Image` | `91ec04fa16fcc833b03732ff825377e10e9ad5615c6d17b906a423537166897c` |
| `build/qemu-trace/.config` | `272d4e953a8e0cc3b1dd42bcce4d0526bfd8ed3911461acf1f6af8d9dcf39e51` |

Device release is `4.9.337-LineageOS+`; isolated release is
`4.9.337-rmx1901-test+`. The required RD_ZSTD, DECOMPRESS_ZSTD,
ZSTD_COMPRESS/DECOMPRESS, F2FS_FS_COMPRESSION, F2FS_FS_LZ4/ZSTD, and
LZ4_COMPRESS/DECOMPRESS values are all `y` in the effective device config.
The complete source delta is recorded as `build/kernel-backport-final.patch`
against the base revision above, with local commits listed in
`build/kernel-backport-commits.txt`. The BakaSU submodule stays at
`d5e9e025b8b49155f8014684d64c91742b465f65`.

No device was flashed or booted, no existing partition was modified, and
no remote Git push was performed. Hardware runtime and userspace dependent
on the old release bypass remain the explicit remaining validation gaps.
