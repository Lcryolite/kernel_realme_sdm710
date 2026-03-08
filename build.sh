#!/bin/bash
# 遇到报错自动停止执行
set -e

# ================= 环境变量配置 =================
export PATH=$(pwd)/clang/bin/:$PATH
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-none-eabi-
export ARCH=arm64
export SUBARCH=arm64
# 内核签名
export KBUILD_BUILD_USER="Lcryolite"
export KBUILD_BUILD_HOST="Lcryolite"
# LLVM + LTO 优化标志
export LLVM=1
export LLVM_IAS=1
export LD=ld.lld
export KBUILD_LTO_CLANG=1

# 【终极杀招】物理删除 Proton-Clang 里冲突的老旧工具，强迫系统使用现代汇编器
echo "🧹 0/4 正在物理清除工具链污染..."
rm -f clang/bin/as clang/bin/ld clang/bin/ld.bfd clang/bin/ld.gold

# 隔离宿主工具链
HOST_ARGS="HOSTCC=/usr/bin/gcc HOSTCXX=/usr/bin/g++ HOSTLD=/usr/bin/ld HOSTAR=/usr/bin/ar"

# 设备配置信息
KERNEL_DEFCONFIG="sdm710_defconfig"
KERNEL_CMDLINE="ARCH=arm64 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 O=out"
# ================================================

# 获取当前时间用于给刷机包命名
TIME=$(TZ=GMT+08 date +%m%d%H%M)

echo "🩹 0.5/4 正在强制 vDSO32 使用现代 LLD 链接器..."
# 先恢复文件初始状态（防止多次运行脚本导致重复添加）
git checkout arch/arm64/kernel/vdso32/Makefile 2>/dev/null || true
# 暴力注入 lld 链接指令，彻底绕过系统老旧 ld
echo "ccflags-y += -fuse-ld=lld" >> arch/arm64/kernel/vdso32/Makefile
echo "VDSO_LDFLAGS += -fuse-ld=lld" >> arch/arm64/kernel/vdso32/Makefile

echo "🧹 1/4 正在进行彻底的物理清理..."
# 直接删除整个 out 输出目录，免去 Kbuild 解析配置的烦恼
rm -rf out/
# 如果有旧的 dtb 文件也一并删掉
rm -f AnyKernel3/Image.gz-dtb
echo "🧬 1.5/4 正在极速拉取并注入 ReSukiSU 源码与配置..."
if [ ! -d "drivers/kernelsu" ]; then
    echo "-> 正在使用浅克隆 (--depth=1) 加速下载..."
    git clone --depth=1 https://github.com/ReSukiSU/ReSukiSU.git KernelSU
    echo "-> 正在执行本地注入脚本..."
    # 直接使用刚刚秒下的本地脚本，避免再次请求网络
    bash KernelSU/kernel/setup.sh main
else
    echo "ReSukiSU 源码已存在，跳过拉取。"
fi

# 2. 注入配置（先删除旧的注入防止无限追加，再重新写入）
sed -i '/CONFIG_KSU/d' arch/arm64/configs/$KERNEL_DEFCONFIG

echo "为 4.9 内核强制开启 hook 支持..."
echo "CONFIG_KSU=y" >> arch/arm64/configs/$KERNEL_DEFCONFIG
echo "CONFIG_KSU_MANUAL_HOOK=y" >> arch/arm64/configs/$KERNEL_DEFCONFIG
echo "CONFIG_KSU_MANUAL_HOOK_AUTO_SETUID_HOOK=y" >> arch/arm64/configs/$KERNEL_DEFCONFIG
echo "CONFIG_KSU_MANUAL_HOOK_AUTO_INITRC_HOOK=y" >> arch/arm64/configs/$KERNEL_DEFCONFIG
echo "CONFIG_KSU_MANUAL_HOOK_AUTO_INPUT_HOOK=y" >> arch/arm64/configs/$KERNEL_DEFCONFIG

echo "⚙️  2/4 正在生成内核配置文件 ($KERNEL_DEFCONFIG)..."
make $KERNEL_CMDLINE $KERNEL_DEFCONFIG CC="ccache clang" $HOST_ARGS

# 【终极修复】强行关闭 32 位 vDSO 编译，绕过裸机工具链限制
sed -i 's/CONFIG_VDSO32=y/# CONFIG_VDSO32 is not set/g' out/.config

echo "🚀 3/4 正在榨干 CPU 进行多核编译 (-j$(nproc))..."
make $KERNEL_CMDLINE CC="ccache clang" -j$(nproc) $HOST_ARGS

echo "📦 4/4 编译完成，正在利用 AnyKernel3 打包..."
if [ -f "out/arch/arm64/boot/Image.gz-dtb" ]; then
    cp out/arch/arm64/boot/Image.gz-dtb AnyKernel3/
    cd AnyKernel3

    ZIP_NAME="RMX1901-ReSuki-Local-${TIME}.zip"
    zip -r9 "../${ZIP_NAME}" * -x .git README.md *placeholder
    cd ..

    echo "🎉 大功告成！"
    echo "刷机包位置: $(pwd)/${ZIP_NAME}"
else
    echo "❌ 错误：未找到编译出的 Image.gz-dtb 文件，内核编译可能失败了。"
    exit 1
fi
