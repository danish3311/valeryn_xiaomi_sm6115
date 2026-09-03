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

# --- Compat shim #1b: drivers/kernelsu/infra/su_mount_ns.c does
#   #include <uapi/linux/mount.h>
# Upstream split various UAPI mount-related definitions out of
# include/uapi/linux/fs.h into a dedicated include/uapi/linux/mount.h
# starting around Linux 5.2 (for the new mount API — fsopen/fsconfig/
# move_mount/open_tree, MOUNT_ATTR_* flags, struct mount_attr, etc). This
# 4.19 tree predates that split, so the header genuinely doesn't exist here.
# Verified: su_mount_ns.c only actually uses two symbols from it — MS_PRIVATE
# and MS_REC (both classic, ancient mount flags, not part of the newer mount
# API at all) — and both are already defined in this tree's
# include/uapi/linux/fs.h. So again this is a missing forwarding header, not
# a missing feature: a shim that pulls in fs.h resolves it with no behavior
# change.
mkdir -p include/uapi/linux
if [ ! -f include/uapi/linux/mount.h ]; then
cat > include/uapi/linux/mount.h << 'EOF'
/* Compat shim for this 4.19 tree: upstream split various mount-related UAPI
 * definitions into this header starting ~5.2. The only symbols this
 * kernel's KernelSU-Next driver actually needs from it (MS_PRIVATE, MS_REC)
 * are already defined in uapi/linux/fs.h, so just pull that in. */
#ifndef _UAPI_LINUX_MOUNT_H
#define _UAPI_LINUX_MOUNT_H
#include <uapi/linux/fs.h>
#endif
EOF
fi

# --- Compat shim #2: newer KSU-Next driver code (pershoot/dev-susfs) calls
# three functions that don't exist in the susfs4ksu 2.1.0 kernel-side patches
# applied above (cherry-picked from Joe7500's fork):
#   susfs_is_current_proc_no_su() / susfs_set_current_proc_no_su()
#     — used in feature/sucompat.c
#   susfs_set_current_proc_umounted_for_zygote_next()
#     — used in hook/setuid_hook.c, always alongside the existing
#       susfs_set_current_proc_umounted(). Verified (grepped dev-susfs's
#       entire kernel/ tree): this is set-only, nothing ever reads it back —
#       and our 2.1.0 kernel-side susfs.c has no concept of it either, so
#       it's currently inert either way. Implementing it for real costs
#       nothing and carries no behavioral risk; a silent no-op stub would
#       have been the wrong call if that ever changes upstream.
# This is a genuine version mismatch between the kernel-side SUSFS patch
# version and the KSU-Next driver's SUSFS integration code, not a missing
# header. Fix: implement all three using the EXACT same pattern susfs_def.h
# already uses for its existing per-process flag (susfs_is_current_proc_umounted,
# at TIF bit 33) — dedicated bits in task_struct->thread_info.flags via the
# kernel's own test_ti_thread_flag / set_ti_thread_flag helpers. Verified no
# collision: arch/arm64's own TIF_* bits top out at 26 (TIF_TAGGED_ADDR), and
# susfs_def.h's own custom bit is 33, so bits 34/35 are safe.
python3 - << 'PYEOF'
path = "include/linux/susfs_def.h"
with open(path) as f:
    content = f.read()
if "susfs_is_current_proc_no_su" not in content:
    marker = "#endif // #ifndef KSU_SUSFS_DEF_H"
    shim = '''
/* --- compat shim: pershoot/dev-susfs's driver calls these functions,
 * which don't exist in susfs4ksu 2.1.0. Mirrors the existing
 * susfs_is_current_proc_umounted pattern above using dedicated, unused
 * TIF bits. --- */
#define TIF_PROC_NO_SU 34
#define TIF_PROC_UMOUNTED_FOR_ZYGOTE_NEXT 35

static inline bool susfs_is_current_proc_no_su(void) {
\treturn test_ti_thread_flag(&current->thread_info, TIF_PROC_NO_SU);
}

static inline void susfs_set_current_proc_no_su(void) {
\tset_ti_thread_flag(&current->thread_info, TIF_PROC_NO_SU);
}

static inline bool susfs_is_current_proc_umounted_for_zygote_next(void) {
\treturn test_ti_thread_flag(&current->thread_info, TIF_PROC_UMOUNTED_FOR_ZYGOTE_NEXT);
}

static inline void susfs_set_current_proc_umounted_for_zygote_next(void) {
\tset_ti_thread_flag(&current->thread_info, TIF_PROC_UMOUNTED_FOR_ZYGOTE_NEXT);
}

'''
    if marker not in content:
        raise SystemExit("susfs_def.h: expected marker not found, refusing to patch blindly")
    content = content.replace(marker, shim + marker, 1)
    with open(path, "w") as f:
        f.write(content)
    print("Patched include/linux/susfs_def.h with no_su + zygote_next compat shim")
else:
    print("include/linux/susfs_def.h already has the compat shim, skipping")
PYEOF
if [ $? -ne 0 ]; then
  echo "!!! BUILD ABORTED: failed to patch include/linux/susfs_def.h with the compat shim."
  exit 1
fi

# --- Compat shim #3: drivers/kernelsu/infra/file_wrapper.c (a "proxy file"
# subsystem used for pts/file hiding, unconditionally compiled — no Kconfig
# gate) uses struct file_operations members iopoll/remap_file_range and the
# REMAP_FILE_DEDUP flag. These are real upstream Linux VFS additions (5.3+
# for the unified remap_file_range; this file has used iopoll since its
# introduction in Nov 2025), not SUSFS-specific — this 4.19 tree's
# include/linux/fs.h genuinely doesn't have them (confirmed: only the older
# split clone_file_range/dedupe_file_range exist here, and no iopoll member
# at all). No SUSFS kernel-patch version could add real upstream VFS struct
# fields to an old kernel tree, so this isn't fixable by bumping susfs4ksu —
# it has to be handled in the driver code itself.
#
# Fix: detect at build time (by actually parsing this kernel's own
# include/linux/fs.h, not by guessing a LINUX_VERSION_CODE threshold that
# vendor kernels routinely diverge from) whether these fields exist, and
# only compile the driver's use of them if they do. Where they don't, the
# corresponding p->ops.* fields are simply left unset — p is allocated with
# kcalloc (verified), so they default to NULL exactly as if the field were
# assigned NULL explicitly. This preserves every other bit of dev-susfs's
# newer functionality (no_su, zygote_next, SUSFS 2.1.0+ features) instead of
# rolling back to a pre-Nov-2025 snapshot, which would also lose those.
python3 - << 'PYEOF'
import re

path_fops_src = "include/linux/fs.h"
path_target = "drivers/kernelsu/infra/file_wrapper.c"

with open(path_fops_src) as f:
    fs_h = f.read()
m = re.search(r'struct file_operations \{(.*?)\n\};', fs_h, re.S)
if not m:
    raise SystemExit("could not locate struct file_operations in include/linux/fs.h")
fops_body = m.group(1)
has_iopoll = "iopoll" in fops_body
has_remap = "remap_file_range" in fops_body
print(f"file_wrapper.c compat: has_iopoll={has_iopoll} has_remap_file_range={has_remap}")

with open(path_target) as f:
    content = f.read()

if "struct file_operations on this kernel" in content:
    print("file_wrapper.c already patched, skipping")
else:
    iopoll_block = '''#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 1, 0)
static int ksu_wrapper_iopoll(struct kiocb *kiocb, struct io_comp_batch *icb,
                              unsigned int v)
{
    struct ksu_file_wrapper *data = kiocb->ki_filp->private_data;
    struct file *orig = data->orig;
    kiocb->ki_filp = orig;
    return orig->f_op->iopoll(kiocb, icb, v);
}
#else
static int ksu_wrapper_iopoll(struct kiocb *kiocb, bool spin)
{
    struct ksu_file_wrapper *data = kiocb->ki_filp->private_data;
    struct file *orig = data->orig;
    kiocb->ki_filp = orig;
    return orig->f_op->iopoll(kiocb, spin);
}
#endif'''
    if iopoll_block not in content:
        raise SystemExit("file_wrapper.c: iopoll function block not found verbatim, refusing to patch blindly")
    if not has_iopoll:
        content = content.replace(
            iopoll_block,
            "#if 0 /* struct file_operations on this kernel has no iopoll member */\n"
            + iopoll_block + "\n#endif",
            1,
        )

    iopoll_assign = "    p->ops.iopoll = fp->f_op->iopoll ? ksu_wrapper_iopoll : NULL;"
    if iopoll_assign not in content:
        raise SystemExit("file_wrapper.c: iopoll assignment line not found verbatim, refusing to patch blindly")
    if not has_iopoll:
        content = content.replace(
            iopoll_assign,
            "    /* iopoll not present on this kernel's file_operations */",
            1,
        )

    remap_block = '''// no REMAP_FILE_DEDUP: use file_in
// https://cs.android.com/android/kernel/superproject/+/common-android-mainline:common/fs/read_write.c;l=1598-1599;drc=398da7defe218d3e51b0f3bdff75147e28125b60
// https://cs.android.com/android/kernel/superproject/+/common-android-mainline:common/fs/remap_range.c;l=403-404;drc=398da7defe218d3e51b0f3bdff75147e28125b60
// REMAP_FILE_DEDUP: use file_out
// https://cs.android.com/android/kernel/superproject/+/common-android-mainline:common/fs/remap_range.c;l=483-484;drc=398da7defe218d3e51b0f3bdff75147e28125b60
static loff_t ksu_wrapper_remap_file_range(struct file *file_in, loff_t pos_in,
                                           struct file *file_out,
                                           loff_t pos_out, loff_t len,
                                           unsigned int remap_flags)
{
    if (remap_flags & REMAP_FILE_DEDUP) {
        struct ksu_file_wrapper *data = file_out->private_data;
        struct file *orig = data->orig;
        return orig->f_op->remap_file_range(file_in, pos_in, orig, pos_out, len,
                                            remap_flags);
    } else {
        struct ksu_file_wrapper *data = file_in->private_data;
        struct file *orig = data->orig;
        return orig->f_op->remap_file_range(orig, pos_in, file_out, pos_out,
                                            len, remap_flags);
    }
}'''
    if remap_block not in content:
        raise SystemExit("file_wrapper.c: remap_file_range function block not found verbatim, refusing to patch blindly")
    if not has_remap:
        content = content.replace(
            remap_block,
            "#if 0 /* struct file_operations on this kernel has no remap_file_range member */\n"
            + remap_block + "\n#endif",
            1,
        )

    remap_assign = """    p->ops.remap_file_range =
        fp->f_op->remap_file_range ? ksu_wrapper_remap_file_range : NULL;"""
    if remap_assign not in content:
        raise SystemExit("file_wrapper.c: remap_file_range assignment lines not found verbatim, refusing to patch blindly")
    if not has_remap:
        content = content.replace(
            remap_assign,
            "    /* remap_file_range not present on this kernel's file_operations */",
            1,
        )

    with open(path_target, "w") as f:
        f.write(content)
    print("Patched drivers/kernelsu/infra/file_wrapper.c for this kernel's actual file_operations layout")
PYEOF
if [ $? -ne 0 ]; then
  echo "!!! BUILD ABORTED: failed to patch drivers/kernelsu/infra/file_wrapper.c."
  exit 1
fi

# --- Compat shim #4: drivers/kernelsu/infra/seccomp_cache.c locally
# redefines the KERNEL-INTERNAL (not publicly exposed) "struct
# seccomp_filter" to reach into a "cache" bitmap field for a seccomp
# fast-path optimization added upstream around Linux 5.11+. Verified against
# this kernel's own kernel/seccomp.c: the REAL internal struct here has only
# 4 fields (usage, log, prev, prog) — no cache field at all. The driver's
# local shadow copy has 10 fields including one this kernel's real struct
# doesn't have. Patching just the missing SECCOMP_ARCH_NATIVE_NR constant to
# make this compile would NOT make it correct — ksu_seccomp_clear_cache/
# ksu_seccomp_allow_cache would read/write memory at an offset that doesn't
# correspond to any real field in this kernel's actual struct, i.e. silent
# memory corruption if ever called.
# Verified (grepped the entire dev-susfs kernel/ tree): NOTHING calls either
# function anywhere in this driver — they're declared in seccomp_cache.h for
# a companion kernel-side patch to call, which our SUSFS 2.1.0 kernel
# patches don't include. So this is genuinely dead code in our build as-is.
# The safe fix is to exclude the file from compilation entirely (equivalent
# to what already happens at runtime — never reached) rather than fabricate
# a fake definition of SECCOMP_ARCH_NATIVE_NR that would make broken code
# merely compile instead of correctly never-execute.
python3 - << 'PYEOF'
import re

with open("include/linux/seccomp.h") as f:
    seccomp_h = f.read()
has_arch_native_nr = "SECCOMP_ARCH_NATIVE_NR" in seccomp_h
print(f"seccomp_cache.c compat: has_SECCOMP_ARCH_NATIVE_NR={has_arch_native_nr}")

if not has_arch_native_nr:
    kbuild_path = "drivers/kernelsu/Kbuild"
    with open(kbuild_path) as f:
        content = f.read()
    line = "kernelsu-objs += infra/seccomp_cache.o"
    if line not in content:
        raise SystemExit("drivers/kernelsu/Kbuild: expected seccomp_cache.o line not found verbatim, refusing to patch blindly")
    if "# excluded: no SECCOMP_ARCH_NATIVE_NR" not in content:
        content = content.replace(
            line,
            "# excluded: no SECCOMP_ARCH_NATIVE_NR on this kernel, and nothing calls\n"
            "# ksu_seccomp_clear_cache/ksu_seccomp_allow_cache anywhere in this driver\n"
            "# tree, so this file is dead code here — see build script for full reasoning\n"
            "# kernelsu-objs += infra/seccomp_cache.o",
            1,
        )
        with open(kbuild_path, "w") as f:
            f.write(content)
        print("Excluded infra/seccomp_cache.o from drivers/kernelsu/Kbuild")
    else:
        print("infra/seccomp_cache.o already excluded, skipping")
else:
    print("This kernel has SECCOMP_ARCH_NATIVE_NR — leaving seccomp_cache.o in the build as-is")
PYEOF
if [ $? -ne 0 ]; then
  echo "!!! BUILD ABORTED: failed to patch drivers/kernelsu/Kbuild to exclude infra/seccomp_cache.o."
  exit 1
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
