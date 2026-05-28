#!/bin/bash

DEFCONFIG="vendor/bengal-perf_defconfig"
ZIPNAME=4.19-A16-valeryn-`date +'%d.%m.%y-%H%M'`.zip

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
