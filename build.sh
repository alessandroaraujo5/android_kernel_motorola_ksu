#!/bin/bash
#
# 🧠 Templar Kernel GKI Build Script (Full LTO Optimized Edition)
# ---------------------------------------------------------------
# Features:
# - LLVM Polly, MLGO, PGO, Full LTO
# - Auto-detect LLVM 15–22
# - Link-time optimization cache (faster rebuild)
# - Telegram notification integration
# - CPU load balancing (24 cores max, smooth VPS usage)
# ---------------------------------------------------------------
# © 2025 Steambot12 / WiL
#

# ===============================================
# 🧩 Environment setup
# ===============================================
TC_DIR="${TC_DIR:-$HOME/prebuilts/clang/host/linux-x86/ollvm-21}"
export PATH="$TC_DIR/bin:$PATH"

export KBUILD_BUILD_USER="WiL"
export KBUILD_BUILD_HOST="Steambot12"
export HOSTCC="gcc"
export HOSTCXX="g++"

# ===============================================
# 🔒 Fixed build-date (reproducible & anti-detect)
# ===============================================
# Tanggal bisa diganti sesuai kebutuhan (format: "Mon Jan  1 00:00:00 UTC 2024")
FIXED_DATE="Mon Jan  1 00:00:00 UTC 2024"
export KBUILD_BUILD_TIMESTAMP="$FIXED_DATE"

TG_TOKEN=""
TG_CHAT_ID=""

PROJECT_ID="Templar Kernel"
PROJECT_HOST="Steambot12"
LOCALVERSION_NAME="Templar-v4.3-SukiSu"

ANYKERNEL_REPO="https://github.com/Steambot12/AnyKernel3-Templar-SukiSu.git"
ANYKERNEL_DIR="AnyKernel3-Templar-SukiSu"

DO_CLEAN=false
NO_LTO=false
ONLY_CONFIG=false

# ===============================================
# ⚙️ LTO / PGO / MLGO runtime options
# ===============================================
LTO_MODE="full"
PGO_MODE="none"
PGO_DATA_DIR="pgo-data"
PGO_PROFDATA="${PGO_DATA_DIR}/default.profdata"
MLGO_AUTO=true
# ===============================================
# 🔥 BOLT runtime options
# ===============================================
BOLT_MODE="none"
BOLT_DATA_DIR="bolt-data"
BOLT_FDATA="${BOLT_DATA_DIR}/vmlinux.fdata"
BOLT_OUTPUT="vmlinux.bolted"

# ===============================================
# 🔍 Detect clang binary
# ===============================================
CLANG_BIN=""
if [ -x "${TC_DIR}/bin/clang" ]; then
    CLANG_BIN="${TC_DIR}/bin/clang"
elif command -v clang >/dev/null 2>&1; then
    CLANG_BIN=$(command -v clang)
fi

clang_has_flag() {
    local flag="$1"
    [ -z "$CLANG_BIN" ] && return 1
    echo "int main(void){}" | "$CLANG_BIN" -x c - -o /dev/null $flag >/dev/null 2>&1
}

# ===============================================
# 🧭 Argument parser
# ===============================================
while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--clean) DO_CLEAN=true ;;
        -n|--no-lto) NO_LTO=true ;;
        -o|--only-config) ONLY_CONFIG=true ;;
        --lto) LTO_MODE="$2"; shift ;;
        --lto=*) LTO_MODE="${1#*=}" ;;
        --pgo-generate) PGO_MODE="generate" ;;
        --pgo-use) PGO_MODE="use"; PGO_PROFDATA="$2"; shift ;;
        --pgo-use=*) PGO_MODE="use"; PGO_PROFDATA="${1#*=}" ;;
        --pgo-dir) PGO_DATA_DIR="$2"; PGO_PROFDATA="$PGO_DATA_DIR/default.profdata"; shift ;;
        --pgo-dir=*) PGO_DATA_DIR="${1#*=}"; PGO_PROFDATA="$PGO_DATA_DIR/default.profdata" ;;
        --mlgo-off) MLGO_AUTO=false ;;
        --mlgo-auto) MLGO_AUTO=true ;;
		--bolt) BOLT_MODE="run" ;;
		--bolt-generate) BOLT_MODE="generate" ;;
		--bolt-use) BOLT_MODE="use"; BOLT_FDATA="$2"; shift ;;
		--bolt-use=*) BOLT_MODE="use"; BOLT_FDATA="${1#*=}" ;;
        *) [[ "$1" == -* ]] && { echo "Unknown option: $1"; exit 1; } || break ;;
    esac
    shift
done

TARGET="${1:-}"
KERNEL_VERSION="${2:-}"

if [ -z "$TARGET" ] || [ -z "$KERNEL_VERSION" ]; then
    echo "Usage: $0 [--clean] [--lto=(none|thin|full)] [--pgo-generate|--pgo-use[=profdata]] <device> <version>"
    exit 1
fi

ZIP_NAME="${LOCALVERSION_NAME}-v${KERNEL_VERSION}.zip"
DEVICE_NAME="$TARGET GKI"

# ===============================================
# 🧠 Detect LLVM version
# ===============================================
LLVM_VERSION=$($CLANG_BIN --version | grep -oE '([0-9]+\.[0-9]+|[0-9]+)' | head -1)
LLVM_MAJOR=${LLVM_VERSION%%.*}
[ -z "$LLVM_MAJOR" ] && LLVM_MAJOR=21
echo "[INFO] Detected LLVM version: $LLVM_MAJOR"

# ===============================================
# ⚡ MLGO / Polly
# ===============================================
MLGO_FLAGS=""
PGO_FLAGS=""

if [ -n "$CLANG_BIN" ] && "$CLANG_BIN" --version >/dev/null 2>&1 && [ "$MLGO_AUTO" = true ]; then
    MLGO_FLAGS+=" -O3"
    if clang_has_flag "-mllvm -polly"; then
        MLGO_FLAGS+=" -mllvm -polly -mllvm -polly-run-inliner -mllvm -polly-ast-use-context"
        MLGO_FLAGS+=" -mllvm -polly-detect-keep-going -mllvm -polly-invariant-load-hoisting"
        MLGO_FLAGS+=" -mllvm -polly-vectorizer=stripmine -mllvm -polly-postopts=1"
    fi
    if $CLANG_BIN --help-hidden 2>/dev/null | grep -q "regalloc-enable-advisor"; then
        MLGO_FLAGS+=" -mllvm -enable-ml-inliner=release"
        MLGO_FLAGS+=" -mllvm -regalloc-enable-advisor=release -mllvm -hot-cold-split=true"
        echo "--- MLGO Optimizations Activated ---"
    else
        echo "--- Polly flags applied ---"
    fi
fi

# ===============================================
# 📊 PGO handling
# ===============================================
if [ "$PGO_MODE" = "generate" ]; then
    PGO_FLAGS+=" -fprofile-instr-generate -fcoverage-mapping"
    echo "[PGO] Building with profile instrumentation"
elif [ "$PGO_MODE" = "use" ]; then
    if [ -f "$PGO_PROFDATA" ]; then
        PGO_FLAGS+=" -fprofile-instr-use=$PGO_PROFDATA -fcoverage-mapping"
        echo "[PGO] Using profdata: $PGO_PROFDATA"
    fi
fi

[ "$NO_LTO" = true ] && LTO_MODE="none"

# ===============================================
# 🧩 Utility functions
# ===============================================
format_time() {
    local D=$1
    printf "%dh:%dm:%ds" $((D / 3600)) $((D % 3600 / 60)) $((D % 60))
}

bolt_extract_vmlinux() {
    local image="$1"
    local output="$2"
    echo "[BOLT] Extracting vmlinux from Image..."
    llvm-objcopy -O binary "$image" "$output"
}

bolt_run() {
    local input="$1"
    local output="$2"
    local fdata="$3"

    local BOLT_BIN="${TC_DIR}/bin/llvm-bolt"
    local MERGE_BIN="${TC_DIR}/bin/merge-fdata"

    if [ ! -x "$BOLT_BIN" ]; then
        echo "[BOLT] llvm-bolt not found in $TC_DIR/bin"
        return 1
    fi

    if [ "$BOLT_MODE" = "generate" ]; then
        echo "[BOLT] Generating fdata (instrumentation mode)..."
        "$BOLT_BIN" "$input" -o "$output" --instrument --instrumentation-file="$fdata"
        return 0
    fi

    if [ "$BOLT_MODE" = "use" ] && [ -f "$fdata" ]; then
        echo "[BOLT] Optimizing with fdata: $fdata"
        "$BOLT_BIN" "$input" -o "$output" \
            --data="$fdata" \
            --reorder-blocks=ext-tsp \
            --reorder-functions=hfsort+ \
            --split-functions \
            --icf=1 \
            --inline-all \
            --use-gnu-stack
        return 0
    fi

    if [ "$BOLT_MODE" = "run" ]; then
        echo "[BOLT] Running basic BOLT optimization (no fdata)..."
        "$BOLT_BIN" "$input" -o "$output" \
            --reorder-blocks=ext-tsp \
            --reorder-functions=hfsort+ \
            --split-functions \
            --icf=1 \
            --inline-all \
            --use-gnu-stack
        return 0
    fi

    echo "[BOLT] No valid BOLT mode selected."
    return 1
}
adaptive_jobs() {
    local max_jobs=24
    local load=$(awk '{print int($1)}' /proc/loadavg)
    (( load > max_jobs )) && echo $((max_jobs / 2)) || echo $max_jobs
}

# ===============================================
# ⚙️ Full LTO Optimized Build Environment
# ===============================================
export LD=ld.lld
export LLVM_AR=llvm-ar
export LLVM_NM=llvm-nm
export LLVM_OBJCOPY=llvm-objcopy
export LLVM_OBJDUMP=llvm-objdump
export LLVM_RANLIB=llvm-ranlib

export LTO_CACHE_DIR="$PWD/out/lto-cache"
mkdir -p "$LTO_CACHE_DIR"

export LDFLAGS="-Wl,--O2 -Wl,--icf=all -Wl,--no-keep-memory \
    -Wl,--plugin-opt=cache-dir=$LTO_CACHE_DIR \
    -Wl,--plugin-opt=cache-policy=cache"

# ===============================================
# ✅ Optimized make wrapper (low CPU priority)
# ===============================================
m() {
    local jobs=$(adaptive_jobs)
    echo "[BUILD] Using $jobs parallel jobs (low load)"
    nice -n 10 ionice -c2 -n7 \
    make ARCH=arm64 LLVM=1 LLVM_IAS=1 O=out CROSS_COMPILE=aarch64-linux-gnu- \
         KCFLAGS="$MLGO_FLAGS $PGO_FLAGS" \
         LDFLAGS="$LDFLAGS" \
         "$@" -j"$jobs" 2>&1 | tee -a $LOG_FILE
}

# ===============================================
# 🚀 Build start
# ===============================================
send_tg() {
    [ -z "$TG_TOKEN" ] || [ -z "$TG_CHAT_ID" ] && return
    curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
         -d chat_id="$TG_CHAT_ID" -d parse_mode="Markdown" -d text="$1" >/dev/null
}

tg_upload() {
    [ -z "$TG_TOKEN" ] || [ -z "$TG_CHAT_ID" ] && return
    curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendDocument" \
         -F chat_id="$TG_CHAT_ID" -F document=@"$1" >/dev/null
}

send_tg "🚀 *New Build Started*  
Project: \`$PROJECT_ID\`  
Device: \`$DEVICE_NAME\`  
Host: \`$PROJECT_HOST\`"

$DO_CLEAN && rm -rf out/ && echo "Cleaned output directory."
mkdir -p out

echo "Generating config..."
m guamp_defconfig
scripts/config --file out/.config --set-str LOCALVERSION "-${LOCALVERSION_NAME}"

case "$LTO_MODE" in
    none) scripts/config --file out/.config -e LTO_NONE -d LTO_CLANG_THIN -d LTO_CLANG_FULL ;;
    thin) scripts/config --file out/.config -d LTO_NONE -e LTO_CLANG_THIN -d LTO_CLANG_FULL ;;
    full|*) scripts/config --file out/.config -d LTO_NONE -d LTO_CLANG_THIN -e LTO_CLANG_FULL ;;
esac

echo "Configured KCFLAGS: $MLGO_FLAGS $PGO_FLAGS"
$ONLY_CONFIG && exit

echo "Building kernel Image..."
m Image || { send_tg "❌ *BUILD FAILED!*"; tg_upload "$LOG_FILE"; exit 1; }

# ===============================================
# 🧩 Patch kernel image
# ===============================================
if [ -f out/arch/arm64/boot/Image ]; then
    echo "=== Patching Kernel Image ==="
    pushd out/arch/arm64/boot >/dev/null
    curl -LO https://raw.githubusercontent.com/Numbersf/Action-Build/SukiSU-Ultra/patches/patch_linux && chmod +x patch_linux
    ./patch_linux && [ -f oImage ] && mv oImage Image
    popd >/dev/null
fi

# ===============================================
# 🔥 BOLT optimization (optional)
# ===============================================
if [ "$BOLT_MODE" != "none" ]; then
    VMLINUX_RAW="out/vmlinux.bin"
    bolt_extract_vmlinux "out/arch/arm64/boot/Image" "$VMLINUX_RAW"

    if bolt_run "$VMLINUX_RAW" "$BOLT_OUTPUT" "$BOLT_FDATA"; then
        echo "[BOLT] Replacing Image with BOLT-optimized version..."
        cp "$BOLT_OUTPUT" out/arch/arm64/boot/Image
        send_tg "🔥 *BOLT optimization applied*"
    else
        send_tg "⚠️ *BOLT failed* – using original Image"
    fi
fi
# ===============================================
# 📦 Package AnyKernel + Telegram upload
# ===============================================
pack_anykernel() {
    echo "Packing AnyKernel3..."
    [ ! -d "$ANYKERNEL_DIR" ] && git clone --depth 1 "$ANYKERNEL_REPO" "$ANYKERNEL_DIR"
    cp out/arch/arm64/boot/Image "$ANYKERNEL_DIR/"
    (cd "$ANYKERNEL_DIR" && zip -r9 "../$ZIP_NAME" . -x .git README.md *placeholder)
    echo "Packed: $ZIP_NAME"
}

if [ -f out/arch/arm64/boot/Image ]; then
    pack_anykernel
    if [ -f "$ZIP_NAME" ]; then
        FILE_SIZE=$(du -h "$ZIP_NAME" | cut -f1)
        MD5_HASH=$(md5sum "$ZIP_NAME" | cut -d ' ' -f1)
        SHA256_HASH=$(sha256sum "$ZIP_NAME" | cut -d ' ' -f1)
        DURATION=$(format_time $SECONDS)
        send_tg "✅ *Build Success!*  
Device: \`$DEVICE_NAME\`  
File: \`$ZIP_NAME\`  
Time: \`$DURATION\`  
Size: \`$FILE_SIZE\`  
MD5: \`$MD5_HASH\`  
SHA256: \`$SHA256_HASH\`"
        tg_upload "$ZIP_NAME"
    fi
else
    send_tg "❌ *Build Failed!* No Image found."
    tg_upload "$LOG_FILE"
    exit 1
fi

echo "✅ Completed in $(format_time $SECONDS)"
