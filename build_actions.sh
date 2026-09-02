#!/bin/bash
# curl -o build_kernel.sh -L https://raw.githubusercontent.com/Joe7500/valeryn_xiaomi_sm6115/refs/heads/build-actions/build_actions.sh
set -x
# Setup
curl -o build_ksun3.sh -L https://raw.githubusercontent.com/danish3311/valeryn_xiaomi_sm6115/refs/heads/build-actions/build_ksun3.sh || exit 1
mkdir build
cd build
rm -rf kernel
git clone --depth 20 --no-single-branch https://github.com/danish3311/valeryn_xiaomi_sm6115 kernel
cd kernel || exit 1
KERNEL_BUILD_DIR=`pwd`
cd ../../
ln -s "$KERNEL_BUILD_DIR"/.git .git
cd build/kernel || exit 1
git config user.email "user@localhost"
git config user.name "user"
# ksun3
rm -rf *
git reset --hard
git switch android16
git switch -c build-ksun3 || exit 1
# Restore MGLRU support (re-adds what "mm: remove MGLRU" took out, then
# reapplies the two follow-up commits from the mglru branch on top).
# Verified clean against this fork's full history: applies with zero
# conflicts in this exact order.
git cherry-pick 8b266fd430de31b1cd49049f9a7543516b223a6d || exit
git revert d0d19501b373a540fbd56551b430619e2d67b5a8 --no-edit || exit
git cherry-pick d749fbbfb5e51e845e3ed227de64eba4ad80f861 || exit
bash ../../build_ksun3.sh
if [ $? -eq 0 ] ; then
   # build_ksun3.sh names its own zip using the real, dynamically resolved
   # KernelSU-Next version tag, so we just copy it as-is.
   cp 4.19*.zip ../../
else
   echo FAILED
   exit 1
fi
exit 0
