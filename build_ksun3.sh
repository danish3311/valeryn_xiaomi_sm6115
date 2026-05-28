#!/bin/bash

DEFCONFIG="vendor/bengal-perf_defconfig"
ZIPNAME=4.19-A16-valeryn-ksun-3.2.0-`date +'%d.%m.%y-%H%M'`.zip

set -x

# Setup tools
curl -o toolchain.tar.xz -L https://github.com/Joe7500/Builds/releases/download/Stuff/toolchain.tar.xz || exit 1
curl -o AnyKernel3.tar.xz -L https://github.com/Joe7500/Builds/releases/download/Stuff/AnyKernel3.tar.xz || exit 1
rm -rf toolchain prebuilts
tar xf toolchain.tar.xz  || exit 1
ln -s prebuilts/clang/host/linux-x86/clang-stablekern/ toolchain
tar xf AnyKernel3.tar.xz  || exit 1
PATH=$PWD/toolchain/bin:$PATH

# Apply changes
git cherry-pick 84b385eb683c32beed15194b8c69611b3f35447f || exit 1
git cherry-pick 70865a757dfceb92fd0dc7d9074b432086c7b73f || exit 1
git cherry-pick 3f72527874b7007742e2dd24d5dc22891c031c3b || exit 1
git cherry-pick 5c6b9ed54ab6f3ffb820dfa27c037137e3eeae52 || exit 1
git cherry-pick 9beaa41861278b138f028253cdb0b4c5f80ee646
grep -vE '<<<|===|>>>' arch/arm64/configs/vendor/bengal-perf_defconfig > arch/arm64/configs/vendor/bengal-perf_defconfig.1
mv arch/arm64/configs/vendor/bengal-perf_defconfig.1 arch/arm64/configs/vendor/bengal-perf_defconfig
git add arch/arm64/configs/vendor/bengal-perf_defconfig
git cherry-pick --continue --no-edit

curl -o KernelSU-Next-susfs-3.2.0.tar.xz -L https://github.com/Joe7500/valeryn_xiaomi_sm6115/raw/refs/heads/build-actions/KernelSU-Next-susfs-3.2.0.tar.xz || exit 1
tar xf KernelSU-Next-susfs-3.2.0.tar.xz

cd KernelSU-Next
git reset --hard
git switch legacy-susfs
git tag 3.2.0-legacy-susfs
cd ..
bash KernelSU-Next/kernel/setup.sh 3.2.0-legacy-susfs

echo "CONFIG_KSU=y" >> arch/arm64/configs/vendor/bengal-perf_defconfig
echo "# CONFIG_KPROBES is not set" >> arch/arm64/configs/vendor/bengal-perf_defconfig
echo "CONFIG_HAVE_SYSCALL_TRACEPOINTS=y" >> arch/arm64/configs/vendor/bengal-perf_defconfig
echo "CONFIG_KSU_MANUAL_HOOK=y" >> arch/arm64/configs/vendor/bengal-perf_defconfig
echo "CONFIG_KSU_SUSFS=y" >> arch/arm64/configs/vendor/bengal-perf_defconfig
echo "CONFIG_KSU_SUSFS_SUS_PATH=y" >> arch/arm64/configs/vendor/bengal-perf_defconfig
echo "CONFIG_KSU_SUSFS_SUS_MOUNT=y" >> arch/arm64/configs/vendor/bengal-perf_defconfig
echo "CONFIG_KSU_SUSFS_SUS_KSTAT=y" >> arch/arm64/configs/vendor/bengal-perf_defconfig
echo "CONFIG_KSU_SUSFS_SPOOF_UNAME=y" >> arch/arm64/configs/vendor/bengal-perf_defconfig
echo "CONFIG_KSU_SUSFS_ENABLE_LOG=y" >> arch/arm64/configs/vendor/bengal-perf_defconfig
echo "CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y" >> arch/arm64/configs/vendor/bengal-perf_defconfig
echo "CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y" >> arch/arm64/configs/vendor/bengal-perf_defconfig
echo "CONFIG_KSU_SUSFS_OPEN_REDIRECT=y" >> arch/arm64/configs/vendor/bengal-perf_defconfig
echo "CONFIG_KSU_SUSFS_SUS_MAP=y" >> arch/arm64/configs/vendor/bengal-perf_defconfig
if grep -q "THREAD_INFO_IN_TASK" "drivers/kernelsu/Kconfig"; then
  echo "CONFIG_THREAD_INFO_IN_TASK=y" >> arch/arm64/configs/vendor/bengal-perf_defconfig
fi
echo "CONFIG_KSU_SUSFS_TRY_UMOUNT=n" >> arch/arm64/configs/vendor/bengal-perf_defconfig

echo "-perf" > localversion

# Build it
rm -rf out/
mkdir out/
make O=out ARCH=arm64 LLVM=1 LLVM_IAS=1 $DEFCONFIG
make O=out ARCH=arm64 LLVM=1 LLVM_IAS=1 -j$(nproc) || exit 1
make O=out ARCH=arm64 LLVM=1 LLVM_IAS=1 -j$(nproc) Image.gz || exit 1
make O=out ARCH=arm64 LLVM=1 LLVM_IAS=1 -j$(nproc) dtbs || exit 1
make O=out ARCH=arm64 LLVM=1 LLVM_IAS=1 -j$(nproc) INSTALL_HDR_PATH=kernel_headers headers_install

# Make anykernel package
kernel="out/arch/arm64/boot/Image.gz"
dtbo="out/arch/arm64/boot/dtbo.img"
dtb="out/arch/arm64/boot/dtb.img"

cp "out/arch/arm64/boot/dtb" "out/arch/arm64/boot/dtb.img"

cp $kernel AnyKernel3
cp $dtbo AnyKernel3
cp $dtb AnyKernel3

cd AnyKernel3
zip -r9 "../$ZIPNAME" * -x .git *placeholder
cd ..
