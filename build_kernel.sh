#!/bin/bash

# Exit on any error
set -e

# ==========================================
# Argument Parsing
# ==========================================
if [ -z "$1" ]; then
    echo "[!] Error: No device specified."
    echo "Usage: $0 <device_name> [ksu] [miui|aosp]"
    echo "Example: $0 lmi"
    echo "         $0 lmi ksu"
    echo "         $0 lmi ksu miui"
    echo "         $0 lmi aosp"
    exit 1
fi

DEVICE_NAME="$1"
DEFCONFIG="${DEVICE_NAME}_defconfig"
DEFCONFIG_PATH="arch/arm64/configs/${DEFCONFIG}"

if [ ! -f "$DEFCONFIG_PATH" ]; then
    echo "[!] Error: Defconfig not found at $DEFCONFIG_PATH"
    echo "[!] Please verify the device name and try again."
    exit 1
fi

ENABLE_KSU=0
TARGET_OS="both"

shift
# Parse remaining arguments loosely
for arg in "$@"; do
    case "$arg" in
        ksu) ENABLE_KSU=1 ;;
        miui) TARGET_OS="miui" ;;
        aosp) TARGET_OS="aosp" ;;
    esac
done

# ==========================================
# Configuration & Environment
# ==========================================
KERNEL_DIR="$(pwd)"
TOOLCHAIN_BIN="$HOME/zyc-clang/bin"

export PATH="${TOOLCHAIN_BIN}:${PATH}"
export ARCH="arm64"
export SUBARCH="arm64"

# ccache Setup
export CCACHE_DIR="$HOME/.cache/ccache_mikernel"
export CCACHE_EXEC=$(command -v ccache)

if [ -z "$CCACHE_EXEC" ]; then
    echo "[!] ccache not found! Please install ccache first."
    exit 1
fi

export USE_CCACHE=1
export CROSS_COMPILE="aarch64-linux-gnu-"
export CROSS_COMPILE_ARM32="arm-linux-gnueabi-"

echo "[*] Checking Clang version..."
clang --version || { echo "[!] Clang not found at ${TOOLCHAIN_BIN}. Please check the path."; exit 1; }

echo "[*] Setting up ccache in $CCACHE_DIR..."
mkdir -p "$CCACHE_DIR"

# ==========================================
# KernelSU Setup
# ==========================================
if [ "$ENABLE_KSU" -eq 1 ]; then
    echo "==========================================="
    echo " [*] Initializing KernelSU-Next Setup"
    echo "==========================================="
    echo "[*] Downloading and running KernelSU-Next v3.2.0-legacy setup script..."
    curl -LSs "https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/v3.2.0-legacy/kernel/setup.sh" | bash -s v3.2.0-legacy
    echo "[+] KernelSU-Next v3.2.0-legacy setup finished."
    echo "[*] Patching KernelSU-Next for APT inline-hook ABI (add missing static key)..."
    if ! grep -q "ksu_is_init_rc_hook_enabled" drivers/kernelsu/runtime/ksud_integration.c; then
        sed -i 's|^void stop_init_rc_hook();|#include <linux/jump_label.h>\nstruct static_key_true ksu_is_init_rc_hook_enabled = STATIC_KEY_TRUE_INIT;\nEXPORT_SYMBOL_GPL(ksu_is_init_rc_hook_enabled);\nvoid stop_init_rc_hook();|' drivers/kernelsu/runtime/ksud_integration.c
        grep -q "ksu_is_init_rc_hook_enabled" drivers/kernelsu/runtime/ksud_integration.c && echo "[+] Static key ksu_is_init_rc_hook_enabled added." || echo "[!] Static key patch FAILED."
    else
        echo "[*] Static key already present, skipping."
    fi

    echo "[*] Activating KSU-Next manual-hook call sites for APT ABI..."
    # 1) kernel/reboot.c : supercall entry (ksu_handle_sys_reboot) gated behind CONFIG_KSU_SUSFS
    if grep -q "#ifdef CONFIG_KSU_SUSFS" kernel/reboot.c; then
        sed -i 's|#ifdef CONFIG_KSU_SUSFS|#ifdef CONFIG_KSU|g; s|#endif // #ifdef CONFIG_KSU_SUSFS|#endif|g; s|#endif #ifdef CONFIG_KSU_SUSFS|#endif|g' kernel/reboot.c
        echo "[+] reboot.c: CONFIG_KSU_SUSFS -> CONFIG_KSU"
    fi

    # 2) fs/exec.c : replace SUSFS-gated execve hooks with plain CONFIG_KSU calls
    if grep -q "ksu_handle_execveat_sucompat" fs/exec.c; then
        perl -0pi -e 's/#ifdef CONFIG_KSU_SUSFS\n(?:extern[^\n]*\n)+?extern int ksu_handle_execveat\(int \*fd, struct filename \*\*filename_ptr, void \*argv,\n[^\n]*\n[^\n]*\n[^\n]*\n#endif\n)/#ifdef CONFIG_KSU\nextern int ksu_handle_execveat(int *fd, struct filename **filename_ptr, void *argv, void *envp, int *flags);\nextern int ksu_handle_execveat_sucompat(int *fd, struct filename **filename_ptr, void *argv, void *envp, int *flags);\n#endif\n/s' fs/exec.c
        perl -0pi -e 's/#ifdef CONFIG_KSU_SUSFS\n\tif \(likely\(susfs_is_current_proc_umounted\(\)\)\)\n\t\tgoto orig_flow;\n\tif \(static_branch_likely\(&ksu_su_compat_enabled\)\) \{\n\t\tif \(static_branch_unlikely\(&susfs_is_sdcard_android_data_not_decrypted\)\)\n\t\tksu_handle_execveat\(&fd, &filename, &argv, &envp, &flags\);\n\telse\n\t\tksu_handle_execveat_sucompat\(&fd, &filename, &argv, &envp, &flags\);\n\t\}\norig_flow:\n#endif\n/#ifdef CONFIG_KSU\n\tksu_handle_execveat(&fd, &filename, &argv, &envp, &flags);\n#endif\n/s' fs/exec.c
        grep -q "ksu_handle_execveat_sucompat(&fd" fs/exec.c && echo "[+] exec.c: execve hooks activated" || echo "[!] exec.c KSU hook replacement failed."
    fi

    # 3) fs/open.c : faccessat hook (used by sucompat to fake su/sh access check)
    if grep -q "ksu_handle_faccessat" fs/open.c && grep -q "CONFIG_KSU_SUSFS" fs/open.c; then
        perl -0pi -e 's/#ifdef CONFIG_KSU_SUSFS\n(?:extern[^\n]*\n)+?extern int ksu_handle_faccessat\(int \*dfd, const char __user \*\*filename_user, int \*mode,\n[^\n]*\n#endif\n)/#ifdef CONFIG_KSU\nextern bool __ksu_is_allow_uid_for_current(uid_t uid);\nextern int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode, int *flags);\n#endif\n/s' fs/open.c
        perl -0pi -e 's/#ifdef CONFIG_KSU_SUSFS\n\tif \(likely\(susfs_is_current_proc_umounted\(\)\)\)\n\t\tgoto orig_flow;\n\tif \(static_branch_likely\(&ksu_su_compat_enabled\)\)\n\t\tif \(unlikely\(__ksu_is_allow_uid_for_current\(current_uid\(\)\.val\)\)\) \{\n\t\t\tksu_handle_faccessat\(&dfd, &filename, &mode, NULL\);\n\t\}\n\norig_flow:\n#endif\n/#ifdef CONFIG_KSU\n\tif (unlikely(__ksu_is_allow_uid_for_current(current_uid().val))) {\n\t\tksu_handle_faccessat(&dfd, &filename, &mode, NULL);\n\t}\n#endif\n/s' fs/open.c
        grep -q "ksu_handle_faccessat(&dfd" fs/open.c && echo "[+] open.c: faccessat hook activated" || echo "[!] open.c KSU hook replacement failed."
    fi

    # 4) fs/stat.c : only ksu_handle_stat block (skip SUSFS-only vfs_fstat/kstat)
    if grep -q "ksu_handle_stat" fs/stat.c; then
        perl -0pi -e 's/#ifdef CONFIG_KSU_SUSFS\n(?:extern[^\n]*\n)+?extern int ksu_handle_stat\(int \*dfd, const char __user \*\*filename_user, int \*flags\);\n#endif\n/#ifdef CONFIG_KSU\nextern bool __ksu_is_allow_uid_for_current(uid_t uid);\nextern int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);\n#endif\n/s' fs/stat.c
        perl -0pi -e 's/#ifdef CONFIG_KSU_SUSFS\n\tif \(likely\(susfs_is_current_proc_umounted\(\)\)\)\n\t\tgoto orig_flow;\n\tif \(static_branch_likely\(&ksu_su_compat_enabled\)\) \{\n\t\tif \(unlikely\(__ksu_is_allow_uid_for_current\(current_uid\(\)\.val\)\)\)\n\t\t\tksu_handle_stat\(&dfd, &filename, &flags\);\n\t\}\norig_flow:\n#endif\n/#ifdef CONFIG_KSU\n\tif (unlikely(__ksu_is_allow_uid_for_current(current_uid().val)))\n\t\tksu_handle_stat(&dfd, &filename, &flags);\n#endif\n/s' fs/stat.c
        grep -q "ksu_handle_stat(&dfd" fs/stat.c && echo "[+] stat.c: stat hook activated" || echo "[!] stat.c KSU hook replacement failed."
    fi
    echo "[+] KSU-Next manual-hook activation done."
fi

# ==========================================
# Baseband-guard Setup
# ==========================================
echo "==========================================="
echo " [*] Initializing Baseband-guard Setup"
echo "==========================================="
echo "[*] Downloading and running Baseband-guard remote setup script..."
wget -O- https://github.com/vc-teahouse/Baseband-guard/raw/main/setup.sh | bash

echo "[*] Patching security/Kconfig for baseband_guard..."
sed -i '/^config LSM$/,/^help$/{ /^[[:space:]]*default/ { /baseband_guard/! s/selinux/selinux,baseband_guard/ } }' security/Kconfig
echo "[+] Baseband-guard setup finished."
echo "==========================================="

# ==========================================
# AnyKernel3 Setup
# ==========================================
echo "==========================================="
echo " [*] Initializing AnyKernel3 Workspace"
echo "==========================================="
rm -rf anykernel
echo "[*] Cloning AnyKernel3..."
git clone https://github.com/AstideLabs/AnyKernel3 -b master --single-branch --depth=1 anykernel
echo "[+] AnyKernel3 cloned successfully."
echo "==========================================="

# ==========================================
# Modular Build Function
# ==========================================
build_target() {
    local OS_TYPE=$1
    echo "==========================================="
    echo " Starting Kernel Compilation for ${DEVICE_NAME} (Target: $OS_TYPE)"
    echo "==========================================="
    
    local OUT_DIR="${KERNEL_DIR}/out_${OS_TYPE}"
    
    local MAKE_OPTS=(
        -j"$(nproc)"
        O="${OUT_DIR}"
        ARCH="${ARCH}"
        SUBARCH="${SUBARCH}"
        LLVM=1
        LLVM_IAS=1
        CC="ccache clang"
        HOSTCC="ccache clang"
        CROSS_COMPILE="${CROSS_COMPILE}"
        CROSS_COMPILE_ARM32="${CROSS_COMPILE_ARM32}"
    )

    echo "[*] Cleaning ${OUT_DIR}..."
    rm -rf "${OUT_DIR}"
    mkdir -p "${OUT_DIR}"

    local DTS_SOURCE="arch/arm64/boot/dts/vendor/qcom"
    local DTS_BACKUP=".dts.bak.${OS_TYPE}"

    if [ "$OS_TYPE" == "miui" ]; then
        echo "[*] Applying MIUI DTS patches..."
        cp -a "${DTS_SOURCE}" "${DTS_BACKUP}"
        
        # Apply MIUI specific sed patches to dts
        sed -i 's/<154>/<1537>/g' ${DTS_SOURCE}/dsi-panel-j1s* || true
        sed -i 's/<154>/<1537>/g' ${DTS_SOURCE}/dsi-panel-j2* || true
        sed -i 's/<155>/<1544>/g' ${DTS_SOURCE}/dsi-panel-j3s-37-02-0a-dsc-video.dtsi || true
        sed -i 's/<155>/<1545>/g' ${DTS_SOURCE}/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi || true
        sed -i 's/<155>/<1546>/g' ${DTS_SOURCE}/dsi-panel-k11a-38-08-0a-dsc-cmd.dtsi || true
        sed -i 's/<155>/<1546>/g' ${DTS_SOURCE}/dsi-panel-l11r-38-08-0a-dsc-cmd.dtsi || true
        sed -i 's/<70>/<695>/g' ${DTS_SOURCE}/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi || true
        sed -i 's/<70>/<695>/g' ${DTS_SOURCE}/dsi-panel-j3s-37-02-0a-dsc-video.dtsi || true
        sed -i 's/<70>/<695>/g' ${DTS_SOURCE}/dsi-panel-k11a-38-08-0a-dsc-cmd.dtsi || true
        sed -i 's/<70>/<695>/g' ${DTS_SOURCE}/dsi-panel-l11r-38-08-0a-dsc-cmd.dtsi || true
        sed -i 's/<71>/<710>/g' ${DTS_SOURCE}/dsi-panel-j1s* || true
        sed -i 's/<71>/<710>/g' ${DTS_SOURCE}/dsi-panel-j2* || true

        sed -i 's/\/\/ mi,mdss-dsi-pan-enable-smart-fps/mi,mdss-dsi-pan-enable-smart-fps/g' ${DTS_SOURCE}/dsi-panel* || true
        sed -i 's/\/\/ mi,mdss-dsi-smart-fps-max_framerate/mi,mdss-dsi-smart-fps-max_framerate/g' ${DTS_SOURCE}/dsi-panel* || true
        sed -i 's/\/\/ qcom,mdss-dsi-pan-enable-smart-fps/qcom,mdss-dsi-pan-enable-smart-fps/g' ${DTS_SOURCE}/dsi-panel* || true
        sed -i 's/qcom,mdss-dsi-qsync-min-refresh-rate/\/\/qcom,mdss-dsi-qsync-min-refresh-rate/g' ${DTS_SOURCE}/dsi-panel* || true

        sed -i 's/120 90 60/120 90 60 50 30/g' ${DTS_SOURCE}/dsi-panel-g7a-36-02-0c-dsc-video.dtsi || true
        sed -i 's/120 90 60/120 90 60 50 30/g' ${DTS_SOURCE}/dsi-panel-g7a-37-02-0a-dsc-video.dtsi || true
        sed -i 's/120 90 60/120 90 60 50 30/g' ${DTS_SOURCE}/dsi-panel-g7a-37-02-0b-dsc-video.dtsi || true
        sed -i 's/144 120 90 60/144 120 90 60 50 48 30/g' ${DTS_SOURCE}/dsi-panel-j3s-37-02-0a-dsc-video.dtsi || true

        sed -i 's/\/\/39 00 00 00 00 00 03 51 03 FF/39 00 00 00 00 00 03 51 03 FF/g' ${DTS_SOURCE}/dsi-panel-j9-38-0a-0a-fhd-video.dtsi || true
        sed -i 's/\/\/39 00 00 00 00 00 03 51 0D FF/39 00 00 00 00 00 03 51 0D FF/g' ${DTS_SOURCE}/dsi-panel-j2-p2-1-38-0c-0a-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${DTS_SOURCE}/dsi-panel-j1s-42-02-0a-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${DTS_SOURCE}/dsi-panel-j1s-42-02-0a-mp-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${DTS_SOURCE}/dsi-panel-j2-mp-42-02-0b-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${DTS_SOURCE}/dsi-panel-j2-p2-1-42-02-0b-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${DTS_SOURCE}/dsi-panel-j2s-mp-42-02-0a-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 03 51 00 00/39 01 00 00 00 00 03 51 00 00/g' ${DTS_SOURCE}/dsi-panel-j2-38-0c-0a-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 03 51 03 FF/39 01 00 00 00 00 03 51 03 FF/g' ${DTS_SOURCE}/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 03 51 03 FF/39 01 00 00 00 00 03 51 03 FF/g' ${DTS_SOURCE}/dsi-panel-j9-38-0a-0a-fhd-video.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 03 51 07 FF/39 01 00 00 00 00 03 51 07 FF/g' ${DTS_SOURCE}/dsi-panel-j1u-42-02-0b-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 03 51 07 FF/39 01 00 00 00 00 03 51 07 FF/g' ${DTS_SOURCE}/dsi-panel-j2-42-02-0b-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 03 51 07 FF/39 01 00 00 00 00 03 51 07 FF/g' ${DTS_SOURCE}/dsi-panel-j2-p1-42-02-0b-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 03 51 0F FF/39 01 00 00 00 00 03 51 0F FF/g' ${DTS_SOURCE}/dsi-panel-j1u-42-02-0b-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 03 51 0F FF/39 01 00 00 00 00 03 51 0F FF/g' ${DTS_SOURCE}/dsi-panel-j2-42-02-0b-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 03 51 0F FF/39 01 00 00 00 00 03 51 0F FF/g' ${DTS_SOURCE}/dsi-panel-j2-p1-42-02-0b-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${DTS_SOURCE}/dsi-panel-j1s-42-02-0a-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${DTS_SOURCE}/dsi-panel-j1s-42-02-0a-mp-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${DTS_SOURCE}/dsi-panel-j2-mp-42-02-0b-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${DTS_SOURCE}/dsi-panel-j2-p2-1-42-02-0b-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${DTS_SOURCE}/dsi-panel-j2s-mp-42-02-0a-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 01 00 03 51 03 FF/39 01 00 00 01 00 03 51 03 FF/g' ${DTS_SOURCE}/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 11 00 03 51 03 FF/39 01 00 00 11 00 03 51 03 FF/g' ${DTS_SOURCE}/dsi-panel-j2-p2-1-38-0c-0a-dsc-cmd.dtsi || true
    fi

    echo "[*] Making defconfig: ${DEFCONFIG}..."
    make "${MAKE_OPTS[@]}" "${DEFCONFIG}"

    # ----------------------------------------------------
    # Configuration tweaks
    # ----------------------------------------------------
    
    # 1. Baseband-guard configuration (Always applied)
    echo "[*] Injecting Baseband-guard configuration..."
    scripts/config --file "${OUT_DIR}/.config" -e BBG

    # 2. KernelSU configurations
    if [ "$ENABLE_KSU" -eq 1 ]; then
        echo "[*] Injecting KernelSU-Next configurations..."
        scripts/config --file "${OUT_DIR}/.config" \
            -e KSU \
            -e THREAD_INFO_IN_TASK 
    fi

    # 3. MIUI configurations
    if [ "$OS_TYPE" == "miui" ]; then
        echo "[*] Injecting MIUI specific configurations..."
        scripts/config --file "${OUT_DIR}/.config" \
            --set-str STATIC_USERMODEHELPER_PATH /system/bin/micd \
            -e PERF_CRITICAL_RT_TASK \
            -e SF_BINDER \
            -e OVERLAY_FS \
            -e MIGT \
            -e MIGT_ENERGY_MODEL \
            -e MIHW \
            -e PACKAGE_RUNTIME_INFO \
            -e BINDER_OPT \
            -e KPERFEVENTS \
            -e MILLET \
            -e PERF_HUMANTASK \
            -d LTO_CLANG \
            -e LTO_NONE \
            -d SHADOW_CALL_STACK \
            -e XIAOMI_MIUI \
            -d MI_MEMORY_SYSFS \
            -e TASK_DELAY_ACCT \
            -e MIUI_ZRAM_MEMORY_TRACKING \
            -e PERF_HELPER \
            -e BOOTUP_RECLAIM \
            -e MI_RECLAIM \
            -e RTMM \
            -d REKERNEL \
            -d REKERNEL_NETWORK
    fi

    # We always need to re-evaluate dependencies because BBG is injected unconditionally
    echo "[*] Updating config (make olddefconfig)..."
    make "${MAKE_OPTS[@]}" olddefconfig

    # Verify KernelSU is really enabled after olddefconfig (KSU depends on KPROBES)
    if [ "$ENABLE_KSU" -eq 1 ]; then
        echo "[*] Verifying KSU config..."
        grep -E "^CONFIG_KSU=" "${OUT_DIR}/.config" || echo "[!] WARNING: CONFIG_KSU not found in .config"
        grep -E "^CONFIG_KPROBES=" "${OUT_DIR}/.config" || echo "[!] WARNING: CONFIG_KPROBES not found in .config"
    fi

    # ----------------------------------------------------
    # Compilation
    # ----------------------------------------------------
    echo "[*] Building kernel..."
    make "${MAKE_OPTS[@]}" 

    # Restore DTS backup for MIUI
    if [ "$OS_TYPE" == "miui" ]; then
        echo "[*] Restoring DTS backups..."
        rm -rf "${DTS_SOURCE}"
        mv "${DTS_BACKUP}" "${DTS_SOURCE}"
    fi

    echo "==========================================="
    if [ -f "${OUT_DIR}/arch/arm64/boot/Image" ]; then
        echo "[+] $OS_TYPE Build Successful!"
        echo "[+] Kernel Image path: ${OUT_DIR}/arch/arm64/boot/Image"
        
        echo "[*] Generating dtb..."
        find "${OUT_DIR}/arch/arm64/boot/dts" -name '*.dtb' -exec cat {} + > "${OUT_DIR}/arch/arm64/boot/dtb"

        echo "[*] Packaging to AnyKernel3 ($OS_TYPE)..."
        # 纭繚鐙珛鎵撳寘锛氭竻绌虹幇鏈夌殑 kernels 鐩綍
        rm -rf anykernel/kernels/*
        mkdir -p "anykernel/kernels/${OS_TYPE}/"
        
        cp "${OUT_DIR}/arch/arm64/boot/Image" "anykernel/kernels/${OS_TYPE}/"
        cp "${OUT_DIR}/arch/arm64/boot/dtb" "anykernel/kernels/${OS_TYPE}/"
        
        if [ -f "${OUT_DIR}/arch/arm64/boot/dtbo.img" ]; then
            cp "${OUT_DIR}/arch/arm64/boot/dtbo.img" "anykernel/kernels/${OS_TYPE}/"
        fi
        
        # 纭畾 ZIP 鏂囦欢鍚?        local KSU_ZIP_STR="NoKernelSU"
        if [ "$ENABLE_KSU" -eq 1 ]; then
            KSU_ZIP_STR="KernelSU-Next"
        fi
        local GIT_COMMIT_ID=$(git rev-parse --short=8 HEAD 2>/dev/null || echo "unknown")
        local OS_UPPER=$(echo "$OS_TYPE" | tr '[:lower:]' '[:upper:]')
        local ZIP_FILENAME="APTKernel_${OS_UPPER}_${DEVICE_NAME}_${KSU_ZIP_STR}_$(date +'%Y%m%d_%H%M%S')_anykernel3_${GIT_COMMIT_ID}.zip"
        
        echo "[*] Zipping $ZIP_FILENAME ..."
        pushd anykernel > /dev/null
        zip -r9 "$ZIP_FILENAME" ./* -x .git .gitignore out/ ./*.zip > /dev/null
        mv "$ZIP_FILENAME" ../
        popd > /dev/null
        
        echo "[+] $OS_TYPE kernel binaries successfully packed into: $ZIP_FILENAME"
    else
        echo "[-] $OS_TYPE Build Failed. Kernel Image not found."
        exit 1
    fi
}

# ==========================================
# Execute builds based on target OS
# ==========================================
if [ "$TARGET_OS" == "aosp" ] || [ "$TARGET_OS" == "both" ]; then
    build_target "aosp"
fi

if [ "$TARGET_OS" == "miui" ] || [ "$TARGET_OS" == "both" ]; then
    build_target "miui"
fi

echo "==========================================="
echo "[*] ccache stats:"
ccache -s
echo "[+] All requested builds completed!"