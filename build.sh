#!/bin/bash
SECONDS=0
set -e

KERNEL_PATH="out/arch/arm64/boot"
OBJ="${KERNEL_PATH}/Image"
GZIP="${KERNEL_PATH}/Image.gz"
DTB="${KERNEL_PATH}/dtb.img"
DTBO="${KERNEL_PATH}/dtbo.img"

DATE="$(TZ=Asia/Jakarta date +%Y%m%d%H%M)"
KERNEL_NAME="derivativeTK-${DATE}.zip"

function KERNEL_COMPILE() {

    export USE_CCACHE=1
    export KBUILD_BUILD_HOST=builder
    export KBUILD_BUILD_USER=khayloaf

    rm -rf out && mkdir -p out

    echo "[*] Resetando KernelSU"
    rm -rf KernelSU drivers/kernelsu
    git restore drivers/Makefile drivers/Kconfig

    echo "[*] Aplicando KernelSU (legacy)"
    curl -LSs "https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/next/kernel/setup.sh" \
    | bash -s legacy

    echo "[*] Verificando clang"
    if [[ ! -d clang ]]; then
        mkdir -p clang
        wget https://github.com/Impqxr/aosp_clang_ci/releases/download/13289611/clang-13289611-linux-x86.tar.xz -O clang.tar.gz
        tar -xf clang.tar.gz -C clang
        if [[ -d clang/clang-* ]]; then mv clang/clang-*/* clang; fi
        rm -f clang.tar.gz
    fi

    export PATH="${PWD}/clang/bin:$PATH"

    echo "[*] Carregando defconfig"
    make O=out ARCH=arm64 guamp_defconfig

    echo "[*] Compilando kernel"
    make -j$(nproc --all) \
        O=out ARCH=arm64 \
        CC=clang LD=ld.lld \
        CROSS_COMPILE=aarch64-linux-gnu- \
        CROSS_COMPILE_COMPAT=arm-linux-gnueabi- \
        LLVM=1 LLVM_IAS=1

    echo "[*] Garantindo Image.gz"
    if [[ ! -f "$GZIP" && -f "$OBJ" ]]; then
        gzip -c "$OBJ" > "$GZIP"
    fi

    echo "[*] Gerando dtb.img (se necessário)"
    if [[ ! -f "$DTB" ]]; then
        find out/arch/arm64/boot/dts -name "*.dtb" -exec cat {} + > "$DTB"
    fi

    echo "[*] Gerando dtbo.img (se necessário)"
    if [[ ! -f "$DTBO" ]]; then
        find out/arch/arm64/boot/dts -name "*.dtbo" -exec cat {} + > "$DTBO"
    fi

    echo "[*] Resultado do build:"
    ls -lh "$KERNEL_PATH"
}

function KERNEL_RESULT() {

    KERNEL_COMPILE

    for f in "$OBJ" "$GZIP" "$DTB" "$DTBO"; do
        [[ ! -f "$f" ]] && echo "Faltando: $f" && exit 1
    done

    echo "[*] Baixando AnyKernel"
    rm -rf anykernel
    git clone https://github.com/kylieeXD/AK3-Surya.git -b T anykernel

    echo "[*] Copiando arquivos"
    cp "$GZIP" anykernel/kernels/
    cp "$DTB"  anykernel/kernels/
    cp "$DTBO" anykernel/kernels/

    cd anykernel

    echo "[*] Criando ZIP"
    zip -r9 "$1" *

    echo "[*] Enviando para Pixeldrain"
    curl -T "$1" -u :dc4f2d6d-ef86-4241-af44-44f311a0ecb9 https://pixeldrain.com/api/file/

    cd ..
}

rm -rf compile.log
KERNEL_RESULT "$KERNEL_NAME" | tee -a compile.log

echo -e "\n✔ Finalizado em $((SECONDS / 60))m $((SECONDS % 60))s\n"
