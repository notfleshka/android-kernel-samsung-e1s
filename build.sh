#!/bin/bash

# SPDX-License-Identifier: GPL-3.0
#
# Kernel build script for Samsung Galaxy S24 (Exynos)
#
# Based on dx4m buildscript
# Modified by notfleshka

CURRENT_DIR="$(KERNEL_DIR)"
KERNELBUILD="${CURRENT_DIR}"

BUILDCHAIN="${KERNELBUILD}/buildchain"
TOOLS="${KERNELBUILD}/tools"
PREBUILTS="${KERNELBUILD}/prebuilts"
EXTERNAL="${KERNELBUILD}/external"
BUILD="${KERNELBUILD}/build"

KERNEL_DIR="${pwd}"
OUTPUT_DIR="${CURRENT_DIR}/out"

MENUCONFIG=false
PRINTHELP=false
CLEAN=false
CONFIG=false
SETVERSION=""
LOCALVERSION=""
BUILDUSER=""
BUILDHOST=""

VERSION="-android14-11"
TARGETSOC="s5e9945"

set -e

function getBuildtools() {
    echo "[💠] Getting the buildchain..."
    mkdir -p "$BUILDCHAIN" && cd "$BUILDCHAIN" || return 1

    repo init -u https://android.googlesource.com/kernel/manifest -b common-android14-6.1
    repo sync -c -n -j 4
    repo sync -c -l -j 16

    cd "$CURRENT_DIR"
    echo "[✅] Buildchain downloaded."
}

function movePrebuilts() {
    echo "[💠] Copying prebuilts into kernel source tree..."
    cp -r "$BUILDCHAIN/tools" "$TOOLS"
    cp -r "$BUILDCHAIN/prebuilts" "$PREBUILTS"
    cp -r "$BUILDCHAIN/external" "$EXTERNAL"
    cp -r "$BUILDCHAIN/build" "$BUILD"
    echo "[✅] Done."
}

function removeBuildchain() {
    rm -rf "$BUILDCHAIN"
	echo "[✅] Removed unnecessary buildchain folder."
}

removeBuildchain
getBuildtools
movePrebuilts

while [[ $# -gt 0 ]]; do
    case "$1" in
		menuconfig)
            MENUCONFIG=true
            shift
            ;;
		config)
            CONFIG=true
            shift
            ;;
		clean)
            CLEAN=true
            shift
            ;;
		--help)
            PRINTHELP=true
            shift
            ;;
		--version)
			shift
			SETVERSION="$1"
			shift
			;;
        *)
            OTHER_ARGS+=("$1")
            shift
            ;;
    esac
done

if [ "$PRINTHELP" = true ]; then
	echo "build_kernel.sh [COMMAND/OPTIONS]"
	echo "OPTIONS:"
	echo "	--help (Prints this message)"
	echo "	menuconfig (opens menuconfig)"
	echo "  config (Builds the .config)"
	echo "  clean (cleans the out dir)"
	exit 1
fi

if [ "$CLEAN" = true ]; then
	if [ ! -d $OUTPUT_DIR ]; then
		echo "[✅] Already clean."
		exit 1
	fi
	
	rm -rf $OUTPUT_DIR
	echo "[✅] Cleaned output."
	exit 1
fi

export PATH="${PREBUILTS}/build-tools/linux-x86/bin:${PATH}"
export PATH="${PREBUILTS}/build-tools/path/linux-x86:${PATH}"
export PATH="${PREBUILTS}/clang/host/linux-x86/clang-r510928/bin:${PATH}"
export PATH="${PREBUILTS}/kernel-build-tools/linux-x86/bin:${PATH}"

LLD_COMPILER_RT="-fuse-ld=lld --rtlib=compiler-rt"
SYSROOT_FLAGS="--sysroot=${PREBUILTS}/gcc/linux-x86/host/x86_64-linux-glibc2.17-4.8/sysroot"

CFLAGS="-I${PREBUILTS}/kernel-build-tools/linux-x86/include "
LDFLAGS="-L${PREBUILTS}/kernel-build-tools/linux-x86/lib64 ${LLD_COMPILER_RT}"

export LD_LIBRARY_PATH="${PREBUILTS}/kernel-build-tools/linux-x86/lib64"
export HOSTCFLAGS="${SYSROOT_FLAGS} ${CFLAGS}"
export HOSTLDFLAGS="${SYSROOT_FLAGS} ${LDFLAGS}"

TARGET_DEFCONFIG="${1:-e1s_defconfig}"
ARGS="CC=clang LD=ld.lld ARCH=arm64 LLVM=1 LLVM_IAS=1"
CONFIG_FILE="${OUTPUT_DIR}/.config"

if [ -f "${CONFIG_FILE}" ]; then
	TARGET_DEFCONFIG="oldconfig"
fi

if [ "$CONFIG" = true ]; then
	make -j"$(nproc)" \
     -C "${KERNEL_DIR}" \
     O="${OUTPUT_DIR}" \
     ${ARGS} \
     "${TARGET_DEFCONFIG}"
	exit 1
fi

if [ "$MENUCONFIG" = true ]; then
	make -j"$(nproc)" \
     -C "${KERNEL_DIR}" \
     O="${OUTPUT_DIR}" \
     ${ARGS} \
	"${TARGET_DEFCONFIG}" HOSTCFLAGS="${CFLAGS}" HOSTLDFLAGS="${LDFLAGS}" menuconfig
	exit 1
else
	make -j"$(nproc)" \
     -C "${KERNEL_DIR}" \
     O="${OUTPUT_DIR}" \
     ${ARGS} \
     EXTRA_CFLAGS:=" -DCFG80211_SINGLE_NETDEV_MULTI_LINK_SUPPORT -DTARGET_SOC=${TARGETSOC}" \
     "${TARGET_DEFCONFIG}"
fi

if [[ ! -f "${CONFIG_FILE}" ]]; then
  echo "[❌] .config not found at ${CONFIG_FILE}"
  exit 1
fi


LOCALVERSION=$("${KERNEL_DIR}/scripts/config" --file "${CONFIG_FILE}" --state CONFIG_LOCALVERSION)

if [ -z "$LOCALVERSION" ]; then
	LOCALVERSION="${VERSION}"
fi

if [[ ! -z "$SETVERSION" ]]; then
	LOCALVERSION="${SETVERSION}"
fi

echo "LOCALVERSION: $LOCALVERSION"

# Change LOCALVERSION
"${KERNEL_DIR}/scripts/config" --file "${CONFIG_FILE}" \
  --set-str CONFIG_LOCALVERSION "$LOCALVERSION" -d CONFIG_LOCALVERSION_AUTO
  
# Fix Kernel Version to remove +
sed -i 's/echo "+"$/echo ""/' $KERNEL_DIR/scripts/setlocalversion

# Compile
KBUILD_BUILD_USER="${BUILDUSER}" KBUILD_BUILD_HOST="${BUILDHOST}" make -j"$(nproc)" \
     -C "${KERNEL_DIR}" \
     O="${OUTPUT_DIR}" \
     ${ARGS} \
     EXTRA_CFLAGS:=" -I$KERNEL_DIR/drivers/ufs/host/s5e9945/ -I$KERNEL_DIR/arch/arm64/kvm/hyp/include -DCFG80211_SINGLE_NETDEV_MULTI_LINK_SUPPORT -DTARGET_SOC=${TARGETSOC}"


# Restore fix from earlier
sed -i 's/echo ""$/echo "+"/' $KERNEL_DIR/scripts/setlocalversion

if [ -e $OUTPUT_DIR/arch/arm64/boot/Image ]; then
	echo "[✅] Kernel build finished."
	python3 $TOOLS/mkbootimg/mkbootimg.py --header_version 4 --kernel $OUTPUT_DIR/arch/arm64/boot/Image --cmdline '' --out $CURRENT_DIR/boot.img
	echo "[✅] Boot image generated at ${CURRENT_DIR}/boot.img"
	tar -cf $CURRENT_DIR/boot.img.tar boot.img
	echo "[✅] Odin flashable image at ${CURRENT_DIR}/boot.img.tar"
else
	echo "[❌] Kernel build failed."
fi
