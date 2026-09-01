#!/bin/bash
# curl -o build_kernel.sh -L https://raw.githubusercontent.com/Joe7500/valeryn_xiaomi_sm6115/refs/heads/build-actions/build_actions.sh

set -x

# Setup
curl -o build_ksun3.sh -L https://raw.githubusercontent.com/Joe7500/valeryn_xiaomi_sm6115/refs/heads/build-actions/build_ksun3.sh || exit 1

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

# vanilla
rm -rf *
git reset --hard
git switch android16
git switch -c build-vanilla || exit 1
bash  ../../build_vanilla.sh 
if [ $? -eq 0 ] ; then
   cp 4.19*.zip ../../4.19-A16-valeryn-`date +'%d.%m.%y-%H%M'`.zip
else
   echo FAILED
   exit 1
fi

# ksun1
rm -rf *
git reset --hard
git switch android16
git switch -c build-ksun1 || exit 1
bash ../../build_ksun1.sh
if [ $? -eq 0 ] ; then
   cp 4.19*.zip ../../4.19-A16-valeryn-ksun-1.1.1-`date +'%d.%m.%y-%H%M'`.zip
   cp kernel-prebuilt*.tar.xz ../../
else
   echo FAILED
   exit 1
fi

# ksun3
rm -rf *
git reset --hard
git switch android16
git switch -c build-ksun3 || exit 1
bash ../../build_ksun3.sh
if [ $? -eq 0 ] ; then
   # CHANGED: build_ksun3.sh now names its own zip using the real, dynamically
   # resolved KernelSU-Next version tag (e.g. "ksun-v3.3.0-..."), so we just
   # copy it as-is instead of re-copying under a hardcoded "ksun-3.2.0" name
   # that would now be stale/misleading.
   cp 4.19*.zip ../../
else
   echo FAILED
   exit 1
fi

exit 0
