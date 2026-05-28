#!/bin/bash

DEFCONFIG="vendor/bengal-perf_defconfig"
ZIPNAME=4.19-A16-valeryn-ksun-1.1.1-`date +'%d.%m.%y-%H%M'`.zip

set -x

# Setup tools
curl -o toolchain.tar.xz -L https://github.com/Joe7500/Builds/releases/download/Stuff/toolchain.tar.xz || exit 1
curl -o AnyKernel3.tar.xz -L https://github.com/Joe7500/Builds/releases/download/Stuff/AnyKernel3.tar.xz || exit 1
rm -rf toolchain prebuilts
tar xf toolchain.tar.xz || exit 1
ln -s prebuilts/clang/host/linux-x86/clang-stablekern/ toolchain
tar xf AnyKernel3.tar.xz || exit 1
PATH=$PWD/toolchain/bin:$PATH

# Apply changes
git cherry-pick 9ddea125151ce61abbd05a84e8de72f8fc45da57 || exit 1
git cherry-pick f0b967626c361d95969dd962cd22dffe1ebe510d || exit 1
git cherry-pick dbc26ce49d11c5d1293dedb5f647dcdacf4432dd
grep -vE '<<<|===|>>>' arch/arm64/configs/vendor/bengal-perf_defconfig > arch/arm64/configs/vendor/bengal-perf_defconfig.1
mv arch/arm64/configs/vendor/bengal-perf_defconfig.1 arch/arm64/configs/vendor/bengal-perf_defconfig
git add arch/arm64/configs/vendor/bengal-perf_defconfig
git cherry-pick --continue --no-edit

curl -o KernelSU-Next-susfs-1.1.1.tar.xz -L https://github.com/Joe7500/valeryn_xiaomi_sm6115/raw/refs/heads/build-actions/KernelSU-Next-susfs-1.1.1.tar.xz || exit 1
tar xf KernelSU-Next-susfs-1.1.1.tar.xz
cd KernelSU-Next/
git reset --hard
git switch next-susfs
git tag next-susfs-1.5.12
cd ..
bash KernelSU-Next/kernel/setup.sh next-susfs

echo 'CONFIG_KSU=y' >> arch/arm64/configs/vendor/bengal-perf_defconfig

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

# Make prebuilt package
mkdir tmpwork/
cd tmpwork
curl -o kernel-prebuilt-perf-valeryn-A16.tar.xz -L https://github.com/Joe7500/Builds/releases/download/Stuff/kernel-prebuilt-perf-valeryn-A16.tar.xz
tar xvf kernel-prebuilt-perf-valeryn-A16.tar.xz
unzip ../4.19*.zip
cp -fv Image.gz kernel/xiaomi/chime/prebuilts/
tar cJf ../kernel-prebuilt-perf-valeryn-A16-`date +"%d.%m.%y"`.tar.xz kernel/xiaomi/chime/
cd ..

