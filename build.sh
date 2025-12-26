#!/bin/bash
SECONDS=0
set -e

# Set kernel path
KERNEL_PATH="out/arch/arm64/boot"

# Set kernel file
OBJ="${KERNEL_PATH}/Image"
GZIP="${KERNEL_PATH}/Image.gz"
CAT="${KERNEL_PATH}/Image.gz-dtb"

# Set dts file
DTB="${KERNEL_PATH}/dtb.img"
DTBO="${KERNEL_PATH}/dtbo.img"

# Set date kernel
DATE="$(TZ=Asia/Jakarta date +%Y%m%d%H%M)"

# Set kernel name
KERNEL_NAME1="derivativeTS-${DATE}.zip"
KERNEL_NAME2="derivativeRS-${DATE}.zip"

# Set config
CONFIG_PATH="arch/arm64/configs"
DEFCONFIG="guamp_defconfig"
ORIGINAL="${CONFIG_PATH}/${DEFCONFIG}"
BACKUP="${CONFIG_PATH}/${DEFCONFIG}.bak"

function KERNEL_COMPILE() {
	# Set environment variables
	export USE_CCACHE=1
	export KBUILD_BUILD_HOST=builder
	export KBUILD_BUILD_USER=khayloaf

	# Create output directory and do a clean build
	rm -rf out && mkdir -p out

	# Cleaning previous SU directory
	rm -rf KernelSU drivers/kernelsu
	git restore drivers/Makefile drivers/Kconfig

	# Setup for KernelSU
	# Setup for KernelSU
curl -LSs "https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/next/kernel/setup.sh" | bash -s legacy

	# Download clang if not present
	if [[ ! -d clang ]]; then mkdir -p clang
		wget https://github.com/Impqxr/aosp_clang_ci/releases/download/13289611/clang-13289611-linux-x86.tar.xz -O clang.tar.gz
		tar -xf clang.tar.gz -C clang && if [ -d clang/clang-* ]; then mv clang/clang-*/* clang; fi && rm -rf clang.tar.gz
	fi

	# Add clang bin directory to PATH
	export PATH="${PWD}/clang/bin:$PATH"

	# Make the config
	make O=out ARCH=arm64 guamp_defconfig

	# Build the kernel with clang and log output
	make -j$(( $(nproc) - 1 )) O=out ARCH=arm64 CC=clang LD=ld.lld AS=llvm-as AR=llvm-ar NM=llvm-nm OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump STRIP=llvm-strip CROSS_COMPILE=aarch64-linux-gnu- CROSS_COMPILE_COMPAT=arm-linux-gnueabi- LLVM=1 LLVM_IAS=1 2>&1
}

function KERNEL_RESULT() {
	# Run compiler
	KERNEL_COMPILE

	# Check if build is successful
	if [ ! -f "$OBJ" ] || [ ! -f "$GZIP" ] || [ ! -f "$DTB" ] || [ ! -f "$DTBO" ]; then
		exit 1
	fi

	# Create anykernel
	rm -rf anykernel
	git clone https://github.com/kylieeXD/AK3-Surya.git -b "$1" anykernel

	# Copying image
	cp "$Image" "anykernel/kernels/"
	cp "$CAT" "anykernel/kernels/"

	# Created zip kernel
	cd anykernel && zip -r9 "$2" *

	RESPONSE=$(curl -s -F "file=@$2" "https://store1.gofile.io/contents/uploadfile" \
	|| curl -s -F "file=@$2" "https://store2.gofile.io/contents/uploadfile")
	DOWNLOAD_LINK=$(echo "$RESPONSE" | grep -oP '"downloadPage":"\K[^"]+')
	echo -e "\nDownload link: $DOWNLOAD_LINK\n"

	# Back to kernel root
	cd - >/dev/null
}

function MAIN() {
	# Run functions for T variant
	KERNEL_RESULT "T" "$KERNEL_NAME1"

	# Disable some config
	cp "$ORIGINAL" "$BACKUP"
	sed -i 's/^CONFIG_CAMERA_BOOTCLOCK_TIMESTAMP=.*/# CONFIG_CAMERA_BOOTCLOCK_TIMESTAMP is not set/' "$ORIGINAL"

	# Run functions for R variant
	KERNEL_RESULT "R" "$KERNEL_NAME2"

	# Restore config
	mv "$BACKUP" "$ORIGINAL"
}

# Run all function
rm -rf compile.log
MAIN | tee -a compile.log

# Done bang
echo -e "Completed in $((SECONDS / 60)) minute(s) and $((SECONDS % 60)) second(s) !\n"
