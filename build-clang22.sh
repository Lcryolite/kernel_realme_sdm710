#!/usr/bin/env bash

set -euo pipefail

kernel_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
android_root="$(cd "${kernel_root}/../.." && pwd)"
build_output="${OUT_DIR:-${android_root}/RMX1901/artifacts/stock-next-clang22}"
kernel_defconfig="${KERNEL_DEFCONFIG:-RMX1901_defconfig}"
llvm_bin="${LLVM_BIN:-${android_root}/toolchains/llvm-22.1.8/bin}"
host_bin="${HOST_BIN:-${android_root}/toolchains/host-tools/usr/bin}"
gnu_bin="${GNU_BIN:-${android_root}/toolchains/proton-clang-13-9fb011b/bin}"
cross_compile="${CROSS_COMPILE:-${gnu_bin}/aarch64-linux-gnu-}"
cross_compile_arm32="${CROSS_COMPILE_ARM32:-${gnu_bin}/arm-linux-gnueabi-}"
resukisu_dir="${RESUKISU_DIR:-${kernel_root}/KernelSU}"
jobs="${JOBS:-$(nproc)}"
required_clang_major="${REQUIRE_CLANG_MAJOR:-22}"
enable_thinlto="${ENABLE_THINLTO:-0}"
enable_polly="${ENABLE_POLLY:-0}"
enable_llvm_tuning="${ENABLE_LLVM_TUNING:-0}"

if [[ ! -d "${llvm_bin}" ]]; then
	echo "LLVM_BIN is not a directory: ${llvm_bin}" >&2
	exit 1
fi
if [[ ! -d "${resukisu_dir}" ]]; then
	echo "ReSukiSU submodule is missing: ${resukisu_dir}" >&2
	exit 1
fi

export PATH="${llvm_bin}:${host_bin}:${PATH}"

required_tools=(
	clang ld.lld llvm-ar llvm-nm llvm-objcopy llvm-objdump
	llvm-readelf llvm-strip
)
for required_tool in "${required_tools[@]}"; do
	if ! command -v "${required_tool}" >/dev/null 2>&1; then
		echo "Missing required tool: ${required_tool}" >&2
		exit 1
	fi
done
if ! command -v "${cross_compile}ld" >/dev/null 2>&1; then
	echo "Missing GNU cross linker: ${cross_compile}ld" >&2
	exit 1
fi
if ! command -v "${cross_compile_arm32}ld" >/dev/null 2>&1; then
	echo "Missing ARM32 cross linker: ${cross_compile_arm32}ld" >&2
	exit 1
fi

if [[ -x "${llvm_bin}/llvm-dis" ]]; then
	llvm_dis="${llvm_bin}/llvm-dis"
else
	llvm_dis="${kernel_root}/scripts/clang-llvm-dis"
fi

clang_version="$(clang -dumpversion)"
case "${clang_version}" in
	"${required_clang_major}".*) ;;
	*)
		echo "Clang ${required_clang_major} is required, found ${clang_version}" >&2
		exit 1
		;;
esac

compiler_command="clang"
if command -v ccache >/dev/null 2>&1; then
	compiler_command="ccache clang"
fi

default_kcflags=(
	-fuse-ld=lld
	-Wno-default-const-init-var-unsafe
	-Wno-default-const-init-field-unsafe
	-Wno-implicit-enum-enum-cast
)
if [[ -n "${KCFLAGS:-}" ]]; then
	read -r -a kcflags_parts <<<"${KCFLAGS}"
else
	kcflags_parts=("${default_kcflags[@]}")
fi

llvm_backend_flags=(
	-mllvm -inline-threshold=500
	-mllvm -import-instr-limit=200
	-mllvm -enable-gvn-hoist=true
)
lld_backend_flags=(
	--lto-O3
	"--thinlto-jobs=${jobs}"
	--mllvm=-inline-threshold=500
	--mllvm=-import-instr-limit=200
	--mllvm=-enable-gvn-hoist=true
)

if [[ "${enable_llvm_tuning}" == "1" ]]; then
	# SDM710 combines Cortex-A55- and Cortex-A75-derived cores. Keep one
	# ARMv8.2-A ISA baseline and tune scheduling for the efficiency cores.
	kcflags_parts+=(
		-march=armv8.2-a
		-mtune=cortex-a55
		"${llvm_backend_flags[@]}"
	)
fi
if [[ "${enable_polly}" == "1" ]]; then
	kcflags_parts+=(
		-mllvm -polly
		-mllvm -polly-vectorizer=stripmine
	)
fi

kcflags="${kcflags_parts[*]}"
kbuild_kcflags_file="${build_output}/.neutron-kcflags.rsp"
kbuild_kcflags="@${kbuild_kcflags_file}"
kbuild_ldflags_parts=()
if [[ -n "${KBUILD_LDFLAGS:-}" ]]; then
	read -r -a kbuild_ldflags_parts <<<"${KBUILD_LDFLAGS}"
fi
if [[ "${enable_thinlto}" == "1" ]]; then
	kbuild_ldflags_parts+=("${lld_backend_flags[@]}")
fi
kbuild_ldflags="${kbuild_ldflags_parts[*]}"
ldflags="${LDFLAGS:--EL -maarch64elf}"

probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/kernel-llvm-probe.XXXXXX")"
trap 'rm -rf "${probe_dir}"' EXIT
printf 'int kernel_llvm_probe(int value) { return value + 1; }\n' >"${probe_dir}/probe.c"
clang --target=aarch64-linux-gnu -O2 -c "${probe_dir}/probe.c" \
	-o "${probe_dir}/probe.o" "${kcflags_parts[@]}"
if [[ "${enable_thinlto}" == "1" ]]; then
	clang --target=aarch64-linux-gnu -O2 -flto=thin \
		-c "${probe_dir}/probe.c" -o "${probe_dir}/probe.lto.o"
	ld.lld -r "${probe_dir}/probe.lto.o" -o "${probe_dir}/probe.linked.o" \
		"${lld_backend_flags[@]}"
fi

make_args=(
	"O=${build_output}"
	ARCH=arm64
	SUBARCH=arm64
	LLVM=1
	LLVM_IAS=1
	"CC=${compiler_command}"
	HOSTCC=clang
	HOSTCXX=clang++
	LD=ld.lld
	AR=llvm-ar
	NM=llvm-nm
	"LLVM_DIS=${llvm_dis}"
	OBJCOPY=llvm-objcopy
	OBJDUMP=llvm-objdump
	STRIP=llvm-strip
	"CROSS_COMPILE=${cross_compile}"
	"CROSS_COMPILE_ARM32=${cross_compile_arm32}"
	"KCFLAGS=${kbuild_kcflags}"
	"KBUILD_LDFLAGS=${kbuild_ldflags}"
	"LDFLAGS=${ldflags}"
)

echo "Building RMX1901 stock-next"
echo "Compiler: $(clang --version | head -n 1)"
echo "Linker: $(ld.lld --version | head -n 1)"
echo "ReSukiSU: $(git -C "${resukisu_dir}" rev-parse HEAD)"
echo "Output: ${build_output}"
echo "ThinLTO: ${enable_thinlto}"
echo "Polly: ${enable_polly}"
echo "LLVM tuning: ${enable_llvm_tuning}"
echo "KCFLAGS: ${kcflags}"
echo "KBUILD_LDFLAGS: ${kbuild_ldflags}"
echo "LDFLAGS: ${ldflags}"

mkdir -p "${build_output}"
printf '%s\n' "${kcflags_parts[@]}" >"${kbuild_kcflags_file}"

make -C "${kernel_root}" "${make_args[@]}" "${kernel_defconfig}"
if [[ "${enable_thinlto}" == "1" ]]; then
	"${kernel_root}/scripts/config" --file "${build_output}/.config" \
		--enable LTO_CLANG --disable LTO_NONE
	make -C "${kernel_root}" "${make_args[@]}" olddefconfig
	grep -q '^CONFIG_LTO_CLANG=y$' "${build_output}/.config"
fi
grep -q '^CONFIG_PRODUCT_REALME_RMX1901=y$' "${build_output}/.config"
grep -q '^CONFIG_PSTORE_RAM=y$' "${build_output}/.config"
grep -q '^CONFIG_BUILD_ARM64_APPENDED_DTB_IMAGE=y$' "${build_output}/.config"

smp_config=""
preempt_config=""
grep -q '^CONFIG_SMP=y$' "${build_output}/.config" && smp_config="y"
grep -q '^CONFIG_PREEMPT=y$' "${build_output}/.config" && preempt_config="y"
mkdir -p "${build_output}/include/generated"
(
	cd "${build_output}"
	"${kernel_root}/scripts/mkcompile_h" \
		include/generated/compile.h arm64 "${smp_config}" \
		"${preempt_config}" "${compiler_command} ${kcflags}"
)

targets=(Image.gz)
if [[ "${BUILD_DTBS:-1}" == "1" ]]; then
	targets+=(
		18041/sdm710.dtb
		18621/sdm710.dtb
		19651/sdm710.dtb
		19691/sdm710.dtb
	)
fi
make -C "${kernel_root}" -j"${jobs}" "${make_args[@]}" "${targets[@]}"

kernel_image="${build_output}/arch/arm64/boot/Image.gz"
test -s "${kernel_image}"
test -s "${build_output}/vmlinux"
grep -aFq "clang version ${clang_version}" "${build_output}/vmlinux"

if grep -q '^CONFIG_KSU=y$' "${build_output}/.config"; then
	grep -q '^CONFIG_KSU_MANUAL_HOOK=y$' "${build_output}/.config"
	grep -aFq '@ReSukiSU' "${build_output}/vmlinux"
fi

kernel_release="$(make -s -C "${kernel_root}" "${make_args[@]}" kernelrelease)"
case "${kernel_release}" in
	4.9.337-LineageOS*) ;;
	*)
		echo "Unexpected kernel release: ${kernel_release}" >&2
		exit 1
		;;
esac

sha256sum "${kernel_image}"
echo "Kernel release: ${kernel_release}"
