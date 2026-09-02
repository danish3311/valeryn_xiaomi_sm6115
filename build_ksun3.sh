#!/bin/bash
DEFCONFIG="vendor/bengal-perf_defconfig"

# --- IMPORTANT FIX ---
# https://github.com/KernelSU-Next/KernelSU-Next (the official repo you were
# pointing at) has ZERO SUSFS support — verified by cloning it at tag v3.3.0
# and grepping kernel/Kconfig, kernel/Kbuild, and every .c/.h file: no
# KSU_SUSFS symbol, no susfs.c, nothing. Its own setup.sh also hardcodes
# OWNER=KernelSU-Next / REPO=KernelSU-Next, so no argument you pass it can
# make it pull SUSFS in — "v3.3.0" just checks out the official tag, same
# commit either way. Your CONFIG_KSU_SUSFS_* lines would have been silently
# ignored (unknown Kconfig symbols), giving you plain root with NO spoofing —
# built successfully, but with none of the hiding/spoof features you actually
# want from a "ksun3" (SUSFS) variant.
#
# The actual SUSFS-integrated fork is pershoot/KernelSU-Next. Its official
# releases (v3.2.0, v3.3.0 tags) also do NOT carry SUSFS — SUSFS only lives on
# specific branches. The branch that (a) still uses the old-style kernel/Kbuild
# module layout our 4.19 GKI-1.0 kernel needs, and (b) has SUSFS wired into
# Kconfig, is "dev-susfs". Verified: dev-susfs already contains everything
# from the official v3.3.0 release (confirmed via git merge-base — v3.3.0 is
# an ancestor, 52 commits behind dev-susfs's tip as of this writing), so this
# gives you v3.3.0 AND working SUSFS, unlike pointing at the plain tag.
#
# There is no clean "vX.Y.Z-susfs" tag to pin to — dev-susfs is nightly/rolling
# past v3.3.0. If you want hard reproducibility instead of always tracking the
# latest dev-susfs commit, replace KSU_REF below with a specific commit hash
# from https://github.com/pershoot/KernelSU-Next/commits/dev-susfs instead of
# the branch name.
KSU_REF="dev-susfs"

set -x
# Setup tools
curl -o toolchain.tar.xz -L https://github.com/Joe7500/Builds/releases/download/Stuff/toolchain.tar.xz || exit 1
curl -o AnyKernel3.tar.xz -L https://github.com/Joe7500/Builds/releases/download/Stuff/AnyKernel3.tar.xz || exit 1
rm -rf toolchain prebuilts
tar xf toolchain.tar.xz  || exit 1
ln -s prebuilts/clang/host/linux-x86/clang-stablekern/ toolchain
tar xf AnyKernel3.tar.xz  || exit 1
PATH=$PWD/toolchain/bin:$PATH
# Apply changes (kernel-side SUSFS 2.1.0 patches — these create fs/susfs.c /
# include/linux/susfs.h, which is what makes the KSU_SUSFS driver code below
# actually have something to hook into. Unrelated to KSU-Next's own version.)
git cherry-pick 84b385eb683c32beed15194b8c69611b3f35447f || exit 1
git cherry-pick 70865a757dfceb92fd0dc7d9074b432086c7b73f || exit 1
git cherry-pick 3f72527874b7007742e2dd24d5dc22891c031c3b || exit 1
git cherry-pick 5c6b9ed54ab6f3ffb820dfa27c037137e3eeae52 || exit 1
git cherry-pick 9beaa41861278b138f028253cdb0b4c5f80ee646
grep -vE '<<<|===|>>>' arch/arm64/configs/vendor/bengal-perf_defconfig > arch/arm64/configs/vendor/bengal-perf_defconfig.1
mv arch/arm64/configs/vendor/bengal-perf_defconfig.1 arch/arm64/configs/vendor/bengal-perf_defconfig
git add arch/arm64/configs/vendor/bengal-perf_defconfig
git cherry-pick --continue --no-edit

# --- KernelSU-Next (SUSFS-integrated fork), latest dev-susfs ---
# This is pershoot's own real setup.sh (not dead code): it clones
# github.com/pershoot/KernelSU-Next, then `git checkout "$1"` — passing
# KSU_REF ("dev-susfs") checks out that branch specifically instead of
# the non-SUSFS default branch or a non-SUSFS release tag.
rm -rf KernelSU-Next
curl -LSs "https://raw.githubusercontent.com/pershoot/KernelSU-Next/dev-susfs/kernel/setup.sh" | bash -s "$KSU_REF" || exit 1

echo "CONFIG_KSU=y" >> arch/arm64/configs/vendor/bengal-perf_defconfig
# --- FIX ---
# dev-susfs's top-level Kconfig has:
#   config KSU
#       tristate "KernelSU function support"
#       depends on KPROBES || SUSFS
# There is NO "CONFIG_SUSFS" Kconfig symbol anywhere in this kernel tree —
# verified by grepping the full source after the susfs4ksu cherry-picks above
# are applied. Those patches add fs/susfs.c etc. but never define a top-level
# "config SUSFS" toggle. So the "|| SUSFS" half of that dependency can never
# be satisfied here, which makes KPROBES mandatory. The old (pre-version-bump)
# script disabled KPROBES because an older KSU-Next Kconfig didn't gate KSU on
# it this way — dev-susfs does. Disabling it here silently clamped
# CONFIG_KSU (and therefore every CONFIG_KSU_SUSFS_* option, which all
# `depends on KSU`) to unset, with only a Kconfig "override: reassigning"
# warning to show for it — no hard error, which is exactly why this shipped
# silently before the safety check below caught it.
# MODULES=y is already set in the stock bengal-perf_defconfig, and
# HAVE_KPROBES is auto-selected on arm64, so this has no other blockers.
echo "CONFIG_KPROBES=y" >> arch/arm64/configs/vendor/bengal-perf_defconfig
echo "CONFIG_HAVE_SYSCALL_TRACEPOINTS=y" >> arch/arm64/configs/vendor/bengal-perf_defconfig
echo "CONFIG_KSU_MANUAL_HOOK=y" >> arch/arm64/configs/vendor/bengal-perf_defconfig
if grep -q "THREAD_INFO_IN_TASK" "drivers/kernelsu/Kconfig"; then
  echo "CONFIG_THREAD_INFO_IN_TASK=y" >> arch/arm64/configs/vendor/bengal-perf_defconfig
fi
# Explicit SUSFS feature set. NOTE: as of dev-susfs, every one of these
# (including KSU_SUSFS itself) already has `default y` in Kconfig once
# CONFIG_KSU + CONFIG_THREAD_INFO_IN_TASK are set, so this block is
# technically redundant right now — but Kconfig defaults are exactly the
# kind of thing that silently changes between versions (TRY_UMOUNT existed
# in 3.2.0 and is GONE in dev-susfs; THREAD_INFO_IN_TASK used to be optional
# and is now a hard dependency). Being explicit here means a future default
# flipping to `n` upstream won't silently strip your spoofing without you
# noticing at build time.
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
# (CONFIG_KSU_SUSFS_TRY_UMOUNT intentionally omitted — that symbol no longer
# exists on dev-susfs; setting it would just be a harmless dead line, but
# there's no reason to carry it forward.)

# --- Compat shim: drivers/kernelsu/feature/sucompat.c does
#   #ifdef CONFIG_KSU_SUSFS
#   #include <linux/minmax.h>
#   #endif
# <linux/minmax.h> is where upstream Linux split min()/max()/clamp() out of
# kernel.h starting around 5.14 — this tree is 4.19 and doesn't have that
# file at all, so this include fails outright ("file not found"), not a
# missing-macro error. Verified: nothing in sucompat.c or the susfs headers
# actually calls anything beyond what THIS tree's include/linux/kernel.h
# already defines (min/max/min_t/max_t/min3/max3/clamp/clamp_t/clamp_val are
# all already present there). So this is purely a missing forwarding header,
# not a missing feature — a one-line shim that just pulls in kernel.h
# resolves it with no behavior change.
mkdir -p include/linux
if [ ! -f include/linux/minmax.h ]; then
cat > include/linux/minmax.h << 'EOF'
/* Compat shim for this 4.19 tree: upstream split min()/max()/clamp() into
 * this header starting ~5.14. This kernel still defines them in kernel.h,
 * so just pull that in. */
#ifndef _LINUX_MINMAX_H
#define _LINUX_MINMAX_H
#include <linux/kernel.h>
#endif
EOF
fi

echo "-perf" > localversion
# Build it — tee the log so we can read back Kbuild's own resolved version
# string for the zip name, instead of hand-typing a version that can drift
# out of sync with what's actually on dev-susfs.
rm -rf out/
mkdir out/
BUILD_LOG="ksun3_build.log"
make O=out ARCH=arm64 LLVM=1 LLVM_IAS=1 $DEFCONFIG

# --- Hard safety check ---
# This is the exact class of bug that's bitten this build twice now: a
# defconfig line gets "accepted" (Kconfig even prints "override: reassigning
# to symbol X") but the *resolved* value in .config still ends up unset,
# because some dependency wasn't met — with nothing louder than a warning to
# show for it. Verify what actually landed, and if it didn't, dump the real
# state instead of just saying "it failed" again.
if ! grep -q "^CONFIG_KSU=y" out/.config; then
  echo "!!! BUILD ABORTED: CONFIG_KSU did not land in out/.config."
  echo "--- Resolved KSU-related lines from out/.config: ---"
  grep -E "^(CONFIG_KSU|CONFIG_KPROBES|CONFIG_MODULES|CONFIG_THREAD_INFO_IN_TASK)|# CONFIG_(KSU|KPROBES) is not set" out/.config
  echo "--- KSU's own Kconfig dependency line, for reference: ---"
  grep -A2 "^config KSU$" drivers/kernelsu/Kconfig 2>/dev/null
  exit 1
fi
if ! grep -q "^CONFIG_KSU_SUSFS=y" out/.config; then
  echo "!!! BUILD ABORTED: CONFIG_KSU_SUSFS did not land in out/.config."
  echo "--- Resolved SUSFS-related lines from out/.config: ---"
  grep -E "^CONFIG_KSU_SUSFS|# CONFIG_KSU_SUSFS is not set" out/.config
  echo "--- Possible causes: KernelSU-Next checked out at the wrong ref (not dev-susfs), or an unmet dependency clamped it the same way CONFIG_KSU was clamped above. ---"
  exit 1
fi
echo "Verified: CONFIG_KSU=y and CONFIG_KSU_SUSFS=y are present in out/.config"

make O=out ARCH=arm64 LLVM=1 LLVM_IAS=1 -j$(nproc) 2>&1 | tee "$BUILD_LOG"
if [ ${PIPESTATUS[0]} -ne 0 ]; then exit 1; fi
make O=out ARCH=arm64 LLVM=1 LLVM_IAS=1 -j$(nproc) Image.gz || exit 1
make O=out ARCH=arm64 LLVM=1 LLVM_IAS=1 -j$(nproc) dtbs || exit 1
make O=out ARCH=arm64 LLVM=1 LLVM_IAS=1 -j$(nproc) INSTALL_HDR_PATH=kernel_headers headers_install

KSU_RESOLVED_TAG=$(grep -oP -- '-- KernelSU-Next tag: \K.*' "$BUILD_LOG" | tail -1)
[ -z "$KSU_RESOLVED_TAG" ] && KSU_RESOLVED_TAG="$KSU_REF"
echo "Resolved KernelSU-Next version tag: $KSU_RESOLVED_TAG"

ZIPNAME="4.19-A16-valeryn-ksun-${KSU_RESOLVED_TAG}-`date +'%d.%m.%y-%H%M'`.zip"

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
