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
	llvm-readelf llvm-size llvm-strip
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

clang_version="$(clang -dumpversion)"
case "${clang_version}" in
	22.*) ;;
	*)
		echo "Clang 22 is required, found ${clang_version}" >&2
		exit 1
		;;
esac

compiler_command="clang"
if command -v ccache >/dev/null 2>&1; then
	compiler_command="ccache clang"
fi

kcflags="${KCFLAGS:--fuse-ld=lld -Wno-default-const-init-var-unsafe -Wno-default-const-init-field-unsafe -Wno-implicit-enum-enum-cast}"
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
	OBJCOPY=llvm-objcopy
	OBJDUMP=llvm-objdump
	STRIP=llvm-strip
	"CROSS_COMPILE=${cross_compile}"
	"CROSS_COMPILE_ARM32=${cross_compile_arm32}"
	"KCFLAGS=${kcflags}"
	"LDFLAGS=-EL -maarch64elf"
)

echo "Building RMX1901 stock-next"
echo "Compiler: $(clang --version | head -n 1)"
echo "Linker: $(ld.lld --version | head -n 1)"
echo "ReSukiSU: $(git -C "${resukisu_dir}" rev-parse HEAD)"
echo "Output: ${build_output}"

make -C "${kernel_root}" "${make_args[@]}" "${kernel_defconfig}"
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
