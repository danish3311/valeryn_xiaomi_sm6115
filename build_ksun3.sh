#!/bin/bash
#
# build_ksun3.sh — vendor/bengal-perf + KernelSU-Next (SUSFS) build
#
# CHANGED vs the old version:
#   - No longer downloads a static "KernelSU-Next-susfs-3.2.0.tar.xz" from
#     the build-actions branch. That tarball was a hand-packaged, single-commit
#     snapshot of pershoot/KernelSU-Next's now-DELETED "legacy-susfs" branch,
#     with KSU_VERSION/KSU_VERSION_TAG hardcoded (33133 / "3.2.0-legacy-susfs")
#     in kernel/Kbuild, overriding the real auto-versioning logic.
#   - Now clones pershoot/KernelSU-Next's "dev-susfs" branch directly at build
#     time (confirmed: this is the current branch that still uses the old-style
#     kernel/Kbuild module layout our 4.19 GKI-1.0 kernel needs, and it already
#     contains everything from the official v3.3.0 release — 52 commits ahead
#     of the v3.3.0 tag as of this writing).
#   - Because we keep a real .git history (not a squashed tarball), Kbuild's
#     built-in auto-versioning takes over and computes KSU_VERSION /
#     KSU_VERSION_TAG from actual git state — nothing hardcoded, nothing spoofed.
#   - Dropped CONFIG_KSU_SUSFS_TRY_UMOUNT: that symbol no longer exists in
#     dev-susfs's Kconfig.
#   - CONFIG_THREAD_INFO_IN_TASK is now set unconditionally: KSU_SUSFS itself
#     hard-depends on it in dev-susfs's Kconfig (used to be optional).
#   - Zip filename now embeds the real resolved KSU-Next tag instead of a
#     hand-typed "3.2.0" string.
#
# To track a different branch later (e.g. if pershoot renames dev-susfs again),
# change KSU_BRANCH below — that's the only thing you should need to touch.

DEFCONFIG="vendor/bengal-perf_defconfig"
KSU_REPO="https://github.com/pershoot/KernelSU-Next"
KSU_BRANCH="dev-susfs"

set -x

# Setup tools
curl -o toolchain.tar.xz -L https://github.com/danish3311/Builds/releases/download/Stuff/toolchain.tar.xz || exit 1
curl -o AnyKernel3.tar.xz -L https://github.com/danish3311/Builds/releases/download/Stuff/AnyKernel3.tar.xz || exit 1
rm -rf toolchain prebuilts
tar xf toolchain.tar.xz || exit 1
ln -s prebuilts/clang/host/linux-x86/clang-stablekern/ toolchain
tar xf AnyKernel3.tar.xz || exit 1
PATH=$PWD/toolchain/bin:$PATH

# Apply kernel-side SUSFS patches (unchanged — these patch the KERNEL tree
# itself, e.g. fs/susfs.c, and are independent of which KernelSU-Next module
# version we build against below).
git cherry-pick 84b385eb683c32beed15194b8c69611b3f35447f || exit 1
git cherry-pick 70865a757dfceb92fd0dc7d9074b432086c7b73f || exit 1
git cherry-pick 3f72527874b7007742e2dd24d5dc22891c031c3b || exit 1
git cherry-pick 5c6b9ed54ab6f3ffb820dfa27c037137e3eeae52 || exit 1
git cherry-pick 9beaa41861278b138f028253cdb0b4c5f80ee646
grep -vE '<<<|===|>>>' arch/arm64/configs/vendor/bengal-perf_defconfig > arch/arm64/configs/vendor/bengal-perf_defconfig.1
mv arch/arm64/configs/vendor/bengal-perf_defconfig.1 arch/arm64/configs/vendor/bengal-perf_defconfig
git add arch/arm64/configs/vendor/bengal-perf_defconfig
git cherry-pick --continue --no-edit

# Fetch the current KernelSU-Next (SUSFS) module.
# --filter=blob:none keeps this lightweight (fetches full commit graph /
# branch refs, but defers blob downloads to what's actually checked out) while
# still giving Kbuild's version logic access to origin/dev for merge-base
# calculation, which a shallow --depth clone of a single branch would NOT have.
rm -rf KernelSU-Next
git clone --filter=blob:none --no-single-branch "$KSU_REPO" KernelSU-Next || exit 1
cd KernelSU-Next
git switch "$KSU_BRANCH" || exit 1
cd ..

# setup.sh's checkout-by-argument logic is dead code upstream (commented out);
# all it actually does is symlink KernelSU-Next/kernel into drivers/kernelsu
# and patch the drivers Makefile/Kconfig. No argument needed.
bash KernelSU-Next/kernel/setup.sh || exit 1

echo "CONFIG_KSU=y" >> arch/arm64/configs/vendor/bengal-perf_defconfig
echo "# CONFIG_KPROBES is not set" >> arch/arm64/configs/vendor/bengal-perf_defconfig
echo "CONFIG_HAVE_SYSCALL_TRACEPOINTS=y" >> arch/arm64/configs/vendor/bengal-perf_defconfig
echo "CONFIG_KSU_MANUAL_HOOK=y" >> arch/arm64/configs/vendor/bengal-perf_defconfig
echo "CONFIG_THREAD_INFO_IN_TASK=y" >> arch/arm64/configs/vendor/bengal-perf_defconfig
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
# (CONFIG_KSU_SUSFS_TRY_UMOUNT dropped — symbol no longer exists on dev-susfs)

echo "-perf" > localversion

# Build it — tee the log so we can pull the real KSU_VERSION/tag that Kbuild
# resolved (its $(info) lines), instead of guessing or hardcoding it.
rm -rf out/
mkdir out/
BUILD_LOG="ksun3_build.log"
make O=out ARCH=arm64 LLVM=1 LLVM_IAS=1 $DEFCONFIG
make O=out ARCH=arm64 LLVM=1 LLVM_IAS=1 -j$(nproc) 2>&1 | tee "$BUILD_LOG"
if [ ${PIPESTATUS[0]} -ne 0 ]; then exit 1; fi
make O=out ARCH=arm64 LLVM=1 LLVM_IAS=1 -j$(nproc) Image.gz || exit 1
make O=out ARCH=arm64 LLVM=1 LLVM_IAS=1 -j$(nproc) dtbs || exit 1
make O=out ARCH=arm64 LLVM=1 LLVM_IAS=1 -j$(nproc) INSTALL_HDR_PATH=kernel_headers headers_install

# Pull the resolved version out of the build log for the zip name / a sanity
# check. Falls back to the branch name if the info lines weren't captured
# (e.g. incremental build skipped the KSU object).
KSU_VERSION_TAG=$(grep -oP -- '-- KernelSU-Next tag: \K.*' "$BUILD_LOG" | tail -1)
KSU_VERSION_NUM=$(grep -oP -- '-- KernelSU-Next version: \K[0-9]+' "$BUILD_LOG" | tail -1)
if [ -z "$KSU_VERSION_TAG" ]; then
  KSU_VERSION_TAG="$KSU_BRANCH-unknown"
fi
echo "Resolved KernelSU-Next version: ${KSU_VERSION_NUM:-unknown} (${KSU_VERSION_TAG})"

ZIPNAME="4.19-A16-valeryn-ksun-${KSU_VERSION_TAG}-`date +'%d.%m.%y-%H%M'`.zip"

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
