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

# --- Compat shim #5: drivers/kernelsu/manager/pkg_observer.c hardcodes the
# 5.9+ struct fsnotify_ops field (.handle_inode_event) and function
# signature (mark, mask, inode, dir, const struct qstr *file_name, cookie).
# This kernel's real struct fsnotify_ops (verified against
# include/linux/fsnotify_backend.h) only has the older field
# (.handle_event), with the pre-5.2 signature (group, inode, mask, data,
# data_type, const unsigned char *file_name, cookie, iter_info).
#
# Unlike the earlier shims, this one isn't a fabricated fix — it's restoring
# code that used to exist. The working KernelSU-Next-susfs-3.2.0 source (the
# tarball this whole build used to be based on, from the now-deleted
# pershoot legacy-susfs branch) shipped a small header,
# kernel/manager/pkg_observer_defs.h, with a KSU_DECL_FSNOTIFY_OPS(name)
# macro that expands to the correct signature for FIVE different kernel-
# version brackets (pre-4.12, 4.12–4.18, 4.18–5.2, 5.2–5.9, 5.9+), plus
# ksu_fname_len()/ksu_fname_arg() helper macros so the same function BODY
# works across all of them. dev-susfs deleted this file entirely and kept
# only the 5.9+ branch's signature, unconditionally.
# Fix: restore that original file verbatim, and restore pkg_observer.c's use
# of it (also matching the 3.2.0 source, adapted to dev-susfs's current
# variable names — functionally identical logic either way: detect
# "packages.list" in /data/system and call track_throne(false)).
python3 - << 'PYEOF'
path_defs = "drivers/kernelsu/manager/pkg_observer_defs.h"
path_target = "drivers/kernelsu/manager/pkg_observer.c"

defs_content = '''// This header should not be used outside of pkg_observer.c!

#include <linux/version.h>

#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 2, 0)
typedef const struct qstr *ksu_fname_t;
#define ksu_fname_len(f) ((f)->len)
#define ksu_fname_arg(f) ((f)->name)
#else
typedef const unsigned char *ksu_fname_t;
#define ksu_fname_len(f) (strlen(f))
#define ksu_fname_arg(f) (f)
#endif

#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0)
#define KSU_DECL_FSNOTIFY_OPS(name)                                            \\
\tint name(struct fsnotify_mark *mark, u32 mask, struct inode *inode,    \\
\t\t struct inode *dir, const struct qstr *file_name, u32 cookie)
#elif LINUX_VERSION_CODE >= KERNEL_VERSION(5, 2, 0)
#define KSU_DECL_FSNOTIFY_OPS(name)                                            \\
\tint name(struct fsnotify_group *group, struct inode *inode, u32 mask,  \\
\t\t const void *data, int data_type, ksu_fname_t file_name,       \\
\t\t u32 cookie, struct fsnotify_iter_info *iter_info)
#elif LINUX_VERSION_CODE >= KERNEL_VERSION(4, 18, 0)
#define KSU_DECL_FSNOTIFY_OPS(name)                                            \\
\tint name(struct fsnotify_group *group, struct inode *inode, u32 mask,  \\
\t\t const void *data, int data_type, ksu_fname_t file_name,       \\
\t\t u32 cookie, struct fsnotify_iter_info *iter_info)
#elif LINUX_VERSION_CODE >= KERNEL_VERSION(4, 12, 0)
#define KSU_DECL_FSNOTIFY_OPS(name)                                            \\
\tint name(struct fsnotify_group *group, struct inode *inode,            \\
\t\t struct fsnotify_mark *inode_mark,                             \\
\t\t struct fsnotify_mark *vfsmount_mark, u32 mask,                \\
\t\t const void *data, int data_type, ksu_fname_t file_name,       \\
\t\t u32 cookie, struct fsnotify_iter_info *iter_info)
#else
#define KSU_DECL_FSNOTIFY_OPS(name)                                            \\
\tint name(struct fsnotify_group *group, struct inode *inode,            \\
\t\t struct fsnotify_mark *inode_mark,                             \\
\t\t struct fsnotify_mark *vfsmount_mark, u32 mask, void *data,    \\
\t\t int data_type, ksu_fname_t file_name, u32 cookie)
#endif
'''

with open(path_defs, "w") as f:
    f.write(defs_content)
print("Restored drivers/kernelsu/manager/pkg_observer_defs.h")

with open(path_target) as f:
    content = f.read()

if "KSU_DECL_FSNOTIFY_OPS" in content:
    print("pkg_observer.c already patched, skipping")
else:
    old_block = '''static int ksu_handle_inode_event(struct fsnotify_mark *mark, u32 mask,
                                  struct inode *inode, struct inode *dir,
                                  const struct qstr *file_name, u32 cookie)
{
    if (!file_name)
        return 0;
    if (mask & FS_ISDIR)
        return 0;
    if (file_name->len == 13 && !memcmp(file_name->name, "packages.list", 13)) {
        pr_info("packages.list detected: %d\\n", mask);
        track_throne(false);
    }
    return 0;
}

static const struct fsnotify_ops ksu_ops = {
\t.handle_inode_event = ksu_handle_inode_event,
};'''
    if old_block not in content:
        raise SystemExit("pkg_observer.c: expected verbatim block not found, refusing to patch blindly")

    new_block = '''#include "pkg_observer_defs.h" // KSU_DECL_FSNOTIFY_OPS
static KSU_DECL_FSNOTIFY_OPS(ksu_handle_inode_event)
{
    if (!file_name)
        return 0;
    if (mask & FS_ISDIR)
        return 0;
    if (ksu_fname_len(file_name) == 13 &&
        !memcmp(ksu_fname_arg(file_name), "packages.list", 13)) {
        pr_info("packages.list detected: %d\\n", mask);
        track_throne(false);
    }
    return 0;
}

static const struct fsnotify_ops ksu_ops = {
#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0)
\t.handle_inode_event = ksu_handle_inode_event,
#else
\t.handle_event = ksu_handle_inode_event,
#endif
};'''
    content = content.replace(old_block, new_block, 1)
    with open(path_target, "w") as f:
        f.write(content)
    print("Patched drivers/kernelsu/manager/pkg_observer.c to use KSU_DECL_FSNOTIFY_OPS")
PYEOF
if [ $? -ne 0 ]; then
  echo "!!! BUILD ABORTED: failed to patch pkg_observer.c / pkg_observer_defs.h."
  exit 1
fi

# --- Compat shim #6: drivers/kernelsu/policy/allowlist.c's
# ksu_persistent_allow_list() is genuinely new functionality — verified it
# doesn't exist anywhere in the working KernelSU-Next-susfs-3.2.0 source at
# all, so this isn't a signature drift like the others, it's a feature added
# since. It hits two separate gaps on this kernel:
#   1. TWA_RESUME (enum task_work_notify_mode) doesn't exist here.
#      task_work_add()'s third parameter changed from a plain bool to this
#      enum around Linux 5.8/5.9 — verified this kernel's task_work.h still
#      declares it as bool. true is the exact semantic equivalent of
#      TWA_RESUME (schedule the work via TIF_NOTIFY_RESUME on return to
#      userspace), so #define TWA_RESUME true is a real fix, not a stub.
#   2. put_task_struct — implicit-declaration error, but verified this
#      function genuinely exists in this kernel
#      (include/linux/sched/task.h, as a static inline) — allowlist.c just
#      never includes that header. Adding the include is the actual fix,
#      not a workaround.
python3 - << 'PYEOF'
path = "drivers/kernelsu/policy/allowlist.c"
with open(path) as f:
    content = f.read()

if "TWA_RESUME true" in content:
    print("allowlist.c already patched, skipping")
else:
    anchor = "#include <linux/kref.h>"
    if content.count(anchor) != 1:
        raise SystemExit(f"allowlist.c: expected exactly one match for anchor include, found {content.count(anchor)}, refusing to patch blindly")
    addition = anchor + '''
#include <linux/sched/task.h> /* put_task_struct — not always transitively
                                  included on older kernels */

#ifndef TWA_RESUME
/* TWA_RESUME (enum task_work_notify_mode) was introduced when
 * task_work_add()'s third parameter changed from bool to that enum
 * (~5.8/5.9). This kernel's task_work_add() still takes a plain bool, where
 * true is the exact equivalent of TWA_RESUME (schedule via
 * TIF_NOTIFY_RESUME on return to userspace). */
#define TWA_RESUME true
#endif'''
    content = content.replace(anchor, addition, 1)
    with open(path, "w") as f:
        f.write(content)
    print("Patched drivers/kernelsu/policy/allowlist.c with TWA_RESUME + put_task_struct include")
PYEOF
if [ $? -ne 0 ]; then
  echo "!!! BUILD ABORTED: failed to patch drivers/kernelsu/policy/allowlist.c."
  exit 1
fi


# --- Compat shim #7: this is the largest fix in the chain so far, and
# touches core SELinux policy manipulation, so it's worth explaining fully.
#
# security/selinux/rules.c error: "no member named 'policy' in
# 'struct selinux_state'" / "no member named 'policy_mutex'" / "incomplete
# definition of type 'struct selinux_policy'".
#
# Root cause: SELinux upstream restructured how policy is stored around
# Linux 5.10+ — from a single mutable policydb protected by a rwlock, to an
# RCU-swappable "struct selinux_policy" the kernel dup-and-swaps atomically.
# dev-susfs's rules.c unconditionally assumes the NEW model
# (#define SELINUX_POLICY_INSTEAD_SELINUX_SS with no version guard at all).
# The working KernelSU-Next-susfs-3.2.0 source (pershoot legacy-susfs,
# now deleted upstream) supported BOTH models via
# "#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)" — dev-susfs dropped
# the old branch entirely.
#
# Verified directly against this kernel's real security/selinux headers
# (not assumed): struct selinux_state here has .ss and .avc (the "middle
# era" layout, confirmed present), struct selinux_ss has .policydb and
# .policy_rwlock directly, and struct selinux_policy does not exist
# anywhere in this kernel's SELinux source at all. Also ran the actual
# KSU_COMPAT_* detection greps (restored below, verbatim from 3.2.0's own
# Kbuild) against this kernel to confirm exactly which branch applies here.
#
# Fix restores: (1) the version-conditional SELINUX_POLICY_INSTEAD_SELINUX_SS
# guard, (2) get_policydb()/ksu_get_policy_rwlock()/ksu_get_current_cpumask_t()
# for the pre-5.10 path, (3) apply_kernelsu_rules() and handle_sepolicy()
# both split into old (rwlock + stop_machine fallback) and new (RCU
# dup-and-swap) implementations — using dev-susfs's CURRENT, up-to-date
# SELinux rule set for both paths (not 3.2.0's older one), so this kernel
# gets the same rules a modern kernel would, just applied via a
# version-appropriate safe-locking mechanism.
#
# This also transitively fixes a second, related error further into the
# build: feature/selinux_hide.c depends on struct selinux_policy directly
# (verified: genuinely new functionality, no equivalent in 3.2.0 at all,
# and cannot be backported without pulling in real kernel-core SELinux
# internals, well out of scope for a driver-side compat shim). It has three
# external callers (core/init.c, runtime/boot_event.c,
# runtime/ksud_integration.c) expecting five small void functions, so it's
# replaced with a no-op stub implementing exactly that API rather than
# excluded from the build (which would leave those callers with undefined
# references). Every other SUSFS/root feature is unaffected — only this one
# optional hiding subsystem is disabled on kernels this old.
python3 - << 'PYEOF'
import re

# ============================================================
# Part A: Kbuild compat-macro detection (restored from the working
# KernelSU-Next-susfs-3.2.0 source). These control which branch rules.c's
# restored pre-5.10 code takes.
# ============================================================
kbuild_path = "drivers/kernelsu/Kbuild"
with open(kbuild_path) as f:
    kbuild_content = f.read()

if "KSU_COMPAT_USE_SELINUX_STATE" not in kbuild_content:
    detection_block = '''
# --- restored from KernelSU-Next-susfs-3.2.0: detect actual SELinux
# internal struct layout on this kernel, used by the restored pre-5.10
# compat path in selinux/rules.c ---
ifeq ($(shell grep -q "current_sid(void)" $(srctree)/security/selinux/include/objsec.h; echo $$?),0)
ccflags-y += -DKSU_COMPAT_HAS_CURRENT_SID
endif
ifeq ($(shell grep -q "struct selinux_state " $(srctree)/security/selinux/include/security.h; echo $$?),0)
ccflags-y += -DKSU_COMPAT_USE_SELINUX_STATE
endif
ifeq ($(shell grep -q "^DEFINE_RWLOCK(policy_rwlock);" $(srctree)/security/selinux/ss/services.c; echo $$?),0)
ccflags-y += -DKSU_COMPAT_HAS_EXPORTED_POLICY_RWLOCK
endif
ifeq ($(shell grep -q "cpus_ptr;" $(srctree)/include/linux/sched.h; echo $$?),0)
ccflags-y += -DKSU_COMPAT_HAS_BACKPORTED_CPUS_PTR
endif
'''
    # Insert right after the very first objs line (unique, ":= " not "+=",
    # never touched by any other patch in this script — safer than
    # anchoring on "kernelsu-objs +=", which could accidentally match
    # inside the seccomp-exclusion patch's comment text if that patch runs
    # first) so ccflags-y is set before anything using it gets compiled.
    marker = "kernelsu-objs := core/init.o"
    if kbuild_content.count(marker) != 1:
        raise SystemExit(f"drivers/kernelsu/Kbuild: expected exactly one match for anchor line, found {kbuild_content.count(marker)}, refusing to patch blindly")
    kbuild_content = kbuild_content.replace(
        marker, marker + "\n" + detection_block.strip("\n"), 1
    )
    with open(kbuild_path, "w") as f:
        f.write(kbuild_content)
    print("Patched drivers/kernelsu/Kbuild with compat-macro detection")
else:
    print("Kbuild compat-macro detection already present, skipping")

# ============================================================
# Part B: selinux/rules.c — restore the pre-5.10 SELinux policy-access path
# ============================================================
rules_path = "drivers/kernelsu/selinux/rules.c"
with open(rules_path) as f:
    content = f.read()

if "#ifndef SELINUX_POLICY_INSTEAD_SELINUX_SS" in content:
    print("rules.c already patched, skipping")
else:
    # --- Step 1: conditional SELINUX_POLICY_INSTEAD_SELINUX_SS + old helpers ---
    old_header = '''struct selinux_policy *backup_sepolicy;

#define SELINUX_POLICY_INSTEAD_SELINUX_SS

#define ALL NULL'''
    if old_header not in content:
        raise SystemExit("rules.c: header block not found verbatim, refusing to patch blindly")

    new_header = '''struct selinux_policy *backup_sepolicy;

#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)
#define SELINUX_POLICY_INSTEAD_SELINUX_SS
#endif

#define ALL NULL

#ifndef SELINUX_POLICY_INSTEAD_SELINUX_SS
/* --- pre-5.10 compat path, restored from the working
 * KernelSU-Next-susfs-3.2.0 source (pershoot legacy-susfs branch, now
 * deleted upstream). dev-susfs assumes SELINUX_POLICY_INSTEAD_SELINUX_SS
 * unconditionally and dropped this branch entirely. --- */
static struct policydb *get_policydb(void)
{
\tstruct policydb *db;
#ifdef KSU_COMPAT_USE_SELINUX_STATE
\tstruct selinux_ss *ss = selinux_state.ss;
\tdb = &ss->policydb;
#else
\tdb = &policydb;
#endif
\treturn db;
}

#if defined(KSU_COMPAT_USE_SELINUX_STATE)
static inline rwlock_t *ksu_get_policy_rwlock(void) { return &selinux_state.ss->policy_rwlock; }
#elif defined(KSU_COMPAT_HAS_EXPORTED_POLICY_RWLOCK)
static inline rwlock_t *ksu_get_policy_rwlock(void) { extern rwlock_t policy_rwlock; return &policy_rwlock; }
#else
static inline rwlock_t *ksu_get_policy_rwlock(void) { return NULL; }
#endif

#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 2, 0) || defined(KSU_COMPAT_HAS_BACKPORTED_CPUS_PTR)
static inline const cpumask_t *ksu_get_current_cpumask_t(void) { return current->cpus_ptr; }
#else
static inline cpumask_t *ksu_get_current_cpumask_t(void) { return &current->cpus_allowed; }
#endif
#endif // #ifndef SELINUX_POLICY_INSTEAD_SELINUX_SS'''
    content = content.replace(old_header, new_header, 1)

    # --- Step 2: wrap apply_kernelsu_rules(), add old-path + shared helper ---
    af_start = "void apply_kernelsu_rules()"
    af_end_marker = "out_unlock:\n    mutex_unlock(&selinux_state.policy_mutex);\n}"
    af_start_idx = content.index(af_start)
    af_end_idx = content.index(af_end_marker, af_start_idx) + len(af_end_marker)
    old_fn = content[af_start_idx:af_end_idx]

    rule_start = '    ksu_type(db, KERNEL_SU_DOMAIN, "domain");'
    rule_end = '    ksu_allow(db, "kernel", "apk_data_file", "file", "open");'
    r_start = old_fn.index(rule_start)
    r_end = old_fn.index(rule_end) + len(rule_end)
    rule_body = old_fn[r_start:r_end]
    rule_body_tabbed = "\n".join(
        ("\t" + l[4:]) if l.startswith("    ") else l for l in rule_body.split("\n")
    )

    new_fn = ('#ifdef SELINUX_POLICY_INSTEAD_SELINUX_SS\n' + old_fn + '''
#else

static int apply_kernelsu_rules_fn(void *ptr)
{
\tstruct policydb *db = (struct policydb *)ptr;

''' + rule_body_tabbed + '''

\treturn 0;
}

void apply_kernelsu_rules()
{
\tstruct policydb *db;
\tcpumask_t old_mask;

\tif (!getenforce()) {
\t\tpr_info("SELinux permissive or disabled, apply rules!\\n");
\t}

\tdb = get_policydb();
\trwlock_t *lock = ksu_get_policy_rwlock();

\tif (!lock)
\t\tgoto do_stop_machine;

\t/*
\t * HACK: write_lock() is held with preempt enabled. DO NOT let the
\t * task be migrated to any other CPU than the current CPU. And since
\t * set_cpus_allowed_ptr() can sleep, use raw_smp_processor_id() to get
\t * current CPU and bypass preemption checks.
\t */
\tcpumask_copy(&old_mask, ksu_get_current_cpumask_t());
\tset_cpus_allowed_ptr(current, cpumask_of(raw_smp_processor_id()));

\twrite_lock(lock);
\tpreempt_enable();

\t// we do this dance since both kernel and userspace can trigger this
\tif (likely(current && current->mm))
\t\tgoto has_current_mm;

\tapply_kernelsu_rules_fn((void *)db);
\tgoto out_unlock;

has_current_mm:
\t;

\t// HACK: raise priority of this to the heavens
\tint old_policy = current->policy;
\tstruct sched_param old_param = { .sched_priority = current->rt_priority };
\tstruct sched_param new_param = { .sched_priority = 50 };

\tsched_setscheduler_nocheck(current, 1, &new_param); // raise, fifo, 50
\tapply_kernelsu_rules_fn((void *)db);
\tsched_setscheduler_nocheck(current, old_policy, &old_param); // restore

out_unlock:
\tpreempt_disable();
\twrite_unlock(lock);
\tset_cpus_allowed_ptr(current, &old_mask);
\tgoto out_flush;

do_stop_machine:
\tstop_machine(apply_kernelsu_rules_fn, (void *)db, NULL);

out_flush:
\tsmp_mb();
\treset_avc_cache();
}
#endif // SELINUX_POLICY_INSTEAD_SELINUX_SS''')
    content = content.replace(old_fn, new_fn, 1)

    # --- Step 3: wrap handle_sepolicy(), add old-path + shared helper ---
    hs_start = "int handle_sepolicy(void __user *user_data, u64 data_len)"
    hs_start_idx = content.rindex(hs_start)
    hs_end_marker = "kvfree(payload);\n\n    return ret;\n}"
    hs_end_idx = content.index(hs_end_marker, hs_start_idx) + len(hs_end_marker)
    old_hs = content[hs_start_idx:hs_end_idx]

    new_hs = ('#ifdef SELINUX_POLICY_INSTEAD_SELINUX_SS\n' + old_hs + '''
#else

struct handle_sepolicy_args {
\tvoid *ctx_success_cmd_count;
\tvoid *ctx_payload;
\tu64 ctx_data_len;
};

static int handle_sepolicy_fn(void *data)
{
\tstruct sepol_batch_cursor cursor;
\tint ret = 0;
\tu32 cmd_index = 0;
\tint success_cmd_count = 0;

\tstruct policydb *db = get_policydb();
\tstruct handle_sepolicy_args *ctx = (struct handle_sepolicy_args *)data;
\tu8 *payload = (u8 *)ctx->ctx_payload;
\tu64 data_len = ctx->ctx_data_len;

\tcursor.cur = payload;
\tcursor.end = payload + (size_t)data_len;

\twhile (cursor.cur < cursor.end) {
\t\tstruct sepol_data header;
\t\tconst char *args[KSU_SEPOLICY_MAX_ARGS] = { 0 };
\t\tint expected_argc;
\t\tu32 arg_index;

\t\tret = sepol_read_cmd_header(&cursor, &header);
\t\tif (ret < 0) {
\t\t\tpr_err("sepol: failed to read cmd header #%u.\\n", cmd_index);
\t\t\tgoto out;
\t\t}

\t\texpected_argc = sepol_expected_argc(header.cmd);
\t\tif (expected_argc < 0 || expected_argc > KSU_SEPOLICY_MAX_ARGS) {
\t\t\tret = -EINVAL;
\t\t\tpr_err("sepol: invalid cmd header #%u.\\n", cmd_index);
\t\t\tgoto out;
\t\t}

\t\tfor (arg_index = 0; arg_index < (u32)expected_argc; arg_index++) {
\t\t\tret = sepol_read_string(&cursor, &args[arg_index]);
\t\t\tif (ret < 0) {
\t\t\t\tpr_err("sepol: failed to read cmd #%u arg #%u.\\n", cmd_index, arg_index);
\t\t\t\tgoto out;
\t\t\t}
\t\t}

\t\tret = apply_one_sepolicy_cmd(db, &header, args);
\t\tif (ret < 0)
\t\t\tpr_err("sepol: cmd #%u failed, cmd=%u subcmd=%u.\\n", cmd_index, header.cmd, header.subcmd);
\t\telse {
\t\t\tsuccess_cmd_count++;
\t\t}

\t\tcmd_index++;
\t}

out:
\t*(int *)(ctx->ctx_success_cmd_count) = success_cmd_count;
\treturn ret;
}

int handle_sepolicy(void __user *user_data, u64 data_len)
{
\tu8 *payload;
\tint ret = 0;
\tint success_cmd_count = 0;
\tcpumask_t old_mask;

\tif (!user_data || !data_len)
\t\treturn -EINVAL;

\tif (data_len > KSU_SEPOLICY_MAX_BATCH_SIZE)
\t\treturn -E2BIG;

\tpayload = kvmalloc((size_t)data_len, GFP_KERNEL);
\tif (!payload)
\t\treturn -ENOMEM;

\tif (copy_from_user(payload, user_data, (size_t)data_len)) {
\t\tret = -EFAULT;
\t\tgoto out_free;
\t}

\tif (!getenforce()) {
\t\tpr_info("SELinux permissive or disabled when handle policy!\\n");
\t}

\tstruct handle_sepolicy_args ctx = { 0 };
\tctx.ctx_success_cmd_count = (void *)&success_cmd_count;
\tctx.ctx_payload = (void *)payload;
\tctx.ctx_data_len = (u64)data_len;

\trwlock_t *lock = ksu_get_policy_rwlock();
\tif (!lock)
\t\tgoto do_stop_machine;

\t/*
\t * HACK: write_lock() is held with preempt enabled. DO NOT let the
\t * task be migrated to any other CPU than the current CPU. And since
\t * set_cpus_allowed_ptr() can sleep, use raw_smp_processor_id() to get
\t * current CPU and bypass preemption checks.
\t */
\tcpumask_copy(&old_mask, ksu_get_current_cpumask_t());
\tset_cpus_allowed_ptr(current, cpumask_of(raw_smp_processor_id()));

\twrite_lock(lock);
\tpreempt_enable();

\tif (likely(current && current->mm))
\t\tgoto has_current_mm;

\tret = handle_sepolicy_fn((void *)&ctx);
\tgoto out_unlock;

has_current_mm:
\t;

\tint old_policy = current->policy;
\tstruct sched_param old_param = { .sched_priority = current->rt_priority };
\tstruct sched_param new_param = { .sched_priority = 50 };

\tsched_setscheduler_nocheck(current, 1, &new_param);
\tret = handle_sepolicy_fn((void *)&ctx);
\tsched_setscheduler_nocheck(current, old_policy, &old_param);

out_unlock:
\tpreempt_disable();
\twrite_unlock(lock);
\tset_cpus_allowed_ptr(current, &old_mask);
\tgoto out_done;

do_stop_machine:
\tret = stop_machine(handle_sepolicy_fn, (void *)&ctx, NULL);

out_done:
\tif (ret)
\t\tgoto out_free;

\tsmp_mb();
\treset_avc_cache();
\tret = success_cmd_count;

out_free:
\tkvfree(payload);

\treturn ret;
}
#endif // SELINUX_POLICY_INSTEAD_SELINUX_SS''')
    content = content.replace(old_hs, new_hs, 1)

    with open(rules_path, "w") as f:
        f.write(content)
    print("Patched drivers/kernelsu/selinux/rules.c with restored pre-5.10 compat path")

# ============================================================
# Part C: feature/selinux_hide.c — depends on struct selinux_policy, a real
# kernel-internal type from the ~5.19+ SELinux RCU-policy refactor that does
# not exist at all in this kernel's actual SELinux source (verified: zero
# matches for "struct selinux_policy" anywhere under security/selinux/).
# Making this compile correctly would require backporting real kernel-core
# SELinux internals, not something a driver-side compat shim can fix. Since
# it's a genuinely new feature (no equivalent in the working 3.2.0 source at
# all) with three external callers, stub its small public API instead of
# excluding the object (which would leave those callers with undefined
# references).
# ============================================================
security_h_path = "security/selinux/include/security.h"
with open(security_h_path) as f:
    security_h = f.read()
has_selinux_policy = bool(re.search(r'struct selinux_policy\b', security_h)) or bool(
    re.search(r'struct selinux_policy\b', open("security/selinux/ss/services.h").read())
    if __import__("os").path.exists("security/selinux/ss/services.h") else False
)
print(f"selinux_hide.c compat: has_struct_selinux_policy={has_selinux_policy}")

if not has_selinux_policy:
    sh_path = "drivers/kernelsu/feature/selinux_hide.c"
    stub_content = '''// SPDX-License-Identifier: GPL-2.0
/*
 * Stub for this kernel: selinux_hide's process/domain hiding depends on
 * struct selinux_policy, a real kernel-internal SELinux type from the
 * ~5.19+ RCU-policy refactor. It does not exist on this kernel at all
 * (verified against security/selinux/ — no definition anywhere), so the
 * real implementation cannot compile here. This is genuinely new
 * functionality with no equivalent in the working KernelSU-Next-susfs-3.2.0
 * source this build was originally based on. No-op instead of failing to
 * build; every other SUSFS/root feature is unaffected.
 */
#include <linux/types.h>

bool ksu_selinux_hide_running = false;
bool ksu_selinux_hide_enabled = false;

void ksu_selinux_hide_init(void) {}
void ksu_selinux_hide_exit(void) {}
void ksu_selinux_hide_drop_backup_if_unused(void) {}
void ksu_selinux_hide_handle_second_stage(void) {}
void ksu_selinux_hide_handle_post_fs_data(void) {}
'''
    with open(sh_path) as f:
        current_sh = f.read()
    if current_sh.strip() != stub_content.strip():
        with open(sh_path, "w") as f:
            f.write(stub_content)
        print("Replaced drivers/kernelsu/feature/selinux_hide.c with a no-op stub")
    else:
        print("selinux_hide.c already stubbed, skipping")
else:
    print("This kernel has struct selinux_policy — leaving selinux_hide.c as-is")

PYEOF
if [ $? -ne 0 ]; then
  echo "!!! BUILD ABORTED: failed to patch selinux/rules.c, Kbuild, or feature/selinux_hide.c."
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
