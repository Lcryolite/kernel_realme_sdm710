#!/usr/bin/env bash

set -euo pipefail

kernel_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
build_output="${OUT_DIR:-out-clang22}"
if [[ "${build_output}" != /* ]]; then
	build_output="${kernel_root}/${build_output}"
fi
kernel_defconfig="${KERNEL_DEFCONFIG:-sdm670-perf_defconfig}"
cross_compile="${CROSS_COMPILE:-aarch64-linux-gnu-}"
cross_compile_arm32="${CROSS_COMPILE_ARM32:-arm-linux-gnueabi-}"
llvm_bin="${LLVM_BIN:-}"

if [[ -n "${llvm_bin}" ]]; then
	if [[ ! -d "${llvm_bin}" ]]; then
		echo "LLVM_BIN is not a directory: ${llvm_bin}" >&2
		exit 1
	fi
	export PATH="${llvm_bin}:${PATH}"
fi

if ! command -v "${cross_compile_arm32}ld" >/dev/null 2>&1 && \
   command -v arm-none-eabi-ld >/dev/null 2>&1; then
	cross_compile_arm32="arm-none-eabi-"
fi


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

kcflags="${KCFLAGS:-}"
if [[ " ${kcflags} " != *" -fuse-ld=lld "* ]]; then
	kcflags="${kcflags:+${kcflags} }-fuse-ld=lld"
fi

make_args=(
	"O=${build_output}"
	ARCH=arm64
	LLVM=1
	LLVM_IAS=1
	"CC=${compiler_command}"
	"CROSS_COMPILE=${cross_compile}"
	"CROSS_COMPILE_ARM32=${cross_compile_arm32}"
	"KCFLAGS=${kcflags}"
)

echo "Building RMX1901 A17 ReSukiSU"
echo "Compiler: $(clang --version | head -n 1)"
echo "Output: ${build_output}"

make -C "${kernel_root}" "${make_args[@]}" "${kernel_defconfig}"

grep -q '^CONFIG_KSU_MANUAL_HOOK=y$' "${build_output}/.config"
grep -q '^# CONFIG_KSU_SUSFS is not set$' "${build_output}/.config"
grep -q '^# CONFIG_BUILD_ARM64_APPENDED_DTB_IMAGE is not set$' \
	"${build_output}/.config"

# KernelSU includes generated/compile.h directly, but this old Kbuild tree
# does not make init/version.o early enough to generate it before drivers are
# compiled. Generate the same header explicitly in the output tree.
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
test -s "${build_output}/include/generated/compile.h"

make -C "${kernel_root}" -j"$(nproc)" "${make_args[@]}" Image.gz

if [[ "${BUILD_DTBS:-1}" == "1" ]]; then
	make -C "${kernel_root}" -j"$(nproc)" "${make_args[@]}" dtbs
	shopt -s nullglob
	dtb_files=("${build_output}"/arch/arm64/boot/dts/**/*.dtb)
	dtbo_files=("${build_output}"/arch/arm64/boot/dts/**/*.dtbo)
	if (( ${#dtb_files[@]} == 0 )); then
		echo "No DTB was generated" >&2
		exit 1
	fi
	overlay_enabled=false
	grep -q '^CONFIG_BUILD_ARM64_DT_OVERLAY=y$' \
		"${build_output}/.config" && overlay_enabled=true
	if [[ "${overlay_enabled}" == true ]] &&
	   (( ${#dtbo_files[@]} == 0 )); then
		echo "DT overlays are enabled but no DTBO was generated" >&2
		exit 1
	fi
	echo "Generated ${#dtb_files[@]} DTB(s) and ${#dtbo_files[@]} DTBO(s)"
fi

kernel_image="${build_output}/arch/arm64/boot/Image.gz"
test -s "${kernel_image}"
grep -aFq "clang version ${clang_version}" "${build_output}/vmlinux"
grep -aFq 'v4.1.0-97163bdc@ReSukiSU' "${build_output}/vmlinux"

kernel_release="$(make -s -C "${kernel_root}" "${make_args[@]}" kernelrelease)"
if [[ "${kernel_release}" != "4.9.337+67-RMX1901-A17-ReSukiSU" ]]; then
	echo "Unexpected kernel release: ${kernel_release}" >&2
	exit 1
fi

echo "Built ${kernel_image}"
echo "Kernel release: ${kernel_release}"
