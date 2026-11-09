#!/usr/bin/env bash
set -Eeuo pipefail

# Snapdragon 8 Gen 3 (pineapple / SM8650) make-based build helper.
# Default target: Galaxy S24 Ultra (e3q, SM-S928B).
#
# Builds the kernel, every in-tree module and every Qualcomm techpack
# (techpack/) with plain `make` - no Bazel/Kleaf - then splits the modules
# into the vendor_boot / vendor_dlkm / system_dlkm sets using the stock
# module lists in android/<device>/, and optionally packs boot.img,
# vendor_boot.img, dtbo.img, vendor_dlkm.img and system_dlkm.img.
#
# Partition contents that are not built from this tree (vendor ramdisk base,
# etc/build.prop of the dlkm partitions, ...) come from build/, extracted from
# the stock S928BXXU4AXK4 images:
#   build/vendor_boot_base/<device>/  vendor ramdisk without lib/modules
#   build/vendor_dlkm/etc/            vendor_dlkm etc/ (build.prop, fs_config)
#   build/system_dlkm/etc/            system_dlkm etc/
# To use another firmware instead, point STOCK_DIR at a directory with
# vendor_boot.img, vendor_dlkm.img and system_dlkm.img dumped from the device
# (or extracted from the firmware); stock images win over build/.
#
# Quick start:
#   ./build_pineapple.sh
#   BUILD_FLASHABLE_ZIP=1 ./build_pineapple.sh    # + TWRP flashable zip
#
# Everything is configurable through environment variables (see below).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

BUILD_START_SECONDS=$SECONDS

# Colors only for an interactive terminal that hasn't opted out (NO_COLOR:
# https://no-color.org). Piped/redirected output stays plain.
if [[ -t 1 && -t 2 && -z "${NO_COLOR:-}" ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'; C_CYAN=$'\033[36m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""
fi

log() { printf '%s[pineapple-make]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s[pineapple-make][warn]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die() { printf '%s[pineapple-make][error]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1${2:+ ($2)}"; }

# Prints a banner and runs the given function, timing it.
run_phase() {
  local title="$1"; shift
  local start=$SECONDS elapsed
  printf '\n%s%s==>%s %s%s%s\n' "$C_BOLD" "$C_CYAN" "$C_RESET" "$C_BOLD" "$title" "$C_RESET"
  "$@"
  elapsed=$((SECONDS - start))
  printf '%s%s<==%s %s %s(%dm%02ds)%s\n' "$C_BOLD" "$C_CYAN" "$C_RESET" "$title" \
    "$C_DIM" "$((elapsed / 60))" "$((elapsed % 60))" "$C_RESET"
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
TARGET_SOC="${TARGET_SOC:-pineapple}"
DEVICE_CODENAME="${DEVICE_CODENAME:-e3q}"
BUILD_VARIANT="${BUILD_VARIANT:-user}"
JOBS="${JOBS:-$(nproc --all 2>/dev/null || echo 8)}"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/out/${DEVICE_CODENAME}_${BUILD_VARIANT}_make}"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/out/${DEVICE_CODENAME}_${BUILD_VARIANT}_dist}"
DEFCONFIG="${DEFCONFIG:-${TARGET_SOC}_${DEVICE_CODENAME}_defconfig}"
# Extra Kconfig fragments merged on top of DEFCONFIG (space separated paths).
CONFIG_FRAGMENTS="${CONFIG_FRAGMENTS:-}"
# LTO: keep (whatever the defconfig says), none, thin or full.
LTO="${LTO:-keep}"
MAKE_GOALS="${MAKE_GOALS:-Image modules dtbs}"
KERNEL_BINARY="${KERNEL_BINARY:-Image}"
CLEAN_BUILD="${CLEAN_BUILD:-0}"
AUTO_MRPROPER="${AUTO_MRPROPER:-1}"
STRICT_MISSING_MODULES="${STRICT_MISSING_MODULES:-0}"
STRICT_DEPMOD="${STRICT_DEPMOD:-0}"
INSTALL_MOD_STRIP="${INSTALL_MOD_STRIP:-1}"
# Modules built but not listed in any stock list: none (report only) or
# vendor_dlkm (ship them there, not added to modules.load).
UNLISTED_MODULES="${UNLISTED_MODULES:-none}"
EXTRA_MAKE_ARGS="${EXTRA_MAKE_ARGS:-}"

# Kernel release string (uname -r):
#   short: <version><CONFIG_LOCALVERSION>, e.g. 6.1.68-SharkKernel-v0.1-e3q
#   stock: as the Samsung/Android build makes it from GOOGLE_BRANCH +
#          KMI_GENERATION + scripts/sec_env.mk, e.g.
#          6.1.68-android14-11<CONFIG_LOCALVERSION>-29543898-abS928BXXU4AXK4
RELEASE_STYLE="${RELEASE_STYLE:-short}"
GOOGLE_BRANCH="${GOOGLE_BRANCH:-android14-6.1}"
KMI_GENERATION="${KMI_GENERATION:-11}"
KCFLAGS="${KCFLAGS:--D__ANDROID_COMMON_KERNEL__}"

# Toolchain: AOSP clang-r487747c (clang 17.0.2), the one this kernel is
# built with (build.config.constants). Set CLANG_BIN to override.
CLANG_VERSION="${CLANG_VERSION:-r487747c}"
CLANG_BIN="${CLANG_BIN:-}"
FETCH_CLANG="${FETCH_CLANG:-0}"
CLANG_FETCH_DIR="${CLANG_FETCH_DIR:-$ROOT_DIR/../prebuilts/clang/host/linux-x86/clang-${CLANG_VERSION}}"
CLANG_FETCH_URL="${CLANG_FETCH_URL:-https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/android14-release/clang-${CLANG_VERSION}.tar.gz}"

# Module partition lists (from the stock firmware).
MODULE_LISTS_DIR="${MODULE_LISTS_DIR:-$ROOT_DIR/android/$DEVICE_CODENAME}"

# Stock images used as base for the partitions we rebuild.
STOCK_DIR="${STOCK_DIR:-}"
STOCK_VENDOR_BOOT_IMG="${STOCK_VENDOR_BOOT_IMG:-${STOCK_DIR:+$STOCK_DIR/vendor_boot.img}}"
STOCK_VENDOR_DLKM_IMG="${STOCK_VENDOR_DLKM_IMG:-${STOCK_DIR:+$STOCK_DIR/vendor_dlkm.img}}"
STOCK_SYSTEM_DLKM_IMG="${STOCK_SYSTEM_DLKM_IMG:-${STOCK_DIR:+$STOCK_DIR/system_dlkm.img}}"
# Or pre-extracted base directories (take precedence over STOCK_*_IMG).
VENDOR_RAMDISK_BASE_DIR="${VENDOR_RAMDISK_BASE_DIR:-}"
VENDOR_DLKM_BASE_DIR="${VENDOR_DLKM_BASE_DIR:-}"
SYSTEM_DLKM_BASE_DIR="${SYSTEM_DLKM_BASE_DIR:-}"
# Without a stock image, fall back to the bases shipped in build/.
IN_TREE_BASE_DIR="${IN_TREE_BASE_DIR:-$ROOT_DIR/build}"
if [[ -z "$VENDOR_RAMDISK_BASE_DIR" && -z "$STOCK_VENDOR_BOOT_IMG" && -d "$IN_TREE_BASE_DIR/vendor_boot_base/$DEVICE_CODENAME" ]]; then
  VENDOR_RAMDISK_BASE_DIR="$IN_TREE_BASE_DIR/vendor_boot_base/$DEVICE_CODENAME"
fi
if [[ -z "$VENDOR_DLKM_BASE_DIR" && -z "$STOCK_VENDOR_DLKM_IMG" && -d "$IN_TREE_BASE_DIR/vendor_dlkm/etc" ]]; then
  VENDOR_DLKM_BASE_DIR="$IN_TREE_BASE_DIR/vendor_dlkm"
fi
if [[ -z "$SYSTEM_DLKM_BASE_DIR" && -z "$STOCK_SYSTEM_DLKM_IMG" && -d "$IN_TREE_BASE_DIR/system_dlkm/etc" ]]; then
  SYSTEM_DLKM_BASE_DIR="$IN_TREE_BASE_DIR/system_dlkm"
fi

# Image builds: 1, 0 or auto (build when the needed inputs are available).
BUILD_BOOT_IMG="${BUILD_BOOT_IMG:-1}"
BUILD_DTBO_IMG="${BUILD_DTBO_IMG:-1}"
BUILD_VENDOR_BOOT_IMG="${BUILD_VENDOR_BOOT_IMG:-auto}"
BUILD_VENDOR_DLKM_IMG="${BUILD_VENDOR_DLKM_IMG:-auto}"
BUILD_SYSTEM_DLKM_IMG="${BUILD_SYSTEM_DLKM_IMG:-auto}"

MKBOOTIMG="${MKBOOTIMG:-}"
UNPACK_BOOTIMG="${UNPACK_BOOTIMG:-}"
MKDTBOIMG="${MKDTBOIMG:-}"

# boot.img (GKI layout: kernel only, the generic ramdisk lives in init_boot).
BOOT_IMAGE_OUT="${BOOT_IMAGE_OUT:-$DIST_DIR/boot.img}"
BOOT_HEADER_VERSION="${BOOT_HEADER_VERSION:-4}"
BOOT_OS_VERSION="${BOOT_OS_VERSION:-14.0.0}"
BOOT_OS_PATCH_LEVEL="${BOOT_OS_PATCH_LEVEL:-2024-11}"
BOOT_CMDLINE="${BOOT_CMDLINE:-}"
BOOT_KERNEL_IMAGE="${BOOT_KERNEL_IMAGE:-$DIST_DIR/$KERNEL_BINARY}"

# vendor_boot.img - defaults match S928BXXU4AXK4 (unpack_bootimg of stock).
VENDOR_BOOT_IMAGE_OUT="${VENDOR_BOOT_IMAGE_OUT:-$DIST_DIR/vendor_boot.img}"
VENDOR_BOOT_HEADER_VERSION="${VENDOR_BOOT_HEADER_VERSION:-4}"
VENDOR_BOOT_PAGESIZE="${VENDOR_BOOT_PAGESIZE:-4096}"
VENDOR_BOOT_BASE="${VENDOR_BOOT_BASE:-0x00000000}"
VENDOR_BOOT_KERNEL_OFFSET="${VENDOR_BOOT_KERNEL_OFFSET:-0x00008000}"
VENDOR_BOOT_RAMDISK_OFFSET="${VENDOR_BOOT_RAMDISK_OFFSET:-0x02000000}"
VENDOR_BOOT_TAGS_OFFSET="${VENDOR_BOOT_TAGS_OFFSET:-0x01e00000}"
VENDOR_BOOT_DTB_OFFSET="${VENDOR_BOOT_DTB_OFFSET:-0x0000000001f00000}"
VENDOR_BOOT_BOARD="${VENDOR_BOOT_BOARD:-SRPWG28B004}"
VENDOR_BOOT_CMDLINE="${VENDOR_BOOT_CMDLINE:-video=vfb:640x400,bpp=32,memsize=3072000 printk.devkmsg=on firmware_class.path=/vendor/firmware_mnt/image bootconfig loop.max_part=7}"
VENDOR_BOOTCONFIG_FILE="${VENDOR_BOOTCONFIG_FILE:-}"
VENDOR_BOOTCONFIG_TEXT="${VENDOR_BOOTCONFIG_TEXT:-androidboot.hardware=qcom
androidboot.memcg=1
androidboot.usbcontroller=a600000.dwc3
androidboot.load_modules_parallel=false
androidboot.hypervisor.protected_vm.supported=true
androidboot.console=0}"
# DTB appended to vendor_boot: built (SoC dtbs from this tree), stock (from
# STOCK_VENDOR_BOOT_IMG) or a path to a dtb file.
VENDOR_DTB="${VENDOR_DTB:-built}"
VENDOR_DTB_NAMES="${VENDOR_DTB_NAMES:-pineapple.dtb pineapple-v2.dtb pineapplep.dtb pineapplep-v2.dtb}"
VENDOR_DTB_DIR="${VENDOR_DTB_DIR:-$OUT_DIR/arch/arm64/boot/dts/vendor/qcom}"

# dtbo.img from the Samsung board overlays of this device.
DTBO_IMAGE_OUT="${DTBO_IMAGE_OUT:-$DIST_DIR/dtbo.img}"
DTBO_PAGESIZE="${DTBO_PAGESIZE:-4096}"
DTBO_BUILD_DIR="${DTBO_BUILD_DIR:-$OUT_DIR/arch/arm64/boot/dts/samsung/eureka/${DEVICE_CODENAME}}"

# Optional AVB hash footers (unsigned, partition sizes of the S24 Ultra).
# Not needed on an unlocked bootloader; useful for tools that expect them.
AVB_FOOTER="${AVB_FOOTER:-0}"
BOOT_PARTITION_SIZE="${BOOT_PARTITION_SIZE:-100663296}"
VENDOR_BOOT_PARTITION_SIZE="${VENDOR_BOOT_PARTITION_SIZE:-100663296}"
DTBO_PARTITION_SIZE="${DTBO_PARTITION_SIZE:-16777216}"

# vendor_dlkm / system_dlkm. The stock fstab accepts erofs, ext4 and f2fs.
# ext4 is labeled with e2fsdroid (SELinux contexts as on stock); erofs is
# only labeled when mkfs.erofs supports --file-contexts.
DLKM_FS="${DLKM_FS:-ext4}"
DLKM_TIMESTAMP="${DLKM_TIMESTAMP:-1230768000}"
VENDOR_DLKM_IMAGE_OUT="${VENDOR_DLKM_IMAGE_OUT:-$DIST_DIR/vendor_dlkm.img}"
SYSTEM_DLKM_IMAGE_OUT="${SYSTEM_DLKM_IMAGE_OUT:-$DIST_DIR/system_dlkm.img}"
# Image size in bytes for ext4: the size of the logical partitions in super
# on the S24 Ultra, so the image never overruns them when flashed. Empty:
# size of the stock image if one is given, else payload + DLKM_EXTRA_SIZE_BYTES.
VENDOR_DLKM_IMAGE_SIZE="${VENDOR_DLKM_IMAGE_SIZE-186064896}"
SYSTEM_DLKM_IMAGE_SIZE="${SYSTEM_DLKM_IMAGE_SIZE-123703296}"
DLKM_EXTRA_SIZE_BYTES="${DLKM_EXTRA_SIZE_BYTES:-16777216}"

# Flashable zip (TWRP). Expects update-binary + updater-script in the base dir.
BUILD_FLASHABLE_ZIP="${BUILD_FLASHABLE_ZIP:-0}"
FLASHABLE_ZIP_BASE_DIR="${FLASHABLE_ZIP_BASE_DIR:-$ROOT_DIR/build/flashable_zip_base}"
FLASHABLE_ZIP_OUT="${FLASHABLE_ZIP_OUT:-$DIST_DIR/${DEVICE_CODENAME}_kernel_flashable.zip}"
FLASHABLE_APPEND_DLKM_STANZAS="${FLASHABLE_APPEND_DLKM_STANZAS:-1}"
# vendor_dlkm/system_dlkm are logical partitions inside super.
FLASHABLE_VENDOR_DLKM_BLOCK_DEVICE="${FLASHABLE_VENDOR_DLKM_BLOCK_DEVICE:-/dev/block/mapper/vendor_dlkm}"
FLASHABLE_SYSTEM_DLKM_BLOCK_DEVICE="${FLASHABLE_SYSTEM_DLKM_BLOCK_DEVICE:-/dev/block/mapper/system_dlkm}"

# KernelSU-Next from its official "next" branch. It patches the source tree,
# so it is opt-in.
UPDATE_KERNELSU_NEXT="${UPDATE_KERNELSU_NEXT:-0}"
KERNELSU_NEXT_SETUP_URL="https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/next/kernel/setup.sh"

BUILD_KSU_MODULES="${BUILD_KSU_MODULES:-0}"
KSU_MODULES_SRC_DIR="${KSU_MODULES_SRC_DIR:-$ROOT_DIR/ksu_modules}"
KSU_MODULES_OUT_DIR="${KSU_MODULES_OUT_DIR:-$DIST_DIR}"

# Shark Manager Android application (expected at <kernel root>/sharkmanager).
BUILD_SHARKMANAGER_APK="${BUILD_SHARKMANAGER_APK:-0}"
SHARKMANAGER_DIR="${SHARKMANAGER_DIR:-$ROOT_DIR/sharkmanager}"
SHARKMANAGER_BUILD_TYPE="${SHARKMANAGER_BUILD_TYPE:-debug}"
SHARKMANAGER_GRADLE_TASK="${SHARKMANAGER_GRADLE_TASK:-}"
SHARKMANAGER_ANDROID_SDK="${SHARKMANAGER_ANDROID_SDK:-${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}}"
SHARKMANAGER_GRADLE_USER_HOME="${SHARKMANAGER_GRADLE_USER_HOME:-$OUT_DIR/sharkmanager/gradle-user-home}"
SHARKMANAGER_PROJECT_CACHE_DIR="${SHARKMANAGER_PROJECT_CACHE_DIR:-$OUT_DIR/sharkmanager/project-cache}"
SHARKMANAGER_BUILD_DIR="${SHARKMANAGER_BUILD_DIR:-$OUT_DIR/sharkmanager/app-build}"
SHARKMANAGER_APK_OUT="${SHARKMANAGER_APK_OUT:-}"
SHARKMANAGER_GRADLE_ARGS="${SHARKMANAGER_GRADLE_ARGS:-}"
SHARKMANAGER_CLEAN="${SHARKMANAGER_CLEAN:-1}"
SHARKMANAGER_APK_RESULT=""

SRC_DIR="$ROOT_DIR"
KERNEL_RELEASE=""
STOCK_WORK_DIR="$OUT_DIR/stock"

# ---------------------------------------------------------------------------
# Toolchain
# ---------------------------------------------------------------------------
find_clang_bin() {
  if [[ -n "$CLANG_BIN" ]]; then
    [[ -x "$CLANG_BIN/clang" ]] || return 1
    printf '%s\n' "$CLANG_BIN"
    return 0
  fi
  local d
  for d in \
    "$ROOT_DIR/../prebuilts/clang/host/linux-x86/clang-${CLANG_VERSION}" \
    "$ROOT_DIR/prebuilts/clang/host/linux-x86/clang-${CLANG_VERSION}" \
    "$ROOT_DIR/../toolchains/clang-${CLANG_VERSION}" \
    "$ROOT_DIR/toolchains/clang-${CLANG_VERSION}" \
    "$HOME/toolchains/clang-${CLANG_VERSION}" \
    "$CLANG_FETCH_DIR"; do
    if [[ -x "$d/bin/clang" ]]; then
      printf '%s\n' "$(cd "$d/bin" && pwd)"
      return 0
    fi
  done
  return 1
}

fetch_clang() {
  need_cmd curl
  need_cmd tar
  log "Downloading clang-${CLANG_VERSION} into $CLANG_FETCH_DIR"
  mkdir -p "$CLANG_FETCH_DIR"
  curl -fL --retry 3 "$CLANG_FETCH_URL" | tar xz -C "$CLANG_FETCH_DIR" \
    || die "clang download failed: $CLANG_FETCH_URL"
}

setup_toolchain() {
  local clang_dir
  if ! clang_dir="$(find_clang_bin)"; then
    if [[ "$FETCH_CLANG" == "1" ]]; then
      fetch_clang
      clang_dir="$(find_clang_bin)" || die "clang still not found after download"
    else
      die "clang-${CLANG_VERSION} not found. Set CLANG_BIN=/path/to/clang/bin, or run with FETCH_CLANG=1 to download it to $CLANG_FETCH_DIR"
    fi
  fi
  export PATH="$clang_dir:$PATH"
  export ARCH=arm64 LLVM=1 LLVM_IAS=1
  export CC="$clang_dir/clang"
  export HOSTCC="$clang_dir/clang"
  export HOSTCXX="$clang_dir/clang++"
  export LD="$clang_dir/ld.lld"
  export AR="$clang_dir/llvm-ar"
  export NM="$clang_dir/llvm-nm"
  export STRIP="$clang_dir/llvm-strip"
  export OBJCOPY="$clang_dir/llvm-objcopy"
  export OBJDUMP="$clang_dir/llvm-objdump"
  export READELF="$clang_dir/llvm-readelf"
  # Generate /__symbols__ in every DTB/DTBO (build.config.msm.common).
  export DTC_FLAGS='-@'
  # qcacld-3.0 treats a set ANDROID_BUILD_TOP as "inside an Android tree"
  # and rewrites its include paths; this is a standalone kernel tree.
  unset ANDROID_BUILD_TOP
  log "Using clang: $clang_dir"
  "$CC" --version | head -n1 || true
  if ! "$CC" --version | head -n1 | grep -q "$CLANG_VERSION"; then
    warn "toolchain is not clang-${CLANG_VERSION}; the techpacks build with -Werror and may break with other versions"
  fi
}

# Every make call goes through here so the same variables are always used.
kmake() {
  local -a release_args
  case "$RELEASE_STYLE" in
    stock) release_args=(GOOGLE_BRANCH="$GOOGLE_BRANCH" KMI_GENERATION="$KMI_GENERATION") ;;
    # No Android/Samsung parts: setlocalversion then gives just
    # <version><CONFIG_LOCALVERSION> (LOCALVERSION_AUTO off adds nothing).
    short) release_args=(GOOGLE_BRANCH= KMI_GENERATION= SEC_LOCALVERSION= LOCALVERSION=) ;;
    *) die "RELEASE_STYLE must be short or stock (got: $RELEASE_STYLE)" ;;
  esac
  # shellcheck disable=SC2086
  make -C "$SRC_DIR" O="$OUT_DIR" \
    ARCH=arm64 LLVM=1 LLVM_IAS=1 \
    "${release_args[@]}" \
    KCFLAGS="$KCFLAGS" \
    $EXTRA_MAKE_ARGS "$@"
}

# ---------------------------------------------------------------------------
# Source tree / config
# ---------------------------------------------------------------------------
list_source_tree_dirty_markers() {
  local markers=(
    ".config" ".config.old" "Module.symvers" "modules.order" ".version" ".old_version"
    ".tmp_versions" "include/config" "include/generated" "arch/arm64/include/generated"
  )
  local marker
  for marker in "${markers[@]}"; do
    [[ -e "$SRC_DIR/$marker" ]] && printf '%s\n' "$marker"
  done
}

ensure_clean_source_tree_for_o_build() {
  local probe_out probe_rc
  set +e
  probe_out="$(make -C "$SRC_DIR" O="$OUT_DIR" kernelversion 2>&1)"
  probe_rc=$?
  set -e
  if [[ $probe_rc -eq 0 ]]; then
    return 0
  fi
  if grep -q "The source tree is not clean" <<<"$probe_out"; then
    if [[ "$AUTO_MRPROPER" != "1" ]]; then
      die "source tree is not clean for O= build. Re-run with AUTO_MRPROPER=1 or clean manually with 'make mrproper'."
    fi
    warn "source tree is not clean for O= build; running 'make mrproper' automatically in the source root"
    local markers line
    markers="$(list_source_tree_dirty_markers || true)"
    if [[ -n "$markers" ]]; then
      warn "generated source-tree artifacts detected:"
      while IFS= read -r line; do
        [[ -n "$line" ]] && warn "  - $line"
      done <<<"$markers"
    fi
    make -C "$SRC_DIR" mrproper
    return 0
  fi
  die "kernel O= preflight probe failed:
$probe_out"
}

prepare_dirs() {
  [[ "$CLEAN_BUILD" == "1" ]] && rm -rf "$OUT_DIR" "$DIST_DIR"
  mkdir -p "$OUT_DIR" "$DIST_DIR" "$OUT_DIR/listfiles" "$OUT_DIR/staging"
  rm -rf "$DIST_DIR/sections"
  mkdir -p "$DIST_DIR/sections"
}

update_kernelsu_next() {
  if [[ "$UPDATE_KERNELSU_NEXT" != "1" ]]; then
    log "KernelSU-Next update skipped (UPDATE_KERNELSU_NEXT=$UPDATE_KERNELSU_NEXT)"
    return 0
  fi
  need_cmd curl
  log "Fetching the latest KernelSU-Next from the official next branch"
  (
    cd "$SRC_DIR"
    curl -fLSs --retry 3 "$KERNELSU_NEXT_SETUP_URL" | bash -
  ) || die "KernelSU-Next update failed; stopping before kernel compilation"
  log "KernelSU-Next setup completed"
}

apply_config() {
  [[ -f "$SRC_DIR/arch/arm64/configs/$DEFCONFIG" ]] || die "defconfig not found: arch/arm64/configs/$DEFCONFIG"
  log "Applying defconfig: $DEFCONFIG"
  kmake "$DEFCONFIG"

  if [[ -n "$CONFIG_FRAGMENTS" ]]; then
    local frag
    for frag in $CONFIG_FRAGMENTS; do
      [[ -f "$frag" ]] || die "config fragment not found: $frag"
    done
    log "Merging config fragments: $CONFIG_FRAGMENTS"
    # shellcheck disable=SC2086
    KCONFIG_CONFIG="$OUT_DIR/.config" "$SRC_DIR/scripts/kconfig/merge_config.sh" \
      -m -O "$OUT_DIR" "$OUT_DIR/.config" $CONFIG_FRAGMENTS
  fi

  case "$LTO" in
    keep) ;;
    none) "$SRC_DIR/scripts/config" --file "$OUT_DIR/.config" -d LTO_CLANG_THIN -d LTO_CLANG_FULL -e LTO_NONE ;;
    thin) "$SRC_DIR/scripts/config" --file "$OUT_DIR/.config" -d LTO_NONE -d LTO_CLANG_FULL -e LTO_CLANG_THIN ;;
    full) "$SRC_DIR/scripts/config" --file "$OUT_DIR/.config" -d LTO_NONE -d LTO_CLANG_THIN -e LTO_CLANG_FULL ;;
    *) die "LTO must be keep, none, thin or full (got: $LTO)" ;;
  esac

  kmake olddefconfig
  # kernelrelease reads include/config/auto.conf: refresh it first, or a
  # changed CONFIG_LOCALVERSION shows up only on the next run.
  kmake -s syncconfig
  KERNEL_RELEASE="$(kmake -s kernelrelease 2>/dev/null | tail -n1)"
  [[ -n "$KERNEL_RELEASE" ]] || die "could not determine kernelrelease"
  if (( ${#KERNEL_RELEASE} > 64 )); then
    die "kernel release '$KERNEL_RELEASE' is ${#KERNEL_RELEASE} chars, the limit is 64: shorten CONFIG_LOCALVERSION by $(( ${#KERNEL_RELEASE} - 64 ))"
  fi
  log "Kernel release: $KERNEL_RELEASE"
}

build_kernel() {
  log "Building kernel with goals: $MAKE_GOALS"
  # shellcheck disable=SC2086
  kmake -j"$JOBS" $MAKE_GOALS
  # The release the build actually used (also limited to 64 chars by make).
  if [[ -f "$OUT_DIR/include/config/kernel.release" ]]; then
    KERNEL_RELEASE="$(cat "$OUT_DIR/include/config/kernel.release")"
  fi
}

install_modules_tree() {
  log "Running modules_install (strip, then sign) into $OUT_DIR/install"
  rm -rf "$OUT_DIR/install"
  mkdir -p "$OUT_DIR/install"
  kmake -j"$JOBS" \
    INSTALL_MOD_PATH="$OUT_DIR/install" \
    INSTALL_MOD_STRIP="$INSTALL_MOD_STRIP" \
    DEPMOD=true \
    modules_install
  [[ -d "$OUT_DIR/install/lib/modules/$KERNEL_RELEASE" ]] \
    || die "modules_install did not produce lib/modules/$KERNEL_RELEASE"
}

copy_core_outputs() {
  local candidates=(
    "$OUT_DIR/arch/arm64/boot/$KERNEL_BINARY"
    "$OUT_DIR/System.map"
    "$OUT_DIR/vmlinux"
    "$OUT_DIR/modules.builtin"
    "$OUT_DIR/modules.builtin.modinfo"
    "$OUT_DIR/modules.order"
    "$OUT_DIR/Module.symvers"
    "$OUT_DIR/.config"
  )
  local f
  for f in "${candidates[@]}"; do
    [[ -f "$f" ]] && cp -f "$f" "$DIST_DIR/"
  done
  mkdir -p "$DIST_DIR/dtbs"
  find "$OUT_DIR/arch/arm64/boot/dts/vendor" "$OUT_DIR/arch/arm64/boot/dts/samsung" \
    -type f \( -name '*.dtb' -o -name '*.dtbo' \) -exec cp -f '{}' "$DIST_DIR/dtbs/" ';' 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Build summary / manifest
# ---------------------------------------------------------------------------
preflight_summary() {
  local commit dirty_count clang_bin
  commit="$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  dirty_count="$( { git -C "$ROOT_DIR" status --porcelain 2>/dev/null || true; } | wc -l | tr -d ' ')"

  printf '%s%s%s\n' "$C_BOLD" "Build plan" "$C_RESET"
  if [[ "${dirty_count:-0}" -gt 0 ]]; then
    printf '  source:     %s (%s%s uncommitted%s)\n' "$commit" "$C_YELLOW" "$dirty_count" "$C_RESET"
  else
    printf '  source:     %s\n' "$commit"
  fi
  printf '  device:     %s / %s-%s\n' "$DEVICE_CODENAME" "$TARGET_SOC" "$BUILD_VARIANT"
  printf '  defconfig:  %s (%s)\n' "$DEFCONFIG" \
    "$(sha256sum "$SRC_DIR/arch/arm64/configs/$DEFCONFIG" 2>/dev/null | cut -c1-12)"
  [[ -n "$CONFIG_FRAGMENTS" ]] && printf '  fragments:  %s\n' "$CONFIG_FRAGMENTS"
  printf '  lto:        %s\n' "$LTO"
  printf '  release:    %s style\n' "$RELEASE_STYLE"
  printf '  jobs:       %s\n' "$JOBS"
  printf '  out:        %s\n' "$OUT_DIR"
  printf '  bases:      vendor_boot=%s\n' "${VENDOR_RAMDISK_BASE_DIR:-${STOCK_VENDOR_BOOT_IMG:-<none>}}"
  printf '              vendor_dlkm=%s\n' "${VENDOR_DLKM_BASE_DIR:-${STOCK_VENDOR_DLKM_IMG:-<none>}}"
  printf '              system_dlkm=%s\n' "${SYSTEM_DLKM_BASE_DIR:-${STOCK_SYSTEM_DLKM_IMG:-<none>}}"
  clang_bin="$(find_clang_bin 2>/dev/null || true)"
  if [[ -n "$clang_bin" ]]; then
    printf '  toolchain:  %s\n' "$("$clang_bin/clang" --version 2>/dev/null | head -1)"
  else
    printf '  toolchain:  %sclang-%s not found%s\n' "$C_YELLOW" "$CLANG_VERSION" "$C_RESET"
  fi
  printf '\n'
}

write_build_manifest() {
  local out="$DIST_DIR/build_manifest.txt"
  local commit dirty_count total_elapsed
  commit="$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  dirty_count="$( { git -C "$ROOT_DIR" status --porcelain 2>/dev/null || true; } | wc -l | tr -d ' ')"
  total_elapsed=$((SECONDS - BUILD_START_SECONDS))
  {
    printf 'pineapple kernel build manifest\n'
    printf 'generated:  %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    printf 'source:     %s (%s uncommitted files)\n' "$commit" "${dirty_count:-0}"
    printf 'device:     %s / %s-%s\n' "$DEVICE_CODENAME" "$TARGET_SOC" "$BUILD_VARIANT"
    printf 'kernel:     %s\n' "${KERNEL_RELEASE:-unknown}"
    printf 'defconfig:  %s (%s)\n' "$DEFCONFIG" \
      "$(sha256sum "$SRC_DIR/arch/arm64/configs/$DEFCONFIG" | cut -c1-12)"
    printf 'config:     %s\n' "$(sha256sum "$OUT_DIR/.config" | cut -c1-12)"
    printf 'toolchain:  %s\n' "$("$CC" --version | head -1)"
    printf 'build time: %dm%02ds\n' "$((total_elapsed / 60))" "$((total_elapsed % 60))"
    printf '\nmodules:\n'
    local s
    for s in vendor_boot vendor_dlkm system_dlkm; do
      [[ -f "$DIST_DIR/$s.modules.present" ]] && \
        printf '  %-12s %s\n' "$s" "$(wc -l < "$DIST_DIR/$s.modules.present" | tr -d ' ')"
    done
    printf '\noutputs:\n'
    local f
    for f in "$DIST_DIR/$KERNEL_BINARY" "$BOOT_IMAGE_OUT" "$DTBO_IMAGE_OUT" \
             "$VENDOR_BOOT_IMAGE_OUT" "$VENDOR_DLKM_IMAGE_OUT" "$SYSTEM_DLKM_IMAGE_OUT" \
             "$FLASHABLE_ZIP_OUT"; do
      [[ -f "$f" ]] && printf '  %-9s %s\n' "$(du -h "$f" | cut -f1)" "$(basename "$f")"
    done
  } > "$out"
  log "Wrote build manifest: $out"
}

# ---------------------------------------------------------------------------
# Image tools
# ---------------------------------------------------------------------------
find_tool() {
  # find_tool <override> <name...>
  local override="$1"; shift
  if [[ -n "$override" ]]; then
    [[ -e "$override" ]] || return 1
    printf '%s\n' "$override"
    return 0
  fi
  local n
  for n in "$@"; do
    command -v "$n" >/dev/null 2>&1 && { command -v "$n"; return 0; }
  done
  return 1
}

run_tool() {
  # Runs a tool that may be a python script or an executable.
  local tool="$1"; shift
  if [[ "$tool" == *.py ]]; then
    python3 "$tool" "$@"
  else
    "$tool" "$@"
  fi
}

mkbootimg_cmd() {
  local t
  t="$(find_tool "$MKBOOTIMG" mkbootimg mkbootimg.py)" \
    || die "mkbootimg not found (install android-tools, or set MKBOOTIMG=/path/to/mkbootimg.py)"
  run_tool "$t" "$@"
}

unpack_bootimg_cmd() {
  local t
  t="$(find_tool "$UNPACK_BOOTIMG" unpack_bootimg unpack_bootimg.py)" \
    || die "unpack_bootimg not found (install android-tools, or set UNPACK_BOOTIMG=/path/to/unpack_bootimg.py)"
  run_tool "$t" "$@"
}

mkdtboimg_cmd() {
  local t
  t="$(find_tool "$MKDTBOIMG" mkdtboimg mkdtboimg.py)" \
    || die "mkdtboimg not found (install android-tools, or set MKDTBOIMG=/path/to/mkdtboimg.py)"
  run_tool "$t" "$@"
}

avb_footer() {
  # avb_footer <image> <partition name> <partition size>
  [[ "$AVB_FOOTER" == "1" ]] || return 0
  need_cmd avbtool "android-tools"
  avbtool add_hash_footer --image "$1" --partition_name "$2" --partition_size "$3"
  log "Added AVB hash footer to $(basename "$1")"
}

# Extracts a filesystem image (ext4 or erofs) into a directory.
extract_fs_image() {
  local img="$1" dst="$2"
  rm -rf "$dst"
  mkdir -p "$dst"
  if dumpe2fs -h "$img" >/dev/null 2>&1; then
    need_cmd debugfs "e2fsprogs"
    debugfs -R "rdump / $dst" "$img" >/dev/null 2>&1 \
      || die "debugfs could not extract $img"
  elif command -v fsck.erofs >/dev/null 2>&1 && fsck.erofs "$img" >/dev/null 2>&1; then
    fsck.erofs --extract="$dst" --overwrite "$img" >/dev/null \
      || die "fsck.erofs could not extract $img"
  else
    die "unknown filesystem in $img (expected ext4 or erofs; erofs needs erofs-utils)"
  fi
  rm -rf "$dst/lost+found"
}

# Unpacks STOCK_VENDOR_BOOT_IMG once per build into $STOCK_WORK_DIR.
unpack_stock_vendor_boot() {
  local img="$STOCK_VENDOR_BOOT_IMG"
  local dst="$STOCK_WORK_DIR/vendor_boot"
  [[ -f "$dst/.done" ]] && return 0
  [[ -n "$img" && -f "$img" ]] || return 1
  need_cmd lz4
  need_cmd cpio
  rm -rf "$dst"
  mkdir -p "$dst/ramdisk"
  unpack_bootimg_cmd --boot_img "$img" --out "$dst/unpacked" >/dev/null \
    || die "unpack_bootimg failed for $img"
  local frag
  for frag in "$dst"/unpacked/vendor_ramdisk*; do
    [[ -f "$frag" ]] || continue
    # Samsung's vendor_boot header under-reports the ramdisk size, so the
    # fragment unpack_bootimg writes carries a few bytes of padding after the
    # lz4 stream and lz4 reports "corrupted input" once it is done. Ignore
    # lz4's status and check that cpio actually got an archive.
    ( cd "$dst/ramdisk" && { lz4 -dc "$frag" 2>/dev/null || true; } | cpio -idm --no-absolute-filenames --quiet ) \
      || die "could not extract vendor ramdisk fragment $frag"
  done
  [[ -n "$(ls -A "$dst/ramdisk")" ]] || die "vendor ramdisk of $img extracted to nothing"
  touch "$dst/.done"
}

# ---------------------------------------------------------------------------
# Module staging
# ---------------------------------------------------------------------------
# Index of every installed module: "<basename> <path relative to the
# release directory>".
build_module_index() {
  local rel_dir="$OUT_DIR/install/lib/modules/$KERNEL_RELEASE"
  local idx="$OUT_DIR/listfiles/module.index"
  ( cd "$rel_dir" && find . -type f -name '*.ko' | sed 's#^\./##' | LC_ALL=C sort ) | \
    awk '{ n=$0; sub(".*/", "", n); print n, $0 }' > "$idx"
  local dups
  dups="$(awk '{print $1}' "$idx" | sort | uniq -d)"
  if [[ -n "$dups" ]]; then
    warn "modules with the same file name in different directories (first one wins):"
    printf '%s\n' "$dups" | sed 's/^/    - /' >&2
  fi
  log "Installed modules: $(wc -l < "$idx" | tr -d ' ')"
}

module_path() {
  # module_path <basename> -> absolute path of the installed module
  local rel
  rel="$(awk -v n="$1" '$1 == n { print $2; exit }' "$OUT_DIR/listfiles/module.index")"
  [[ -n "$rel" ]] || return 1
  printf '%s\n' "$OUT_DIR/install/lib/modules/$KERNEL_RELEASE/$rel"
}

module_relpath() {
  awk -v n="$1" '$1 == n { print $2; exit }' "$OUT_DIR/listfiles/module.index"
}

clean_list() {
  # Strips comments/blank lines and paths, keeps the first occurrence.
  awk 'NF && $0 !~ /^[[:space:]]*#/ { n=$1; sub(".*/", "", n); if (!seen[n]++) print n }' "$1"
}

build_module_lists() {
  local L="$OUT_DIR/listfiles"
  local s f
  [[ -d "$MODULE_LISTS_DIR" ]] || die "module lists not found: $MODULE_LISTS_DIR"
  for s in vendor_boot vendor_dlkm system_dlkm; do
    f="$MODULE_LISTS_DIR/$s.modules.list"
    [[ -f "$f" ]] || die "missing $f"
    clean_list "$f" > "$L/$s.list"
  done

  # Built modules that no partition list mentions.
  awk '{print $1}' "$L/module.index" | LC_ALL=C sort -u > "$L/built.list"
  cat "$L/vendor_boot.list" "$L/vendor_dlkm.list" "$L/system_dlkm.list" | LC_ALL=C sort -u > "$L/listed.list"
  LC_ALL=C comm -23 "$L/built.list" "$L/listed.list" > "$L/unlisted.list"
  cp -f "$L/unlisted.list" "$DIST_DIR/unlisted.modules.list"
  if [[ -s "$L/unlisted.list" ]]; then
    log "Built modules not in any stock list: $(wc -l < "$L/unlisted.list" | tr -d ' ') (see $DIST_DIR/unlisted.modules.list, UNLISTED_MODULES=$UNLISTED_MODULES)"
    if [[ "$UNLISTED_MODULES" == "vendor_dlkm" ]]; then
      cat "$L/unlisted.list" >> "$L/vendor_dlkm.list"
    elif [[ "$UNLISTED_MODULES" != "none" ]]; then
      die "UNLISTED_MODULES must be none or vendor_dlkm"
    fi
  fi

  log "List sizes:"
  wc -l "$L/vendor_boot.list" "$L/vendor_dlkm.list" "$L/system_dlkm.list" | sed 's/^/[pineapple-make]   /'
}

# Copies the modules of a list into <dir>, records present/missing.
copy_listed_modules() {
  local name="$1" list="$2" dst="$3"
  local present="$DIST_DIR/$name.modules.present"
  local missing="$DIST_DIR/$name.modules.missing"
  : > "$present"; : > "$missing"
  mkdir -p "$dst"
  local m src
  while IFS= read -r m; do
    [[ -n "$m" ]] || continue
    if src="$(module_path "$m")"; then
      cp -f "$src" "$dst/$m"
      printf '%s\n' "$m" >> "$present"
    else
      printf '%s\n' "$m" >> "$missing"
    fi
  done < "$list"
  report_missing "$name" "$missing"
}

report_missing() {
  local name="$1" missing="$2"
  if [[ -s "$missing" ]]; then
    warn "$name: $(wc -l < "$missing" | tr -d ' ') listed modules were not built:"
    sed 's/^/    - /' "$missing" >&2
    if [[ "$STRICT_MISSING_MODULES" == "1" ]]; then
      die "STRICT_MISSING_MODULES=1 and modules are missing for $name"
    fi
  else
    rm -f "$missing"
  fi
}

# Filters a stock load/order list to modules that exist in <pool> (a file
# with one basename per line), keeping the stock order.
filter_load_list() {
  local src="$1" pool="$2" out="$3"
  if [[ ! -f "$src" ]]; then
    : > "$out"
    return 0
  fi
  clean_list "$src" | awk 'NR == FNR { ok[$1] = 1; next } ($1 in ok)' "$pool" - > "$out"
}

# Runs depmod over a flat module directory. Modules of the other partitions
# are symlinked in for symbol resolution only. As on stock, modules.dep only
# lists this partition's modules and only dependencies that live in it too:
# a dependency in another partition (e.g. a vendor_boot module needed by a
# vendor_dlkm one) was already loaded by an earlier stage, and a path to a
# file that does not exist here would make modprobe fail. Paths are
# rewritten to <prefix>/lib/modules/.
flat_depmod() {
  local name="$1" mod_dir="$2" prefix="$3"
  local root="$OUT_DIR/staging/.depmod_$name"
  local work="$root/lib/modules/$KERNEL_RELEASE"
  local log_file="$OUT_DIR/staging/$name.depmod.log"
  rm -rf "$root"
  mkdir -p "$work"
  find "$mod_dir" -maxdepth 1 -type f -name '*.ko' -exec cp -f '{}' "$work/" ';'
  ( cd "$mod_dir" && find . -maxdepth 1 -name '*.ko' -printf '%f\n' | LC_ALL=C sort ) > "$work/.own"
  cp -f "$work/.own" "$work/modules.order"
  find "$OUT_DIR/install/lib/modules/$KERNEL_RELEASE" -type f -name '*.ko' | while IFS= read -r ko; do
    local b; b="$(basename "$ko")"
    [[ -e "$work/$b" ]] || ln -s "$ko" "$work/$b"
  done
  cp -f "$OUT_DIR/modules.builtin" "$OUT_DIR/modules.builtin.modinfo" "$work/" 2>/dev/null || true

  set +e
  depmod -e -F "$OUT_DIR/System.map" -b "$root" "$KERNEL_RELEASE" > "$log_file" 2>&1
  local rc=$?
  set -e
  if [[ $rc -ne 0 || -s "$log_file" ]]; then
    warn "depmod reported problems for $name (log: $log_file)"
    [[ "$STRICT_DEPMOD" == "1" ]] && { cat "$log_file" >&2; die "STRICT_DEPMOD=1"; }
  fi

  awk -v own="$work/.own" -v pfx="$prefix" '
    BEGIN { while ((getline l < own) > 0) mine[l] = 1 }
    {
      split($0, parts, ":"); n = parts[1]; sub(".*/", "", n)
      if (!(n in mine)) next
      out = pfx "/lib/modules/" n ":"
      for (i = 2; i <= NF; i++) {
        t = $i; sub(".*/", "", t)
        if (t in mine) out = out " " pfx "/lib/modules/" t
      }
      print out
    }' "$work/modules.dep" > "$mod_dir/modules.dep"
  local f
  for f in modules.alias modules.softdep; do
    [[ -f "$work/$f" ]] && cp -f "$work/$f" "$mod_dir/$f"
  done
  rm -rf "$root"
}

stage_vendor_boot() {
  local L="$OUT_DIR/listfiles"
  local dir="$OUT_DIR/staging/vendor_boot/lib/modules"
  rm -rf "$OUT_DIR/staging/vendor_boot"
  copy_listed_modules vendor_boot "$L/vendor_boot.list" "$dir"
  flat_depmod vendor_boot "$dir" ""
  local pool="$DIST_DIR/vendor_boot.modules.present"
  filter_load_list "$MODULE_LISTS_DIR/vendor_boot.modules.load" "$pool" "$dir/modules.load"
  filter_load_list "$MODULE_LISTS_DIR/vendor_boot.modules.load.recovery" "$pool" "$dir/modules.load.recovery"
  [[ -f "$MODULE_LISTS_DIR/vendor_boot.modules.blocklist" ]] && \
    cp -f "$MODULE_LISTS_DIR/vendor_boot.modules.blocklist" "$dir/modules.blocklist"
  rm -rf "$DIST_DIR/sections/vendor_boot"
  mkdir -p "$DIST_DIR/sections/vendor_boot"
  cp -a "$OUT_DIR/staging/vendor_boot/lib" "$DIST_DIR/sections/vendor_boot/"
  log "vendor_boot: $(wc -l < "$pool" | tr -d ' ') modules, $(wc -l < "$dir/modules.load" | tr -d ' ') in modules.load"
}

stage_vendor_dlkm() {
  local L="$OUT_DIR/listfiles"
  local dir="$OUT_DIR/staging/vendor_dlkm/lib/modules"
  rm -rf "$OUT_DIR/staging/vendor_dlkm"
  copy_listed_modules vendor_dlkm "$L/vendor_dlkm.list" "$dir"
  flat_depmod vendor_dlkm "$dir" "/vendor"
  # Like stock, the second stage list also names modules that the first
  # stage (vendor_boot) already loaded.
  cat "$DIST_DIR/vendor_boot.modules.present" "$DIST_DIR/vendor_dlkm.modules.present" \
    "$DIST_DIR/system_dlkm.modules.present" 2>/dev/null | sort -u > "$L/all_present.list"
  filter_load_list "$MODULE_LISTS_DIR/vendor_dlkm.modules.load" "$L/all_present.list" "$dir/modules.load"
  # Stock vendor_dlkm also carries the system_dlkm blocklist.
  [[ -f "$MODULE_LISTS_DIR/vendor_dlkm.modules.blocklist" ]] && \
    cp -f "$MODULE_LISTS_DIR/vendor_dlkm.modules.blocklist" "$dir/modules.blocklist"
  [[ -f "$MODULE_LISTS_DIR/system_dlkm.modules.blocklist" ]] && \
    cp -f "$MODULE_LISTS_DIR/system_dlkm.modules.blocklist" "$dir/system_dlkm.modules.blocklist"
  rm -rf "$DIST_DIR/sections/vendor_dlkm"
  mkdir -p "$DIST_DIR/sections/vendor_dlkm"
  cp -a "$OUT_DIR/staging/vendor_dlkm/lib" "$DIST_DIR/sections/vendor_dlkm/"
  log "vendor_dlkm: $(wc -l < "$DIST_DIR/vendor_dlkm.modules.present" | tr -d ' ') modules, $(wc -l < "$dir/modules.load" | tr -d ' ') in modules.load"
}

# system_dlkm keeps the stock layout: the standard depmod tree under
# lib/modules/<release>/kernel/... plus a flat copy in flatten/lib/modules.
stage_system_dlkm() {
  local L="$OUT_DIR/listfiles"
  local stage="$OUT_DIR/staging/system_dlkm"
  local rel_dir="$stage/lib/modules/$KERNEL_RELEASE"
  local flat="$stage/flatten/lib/modules"
  rm -rf "$stage"
  mkdir -p "$rel_dir" "$flat"
  copy_listed_modules system_dlkm "$L/system_dlkm.list" "$flat"

  local m rel
  : > "$rel_dir/modules.order"
  while IFS= read -r m; do
    rel="$(module_relpath "$m")"
    mkdir -p "$rel_dir/$(dirname "$rel")"
    cp -f "$flat/$m" "$rel_dir/$rel"
    printf '%s\n' "$rel" >> "$rel_dir/modules.order"
  done < "$DIST_DIR/system_dlkm.modules.present"
  cp -f "$OUT_DIR/modules.builtin" "$OUT_DIR/modules.builtin.modinfo" "$rel_dir/" 2>/dev/null || true

  local log_file="$stage/../system_dlkm.depmod.log"
  set +e
  depmod -e -F "$OUT_DIR/System.map" -b "$stage" "$KERNEL_RELEASE" > "$log_file" 2>&1
  local rc=$?
  set -e
  if [[ $rc -ne 0 || -s "$log_file" ]]; then
    warn "depmod reported problems for system_dlkm (log: $log_file)"
    [[ "$STRICT_DEPMOD" == "1" ]] && { cat "$log_file" >&2; die "STRICT_DEPMOD=1"; }
  fi
  rm -f "$rel_dir/modules.order"

  # modules.load in stock order, with tree paths and with flat names.
  filter_load_list "$MODULE_LISTS_DIR/system_dlkm.modules.load" \
    "$DIST_DIR/system_dlkm.modules.present" "$flat/modules.load"
  while IFS= read -r m; do module_relpath "$m"; done < "$flat/modules.load" > "$rel_dir/modules.load"

  # Flat modules.dep with /system/lib/modules paths, like stock.
  awk '{
      out = ""
      for (i = 1; i <= NF; i++) {
        t = $i; c = ""
        if (t ~ /:$/) { c = ":"; sub(/:$/, "", t) }
        sub(".*/", "", t)
        out = out (i > 1 ? " " : "") "/system/lib/modules/" t c
      }
      print out
    }' "$rel_dir/modules.dep" > "$flat/modules.dep"

  rm -rf "$DIST_DIR/sections/system_dlkm"
  mkdir -p "$DIST_DIR/sections/system_dlkm"
  cp -a "$stage/lib" "$stage/flatten" "$DIST_DIR/sections/system_dlkm/"
  log "system_dlkm: $(wc -l < "$DIST_DIR/system_dlkm.modules.present" | tr -d ' ') modules"
}

# ---------------------------------------------------------------------------
# boot.img / dtbo.img / vendor_boot.img
# ---------------------------------------------------------------------------
build_boot_image() {
  [[ "$BUILD_BOOT_IMG" == "1" || "$BUILD_BOOT_IMG" == "auto" ]] || return 0
  [[ -f "$BOOT_KERNEL_IMAGE" ]] || die "boot kernel image not found: $BOOT_KERNEL_IMAGE"
  log "Building boot.img (header v$BOOT_HEADER_VERSION, kernel only)"
  mkbootimg_cmd \
    --header_version "$BOOT_HEADER_VERSION" \
    --kernel "$BOOT_KERNEL_IMAGE" \
    --cmdline "$BOOT_CMDLINE" \
    --os_version "$BOOT_OS_VERSION" \
    --os_patch_level "$BOOT_OS_PATCH_LEVEL" \
    --output "$BOOT_IMAGE_OUT"
  avb_footer "$BOOT_IMAGE_OUT" boot "$BOOT_PARTITION_SIZE"
  log "Created boot.img: $BOOT_IMAGE_OUT"
}

build_dtbo_image() {
  [[ "$BUILD_DTBO_IMG" == "1" || "$BUILD_DTBO_IMG" == "auto" ]] || return 0
  [[ -d "$DTBO_BUILD_DIR" ]] || die "DTBO directory not found: $DTBO_BUILD_DIR"
  local -a dtbos=()
  mapfile -t dtbos < <(find "$DTBO_BUILD_DIR" -maxdepth 1 -type f -name '*.dtbo' | LC_ALL=C sort)
  (( ${#dtbos[@]} > 0 )) || die "no .dtbo files in $DTBO_BUILD_DIR"
  log "Building dtbo.img from ${#dtbos[@]} overlays in $DTBO_BUILD_DIR"
  mkdtboimg_cmd create "$DTBO_IMAGE_OUT" --page_size="$DTBO_PAGESIZE" "${dtbos[@]}"
  avb_footer "$DTBO_IMAGE_OUT" dtbo "$DTBO_PARTITION_SIZE"
  log "Created dtbo.img: $DTBO_IMAGE_OUT"
}

write_vendor_bootconfig() {
  if [[ -n "$VENDOR_BOOTCONFIG_FILE" && -f "$VENDOR_BOOTCONFIG_FILE" ]]; then
    cp -f "$VENDOR_BOOTCONFIG_FILE" "$1"
  else
    printf '%s\n' "$VENDOR_BOOTCONFIG_TEXT" > "$1"
  fi
}

vendor_dtb_file() {
  local out="$1"
  case "$VENDOR_DTB" in
    built)
      : > "$out"
      local n
      for n in $VENDOR_DTB_NAMES; do
        [[ -f "$VENDOR_DTB_DIR/$n" ]] || die "dtb not found: $VENDOR_DTB_DIR/$n"
        cat "$VENDOR_DTB_DIR/$n" >> "$out"
      done
      ;;
    stock)
      unpack_stock_vendor_boot || die "VENDOR_DTB=stock needs STOCK_VENDOR_BOOT_IMG"
      cp -f "$STOCK_WORK_DIR/vendor_boot/unpacked/dtb" "$out"
      ;;
    *)
      [[ -f "$VENDOR_DTB" ]] || die "VENDOR_DTB must be built, stock or an existing file"
      cp -f "$VENDOR_DTB" "$out"
      ;;
  esac
}

vendor_ramdisk_base() {
  local dst="$1"
  rm -rf "$dst"
  mkdir -p "$dst"
  if [[ -n "$VENDOR_RAMDISK_BASE_DIR" ]]; then
    [[ -d "$VENDOR_RAMDISK_BASE_DIR" ]] || die "VENDOR_RAMDISK_BASE_DIR not found: $VENDOR_RAMDISK_BASE_DIR"
    cp -a "$VENDOR_RAMDISK_BASE_DIR/." "$dst/"
  elif unpack_stock_vendor_boot; then
    cp -a "$STOCK_WORK_DIR/vendor_boot/ramdisk/." "$dst/"
  else
    return 1
  fi
  # git only keeps 644/755 modes: restore the stock ones of the ramdisk.
  [[ -d "$dst/system/bin" ]] && chmod 751 "$dst/system/bin"
  local f
  for f in "$dst"/fstab.*; do
    [[ -f "$f" ]] && chmod 750 "$f"
  done
  # Modules always come from this build.
  rm -rf "$dst/lib/modules"
  mkdir -p "$dst/lib/modules"
}

pack_lz4_legacy_cpio() {
  local src_dir="$1" out_file="$2"
  rm -f "$out_file"
  ( cd "$src_dir" && find . ! -name . | LC_ALL=C sort | cpio -o -H newc -R root:root --quiet | lz4 -l -12 --favor-decSpeed > "$out_file" )
}

build_vendor_boot_image() {
  [[ "$BUILD_VENDOR_BOOT_IMG" != "0" ]] || return 0
  local img_root="$OUT_DIR/vendor_bootimg"
  rm -rf "$img_root"
  mkdir -p "$img_root"
  if ! vendor_ramdisk_base "$img_root/ramdisk"; then
    [[ "$BUILD_VENDOR_BOOT_IMG" == "auto" ]] && { warn "vendor_boot.img skipped: set STOCK_DIR (or STOCK_VENDOR_BOOT_IMG / VENDOR_RAMDISK_BASE_DIR)"; return 0; }
    die "vendor_boot.img needs a ramdisk base: set STOCK_DIR, STOCK_VENDOR_BOOT_IMG or VENDOR_RAMDISK_BASE_DIR"
  fi
  need_cmd cpio
  need_cmd lz4
  cp -a "$DIST_DIR/sections/vendor_boot/lib/modules/." "$img_root/ramdisk/lib/modules/"
  pack_lz4_legacy_cpio "$img_root/ramdisk" "$img_root/vendor_ramdisk.lz4"
  vendor_dtb_file "$img_root/dtb"
  write_vendor_bootconfig "$img_root/bootconfig"

  log "Building vendor_boot.img (dtb: $VENDOR_DTB)"
  mkbootimg_cmd \
    --header_version "$VENDOR_BOOT_HEADER_VERSION" \
    --pagesize "$VENDOR_BOOT_PAGESIZE" \
    --base "$VENDOR_BOOT_BASE" \
    --kernel_offset "$VENDOR_BOOT_KERNEL_OFFSET" \
    --ramdisk_offset "$VENDOR_BOOT_RAMDISK_OFFSET" \
    --tags_offset "$VENDOR_BOOT_TAGS_OFFSET" \
    --dtb_offset "$VENDOR_BOOT_DTB_OFFSET" \
    --vendor_cmdline "$VENDOR_BOOT_CMDLINE" \
    --board "$VENDOR_BOOT_BOARD" \
    --dtb "$img_root/dtb" \
    --vendor_bootconfig "$img_root/bootconfig" \
    --ramdisk_type platform \
    --ramdisk_name "" \
    --vendor_ramdisk_fragment "$img_root/vendor_ramdisk.lz4" \
    --vendor_boot "$VENDOR_BOOT_IMAGE_OUT"
  avb_footer "$VENDOR_BOOT_IMAGE_OUT" vendor_boot "$VENDOR_BOOT_PARTITION_SIZE"
  cp -f "$img_root/bootconfig" "$DIST_DIR/vendor-bootconfig.txt"
  log "Created vendor_boot.img: $VENDOR_BOOT_IMAGE_OUT"
}

# ---------------------------------------------------------------------------
# vendor_dlkm.img / system_dlkm.img
# ---------------------------------------------------------------------------
dlkm_base() {
  # dlkm_base <name> <base dir override> <stock image> <dst>
  local name="$1" base_dir="$2" stock_img="$3" dst="$4"
  if [[ -n "$base_dir" ]]; then
    [[ -d "$base_dir" ]] || die "$name base dir not found: $base_dir"
    rm -rf "$dst"; mkdir -p "$dst"
    cp -a "$base_dir/." "$dst/"
  elif [[ -n "$stock_img" && -f "$stock_img" ]]; then
    log "Extracting $name base from $stock_img"
    extract_fs_image "$stock_img" "$dst"
  else
    return 1
  fi
  # Only the non-module files (etc/build.prop, fs_config, ...) are kept.
  rm -rf "$dst/lib/modules" "$dst/flatten"
  mkdir -p "$dst/etc" "$dst/lib/modules"
}

write_file_contexts() {
  local name="$1" out="$2"
  case "$name" in
    vendor_dlkm)
      cat > "$out" <<'EOF'
/vendor_dlkm(/.*)?		u:object_r:vendor_file:s0
/vendor_dlkm/etc(/.*)?		u:object_r:vendor_configs_file:s0
EOF
      ;;
    system_dlkm)
      cat > "$out" <<'EOF'
/system_dlkm(/.*)?		u:object_r:system_dlkm_file:s0
EOF
      ;;
  esac
}

make_dlkm_image() {
  # make_dlkm_image <name> <tree> <out image> <size override> <stock image>
  local name="$1" tree="$2" out="$3" size="$4" stock_img="$5"
  local fc="$OUT_DIR/$name.file_contexts"
  write_file_contexts "$name" "$fc"
  rm -f "$out"

  case "$DLKM_FS" in
    ext4)
      need_cmd mke2fs "e2fsprogs"
      need_cmd e2fsdroid "android-tools"
      local payload
      payload=$(( $(du -sb "$tree" | cut -f1) ))
      if [[ -z "$size" ]]; then
        if [[ -n "$stock_img" && -f "$stock_img" ]]; then
          size=$(stat -c %s "$stock_img")
        else
          size=$(( payload + payload / 5 + DLKM_EXTRA_SIZE_BYTES ))
        fi
      fi
      size=$(( (size + 4095) / 4096 * 4096 ))
      if (( payload + payload / 20 > size )); then
        die "$name payload ($payload bytes) does not fit in $size bytes; set ${name^^}_IMAGE_SIZE (the logical partition may need resizing)"
      fi
      local inodes
      inodes=$(( $(find "$tree" | wc -l) * 2 + 256 ))
      log "Building $name.img (ext4, $size bytes, SELinux labels via e2fsdroid)"
      mke2fs -q -t ext4 -O ^has_journal,^metadata_csum,^64bit,^orphan_file -m 0 -b 4096 -I 256 \
        -N "$inodes" -L "$name" -E lazy_itable_init=0 \
        "$out" "$(( size / 4096 ))" || die "mke2fs failed for $name"
      e2fsdroid -e -T "$DLKM_TIMESTAMP" -S "$fc" -a "/$name" -f "$tree" "$out" \
        || die "e2fsdroid failed for $name"
      ;;
    erofs)
      need_cmd mkfs.erofs "erofs-utils"
      local -a label_args=()
      if mkfs.erofs --help 2>&1 | grep -q -- '--file-contexts'; then
        label_args=(--file-contexts="$fc")
      else
        warn "mkfs.erofs has no --file-contexts support: $name.img will have no SELinux labels (use DLKM_FS=ext4)"
      fi
      log "Building $name.img (erofs)"
      mkfs.erofs -zlz4hc,level=9 -T "$DLKM_TIMESTAMP" -L "$name" \
        --mount-point="/$name" "${label_args[@]}" "$out" "$tree" \
        || die "mkfs.erofs failed for $name"
      ;;
    *) die "DLKM_FS must be ext4 or erofs (got: $DLKM_FS)" ;;
  esac
  log "Created $name.img: $out"
}

build_vendor_dlkm_image() {
  [[ "$BUILD_VENDOR_DLKM_IMG" != "0" ]] || return 0
  local tree="$OUT_DIR/vendor_dlkm_img/vendor_dlkm"
  if ! dlkm_base vendor_dlkm "$VENDOR_DLKM_BASE_DIR" "$STOCK_VENDOR_DLKM_IMG" "$tree"; then
    [[ "$BUILD_VENDOR_DLKM_IMG" == "auto" ]] && { warn "vendor_dlkm.img skipped: set STOCK_DIR (or STOCK_VENDOR_DLKM_IMG / VENDOR_DLKM_BASE_DIR)"; return 0; }
    die "vendor_dlkm.img needs a base: set STOCK_DIR, STOCK_VENDOR_DLKM_IMG or VENDOR_DLKM_BASE_DIR"
  fi
  cp -a "$DIST_DIR/sections/vendor_dlkm/lib/modules/." "$tree/lib/modules/"
  make_dlkm_image vendor_dlkm "$tree" "$VENDOR_DLKM_IMAGE_OUT" "$VENDOR_DLKM_IMAGE_SIZE" "$STOCK_VENDOR_DLKM_IMG"
}

build_system_dlkm_image() {
  [[ "$BUILD_SYSTEM_DLKM_IMG" != "0" ]] || return 0
  local tree="$OUT_DIR/system_dlkm_img/system_dlkm"
  if ! dlkm_base system_dlkm "$SYSTEM_DLKM_BASE_DIR" "$STOCK_SYSTEM_DLKM_IMG" "$tree"; then
    [[ "$BUILD_SYSTEM_DLKM_IMG" == "auto" ]] && { warn "system_dlkm.img skipped: set STOCK_DIR (or STOCK_SYSTEM_DLKM_IMG / SYSTEM_DLKM_BASE_DIR)"; return 0; }
    die "system_dlkm.img needs a base: set STOCK_DIR, STOCK_SYSTEM_DLKM_IMG or SYSTEM_DLKM_BASE_DIR"
  fi
  rm -rf "$tree/lib/modules"
  cp -a "$DIST_DIR/sections/system_dlkm/lib" "$DIST_DIR/sections/system_dlkm/flatten" "$tree/"
  make_dlkm_image system_dlkm "$tree" "$SYSTEM_DLKM_IMAGE_OUT" "$SYSTEM_DLKM_IMAGE_SIZE" "$STOCK_SYSTEM_DLKM_IMG"
}

# ---------------------------------------------------------------------------
# Flashable zip / KSU modules / Shark Manager
# ---------------------------------------------------------------------------
build_flashable_zip() {
  [[ "$BUILD_FLASHABLE_ZIP" == "1" ]] || return 0
  need_cmd zip
  local zip_root="$OUT_DIR/flashable_zip"
  local updater_script="$zip_root/META-INF/com/google/android/updater-script"
  rm -rf "$zip_root"
  mkdir -p "$zip_root/files" "$zip_root/META-INF/com/google/android"

  [[ -d "$FLASHABLE_ZIP_BASE_DIR" ]] || die "flashable zip base dir not found: $FLASHABLE_ZIP_BASE_DIR"
  [[ -f "$FLASHABLE_ZIP_BASE_DIR/update-binary" ]] || die "missing update-binary in $FLASHABLE_ZIP_BASE_DIR"
  [[ -f "$FLASHABLE_ZIP_BASE_DIR/updater-script" ]] || die "missing updater-script in $FLASHABLE_ZIP_BASE_DIR"

  local img
  for img in "$BOOT_IMAGE_OUT" "$VENDOR_BOOT_IMAGE_OUT" "$DTBO_IMAGE_OUT" \
             "$VENDOR_DLKM_IMAGE_OUT" "$SYSTEM_DLKM_IMAGE_OUT"; do
    [[ -f "$img" ]] && cp -f "$img" "$zip_root/files/$(basename "$img")"
  done
  [[ -f "$DIST_DIR/build_manifest.txt" ]] && cp -f "$DIST_DIR/build_manifest.txt" "$zip_root/build_manifest.txt"
  cp -f "$FLASHABLE_ZIP_BASE_DIR/update-binary" "$zip_root/META-INF/com/google/android/update-binary"
  cp -f "$FLASHABLE_ZIP_BASE_DIR/updater-script" "$updater_script"

  if [[ "$FLASHABLE_APPEND_DLKM_STANZAS" == "1" ]]; then
    if [[ -f "$zip_root/files/vendor_dlkm.img" ]] && ! grep -q 'vendor_dlkm.img' "$updater_script"; then
      printf '\nui_print("Flashing vendor_dlkm image...");\nrun_program("/system/bin/blockdev", "--setrw", "%s");\npackage_extract_file("files/vendor_dlkm.img", "%s");\n' \
        "$FLASHABLE_VENDOR_DLKM_BLOCK_DEVICE" "$FLASHABLE_VENDOR_DLKM_BLOCK_DEVICE" >> "$updater_script"
    fi
    if [[ -f "$zip_root/files/system_dlkm.img" ]] && ! grep -q 'system_dlkm.img' "$updater_script"; then
      printf '\nui_print("Flashing system_dlkm image...");\nrun_program("/system/bin/blockdev", "--setrw", "%s");\npackage_extract_file("files/system_dlkm.img", "%s");\n' \
        "$FLASHABLE_SYSTEM_DLKM_BLOCK_DEVICE" "$FLASHABLE_SYSTEM_DLKM_BLOCK_DEVICE" >> "$updater_script"
    fi
  fi

  # Fail now, not halfway through a flash, if the script references files
  # this build did not produce.
  local -a missing=()
  while read -r img; do
    [[ -n "$img" ]] || continue
    [[ -f "$zip_root/$img" ]] || missing+=("$img")
  done < <(grep -oE 'package_extract_file\("[^"]+"' "$updater_script" | sed -E 's/package_extract_file\("//; s/"$//')
  if (( ${#missing[@]} )); then
    die "updater-script flashes files not present in the zip: ${missing[*]}"
  fi

  printf '\nui_print(" ");\nui_print("Installation done!");\nui_print(" ");\n' >> "$updater_script"

  ( cd "$zip_root" && rm -f "$FLASHABLE_ZIP_OUT" && zip -r -qq "$FLASHABLE_ZIP_OUT" . )
  log "Created flashable zip: $FLASHABLE_ZIP_OUT"
}

build_ksu_modules() {
  [[ "$BUILD_KSU_MODULES" == "1" ]] || return 0
  [[ -d "$KSU_MODULES_SRC_DIR" ]] || return 0
  need_cmd zip
  local mod_dir mod_id out_zip
  for mod_dir in "$KSU_MODULES_SRC_DIR"/*/; do
    [[ -f "${mod_dir}module.prop" ]] || continue
    mod_id="$(basename "$mod_dir")"
    out_zip="$KSU_MODULES_OUT_DIR/${mod_id}.zip"
    mkdir -p "$KSU_MODULES_OUT_DIR"
    rm -f "$out_zip"
    ( cd "$mod_dir" && zip -r -qq "$out_zip" . )
    log "Created KernelSU module zip: $out_zip"
  done
}

find_sharkmanager_android_sdk() {
  local candidate
  if [[ -n "$SHARKMANAGER_ANDROID_SDK" && -d "$SHARKMANAGER_ANDROID_SDK" ]]; then
    printf '%s\n' "$SHARKMANAGER_ANDROID_SDK"
    return 0
  fi
  for candidate in "${ANDROID_SDK_ROOT:-}" "${ANDROID_HOME:-}" "$HOME/Android/Sdk" \
    "$HOME/Android/sdk" "$HOME/android-sdk" "/opt/android-sdk" "/opt/android-sdk-linux" \
    "/usr/lib/android-sdk"; do
    [[ -n "$candidate" && -d "$candidate" ]] || continue
    printf '%s\n' "$candidate"
    return 0
  done
  return 1
}

get_java_major_version() {
  local version
  version="$(java -XshowSettings:properties -version 2>&1 \
    | awk -F= '/^[[:space:]]*java\.specification\.version[[:space:]]*=/{gsub(/[[:space:]]/, "", $2); print $2; exit}')"
  [[ -n "$version" ]] || return 1
  version="${version#1.}"
  printf '%s\n' "${version%%.*}"
}

preflight_sharkmanager() {
  [[ "$BUILD_SHARKMANAGER_APK" == "1" ]] || return 0
  [[ -d "$SHARKMANAGER_DIR" ]] || die "Shark Manager source not found: $SHARKMANAGER_DIR"
  [[ -f "$SHARKMANAGER_DIR/settings.gradle" ]] || die "invalid Shark Manager project: missing settings.gradle"
  [[ -f "$SHARKMANAGER_DIR/app/build.gradle" ]] || die "invalid Shark Manager project: missing app/build.gradle"
  [[ -f "$SHARKMANAGER_DIR/gradlew" ]] || die "invalid Shark Manager project: missing gradlew"
  chmod +x "$SHARKMANAGER_DIR/gradlew"
  need_cmd java
  local java_major sdk required_api
  java_major="$(get_java_major_version)" || die "could not determine Java version"
  [[ "$java_major" =~ ^[0-9]+$ ]] || die "invalid Java major version: $java_major"
  (( java_major >= 17 )) || die "Shark Manager requires Java 17 or newer; found Java $java_major"
  sdk="$(find_sharkmanager_android_sdk)" || die "Android SDK not found. Set SHARKMANAGER_ANDROID_SDK, ANDROID_SDK_ROOT, or ANDROID_HOME."
  SHARKMANAGER_ANDROID_SDK="$(cd "$sdk" && pwd)"
  export ANDROID_SDK_ROOT="$SHARKMANAGER_ANDROID_SDK"
  export ANDROID_HOME="$SHARKMANAGER_ANDROID_SDK"
  required_api="$(sed -nE 's/^[[:space:]]*compileSdk[[:space:]]+([0-9]+).*/\1/p' "$SHARKMANAGER_DIR/app/build.gradle" | head -n1)"
  if [[ -n "$required_api" && ! -f "$SHARKMANAGER_ANDROID_SDK/platforms/android-${required_api}/android.jar" ]]; then
    die "Android SDK platform android-${required_api} is missing from $SHARKMANAGER_ANDROID_SDK"
  fi
  if [[ -z "$SHARKMANAGER_GRADLE_TASK" ]]; then
    SHARKMANAGER_GRADLE_TASK=":app:assemble${SHARKMANAGER_BUILD_TYPE^}"
  fi
  log "Shark Manager preflight: Java ${java_major}, SDK ${SHARKMANAGER_ANDROID_SDK}, task ${SHARKMANAGER_GRADLE_TASK}"
}

build_sharkmanager_apk() {
  [[ "$BUILD_SHARKMANAGER_APK" == "1" ]] || return 0
  mkdir -p "$SHARKMANAGER_GRADLE_USER_HOME" "$SHARKMANAGER_PROJECT_CACHE_DIR" \
    "$(dirname "$SHARKMANAGER_BUILD_DIR")" "$DIST_DIR"
  if [[ "$SHARKMANAGER_CLEAN" == "1" ]]; then
    rm -rf "$SHARKMANAGER_BUILD_DIR" "$SHARKMANAGER_PROJECT_CACHE_DIR"
    mkdir -p "$SHARKMANAGER_PROJECT_CACHE_DIR"
  fi
  local -a gradle_extra_args=()
  [[ -n "$SHARKMANAGER_GRADLE_ARGS" ]] && read -r -a gradle_extra_args <<< "$SHARKMANAGER_GRADLE_ARGS"
  log "Building Shark Manager APK with ${SHARKMANAGER_GRADLE_TASK}"
  (
    cd "$SHARKMANAGER_DIR"
    unset ARCH LLVM LLVM_IAS CROSS_COMPILE CC HOSTCC HOSTCXX LD AR NM STRIP \
      OBJCOPY OBJDUMP READELF DTC_FLAGS
    GRADLE_USER_HOME="$SHARKMANAGER_GRADLE_USER_HOME" \
    SHARKMANAGER_BUILD_DIR="$SHARKMANAGER_BUILD_DIR" \
    ANDROID_SDK_ROOT="$SHARKMANAGER_ANDROID_SDK" \
    ANDROID_HOME="$SHARKMANAGER_ANDROID_SDK" \
      ./gradlew --no-daemon --console=plain \
        --project-cache-dir "$SHARKMANAGER_PROJECT_CACHE_DIR" \
        "$SHARKMANAGER_GRADLE_TASK" "${gradle_extra_args[@]}"
  )
  local -a apks=()
  mapfile -t apks < <(find "$SHARKMANAGER_BUILD_DIR/outputs/apk" -type f -name '*.apk' -printf '%T@ %p\n' 2>/dev/null \
    | sort -nr | cut -d' ' -f2-)
  (( ${#apks[@]} > 0 )) || die "Gradle finished but no APK was found under $SHARKMANAGER_BUILD_DIR/outputs/apk"
  local destination_apk="${SHARKMANAGER_APK_OUT:-$DIST_DIR/$(basename "${apks[0]}")}"
  mkdir -p "$(dirname "$destination_apk")"
  cp -f "${apks[0]}" "$destination_apk"
  SHARKMANAGER_APK_RESULT="$destination_apk"
  log "Created Shark Manager APK: $SHARKMANAGER_APK_RESULT"
}

# ---------------------------------------------------------------------------
out_line() {
  [[ -f "$1" ]] || return 0
  printf '  %s%-9s%s %s\n' "$C_DIM" "$(du -h "$1" | cut -f1)" "$C_RESET" "$1"
}

summarize() {
  local total_elapsed=$((SECONDS - BUILD_START_SECONDS))
  printf '\n%s%s%s\n' "$C_BOLD$C_GREEN" "Build complete" "$C_RESET"
  printf '  kernel:     %s\n' "$KERNEL_RELEASE"
  printf '  total time: %dm%02ds\n\n' "$((total_elapsed / 60))" "$((total_elapsed % 60))"
  printf '%sKey outputs:%s\n' "$C_BOLD" "$C_RESET"
  out_line "$DIST_DIR/$KERNEL_BINARY"
  local s
  for s in vendor_boot vendor_dlkm system_dlkm; do
    [[ -d "$DIST_DIR/sections/$s" ]] && printf '  %s%-9s%s sections/%s\n' "$C_DIM" \
      "$(du -sh "$DIST_DIR/sections/$s" | cut -f1)" "$C_RESET" "$s"
  done
  out_line "$BOOT_IMAGE_OUT"
  out_line "$DTBO_IMAGE_OUT"
  out_line "$VENDOR_BOOT_IMAGE_OUT"
  out_line "$VENDOR_DLKM_IMAGE_OUT"
  out_line "$SYSTEM_DLKM_IMAGE_OUT"
  out_line "$FLASHABLE_ZIP_OUT"
  if [[ "$BUILD_KSU_MODULES" == "1" && -d "$KSU_MODULES_SRC_DIR" ]]; then
    local mod_dir
    for mod_dir in "$KSU_MODULES_SRC_DIR"/*/; do
      [[ -f "${mod_dir}module.prop" ]] && out_line "$KSU_MODULES_OUT_DIR/$(basename "$mod_dir").zip"
    done
  fi
  out_line "$DIST_DIR/build_manifest.txt"
  [[ -n "$SHARKMANAGER_APK_RESULT" ]] && out_line "$SHARKMANAGER_APK_RESULT"
  local f
  for f in "$DIST_DIR"/*.modules.missing; do
    [[ -f "$f" ]] && printf '  %swarning:%s %s\n' "$C_YELLOW" "$C_RESET" "$f"
  done
  return 0
}

main() {
  local c
  for c in bash make python3 grep awk sed find xargs depmod sort comm; do
    need_cmd "$c"
  done
  [[ -d "$MODULE_LISTS_DIR" ]] || die "module lists dir not found: $MODULE_LISTS_DIR"

  prepare_dirs
  preflight_summary
  run_phase "Update KernelSU-Next"          update_kernelsu_next
  run_phase "Shark Manager preflight"       preflight_sharkmanager
  run_phase "Toolchain setup"               setup_toolchain
  run_phase "Source tree check"             ensure_clean_source_tree_for_o_build
  run_phase "Apply kernel config"           apply_config
  run_phase "Compile kernel + modules"      build_kernel
  run_phase "Install modules tree"          install_modules_tree
  run_phase "Copy core outputs"             copy_core_outputs
  run_phase "Index modules"                 build_module_index
  run_phase "Build module lists"            build_module_lists
  run_phase "Stage vendor_boot modules"     stage_vendor_boot
  run_phase "Stage system_dlkm modules"     stage_system_dlkm
  run_phase "Stage vendor_dlkm modules"     stage_vendor_dlkm
  run_phase "Build boot.img"                build_boot_image
  run_phase "Build dtbo.img"                build_dtbo_image
  run_phase "Build vendor_boot.img"         build_vendor_boot_image
  run_phase "Build vendor_dlkm.img"         build_vendor_dlkm_image
  run_phase "Build system_dlkm.img"         build_system_dlkm_image
  write_build_manifest
  run_phase "Package flashable zip"         build_flashable_zip
  run_phase "Package KernelSU modules"      build_ksu_modules
  run_phase "Build Shark Manager APK"       build_sharkmanager_apk

  summarize
}

main "$@"
