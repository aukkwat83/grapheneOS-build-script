#!/usr/bin/env bash
# =====================================================================
# one-all-stop-build-grapheneos-on-guixsystem-150withgpg.sh
#
# One-stop script: Guix System  ->  flashable GrapheneOS
# (custom AVB key, ไม่มี OTA in-place) แปลงมาจาก Ubuntu script
#
# วิธีใช้ (รันเป็น user ธรรมดา — Guix ไม่ต้องพึ่งพา sudo):
#   ./one-all-stop-build-grapheneos-on-guixsystem-150withgpg.sh husky
#   ./one-all-stop-build-grapheneos-on-guixsystem-150withgpg.sh husky tangorpro
#
# Env override (เหมือน Ubuntu script):
#   GOS_TAG=2026042100         GrapheneOS source tag
#   BUILD_ROOT=$HOME/grapheneos
#   ADEV_DL=$HOME/adevtool-downloads
#   CCACHE_DIR=$HOME/.cache/ccache
#   CCACHE_SIZE=50G
#   GIT_NAME / GIT_EMAIL       ใช้ตั้ง git identity ครั้งแรก
#   ASSUME_YES=1               ตอบ yes อัตโนมัติเมื่อ disk ไม่พอ
#   SKIP_SYNC=1                ข้าม repo init/sync (ถ้าทำไว้แล้ว)
#   CLEAN_OUT_AFTER=1          ลบ out/target/product/<DEV>/ หลัง build เพื่อเซฟ disk
#   LOG_FILE=$HOME/gos-build.log
#   GPG_RECIPIENT=<key-id|email>  ใช้ public key encrypt (asymmetric, แนะนำ)
#   GPG_PASSPHRASE=<passphrase>   ถ้าไม่ตั้ง GPG_RECIPIENT จะใช้ symmetric AES256
#   GPG_OUT_DIR=$HOME             โฟลเดอร์เก็บไฟล์ .tar.gpg (default = $HOME)
#   SKIP_GPG=1                    ข้าม pack/encrypt ขั้นตอนสุดท้าย
#   FORCE_REBUILD=1               บังคับ build ใหม่แม้พบ artifact เดิมที่พร้อม flash
# =====================================================================

set -o errexit -o nounset -o pipefail

# -------- ค่าตั้งต้น --------
GOS_TAG="${GOS_TAG:-2026042100}"
BUILD_ROOT="${BUILD_ROOT:-$HOME/grapheneos}"
ADEV_DL="${ADEV_DL:-$HOME/adevtool-downloads}"
CCACHE_DIR_VAR="${CCACHE_DIR:-$BUILD_ROOT/.ccache}"
CCACHE_SIZE="${CCACHE_SIZE:-50G}"
ASSUME_YES="${ASSUME_YES:-0}"
SKIP_SYNC="${SKIP_SYNC:-0}"
CLEAN_OUT_AFTER="${CLEAN_OUT_AFTER:-auto}"
LOG_FILE="${LOG_FILE:-$HOME/gos-build-$(date +%Y%m%d-%H%M%S).log}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_SRC="$SCRIPT_DIR/patch-grapheneos.sh"

# -------- สี / log --------
c_red=$'\e[1;31m'; c_grn=$'\e[1;32m'; c_ylw=$'\e[1;33m'; c_blu=$'\e[1;34m'; c_cyn=$'\e[1;36m'; c_off=$'\e[0m'
log()   { printf '%s[+]%s %s\n' "$c_grn" "$c_off" "$*"; }
warn()  { printf '%s[!]%s %s\n' "$c_ylw" "$c_off" "$*" >&2; }
info()  { printf '%s[i]%s %s\n' "$c_blu" "$c_off" "$*"; }
step()  { printf '\n%s==== %s ====%s\n' "$c_cyn" "$*" "$c_off"; }
die()   { printf '%s[x]%s %s\n' "$c_red" "$c_off" "$*" >&2; exit 1; }

ask_yes() {
    local prompt="$1"
    if [[ "$ASSUME_YES" == "1" ]]; then info "auto-yes: $prompt"; return 0; fi
    if [[ ! -t 0 ]]; then warn "non-TTY → ถือเป็น 'no' ($prompt)"; return 1; fi
    read -r -p "$prompt [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]]
}

_started_at=$(date -Iseconds 2>/dev/null || date)

# -------- pre-flight --------
[[ "$EUID" -ne 0 ]] || die "ห้ามรันเป็น root — รันเป็น user ปกติ (Guix ไม่ต้อง sudo)"
[[ $# -ge 1 ]]      || die "ระบุ codename อย่างน้อย 1 ตัว เช่น: $0 husky"
[[ -f "$PATCH_SRC" ]] || die "ไม่พบ patch-grapheneos.sh ที่ $PATCH_SRC"

DEVICES=("$@")

# log ทุกอย่างไปไฟล์ด้วย
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1
info "Log file: $LOG_FILE"

# -------- pre-check: มี build พร้อม flash อยู่แล้วไหม? --------
FORCE_REBUILD="${FORCE_REBUILD:-0}"
SKIP_BUILD=0
BUILD_NUMBER=""
declare -a OUT_PATHS=()

if [[ "$FORCE_REBUILD" == "1" ]]; then
    info "FORCE_REBUILD=1 — ข้าม pre-check ของ artifact เดิม"
elif [[ -d "$BUILD_ROOT/releases" ]]; then
    step "PRE-CHECK — ตรวจหา build เดิมที่พร้อม flash"
    declare -a _found_paths=()
    declare -a _found_bn=()
    _all_ok=1
    for _D in "${DEVICES[@]}"; do
        _latest=""
        for _cand in $(ls -d "$BUILD_ROOT/releases/"*/"release-${_D}-"*/ 2>/dev/null | sort -r); do
            _bn=$(basename "$(dirname "$_cand")")
            _has_install=0
            [[ -f "${_cand}${_D}-install-${_bn}.zip" ]] && _has_install=1
            [[ -x "${_cand}${_D}-install-${_bn}/flash-all.sh" ]] && _has_install=1
            if [[ -f "${_cand}${_D}-factory-${_bn}.zip" \
                  && -f "${_cand}${_D}-ota_update-${_bn}.zip" \
                  && "$_has_install" == "1" ]]; then
                _latest="$_cand"
                break
            fi
        done
        if [[ -n "$_latest" ]]; then
            _found_paths+=("${_latest%/}")
            _found_bn+=("$(basename "$(dirname "$_latest")")")
            info "พบ [$_D]: $_latest"
        else
            warn "ไม่พบ build พร้อม flash สำหรับ [$_D]"
            _all_ok=0
        fi
    done

    if [[ "$_all_ok" == "1" ]]; then
        _bn0="${_found_bn[0]}"
        _consistent=1
        for _b in "${_found_bn[@]}"; do
            [[ "$_b" == "$_bn0" ]] || _consistent=0
        done
        _keys_ok=1
        for _D in "${DEVICES[@]}"; do
            for _K in bluetooth gmscompat_lib media networkstack nfc platform releasekey sdk_sandbox shared; do
                [[ -f "$BUILD_ROOT/keys/$_D/$_K.pk8" && -f "$BUILD_ROOT/keys/$_D/$_K.x509.pem" ]] || _keys_ok=0
            done
            [[ -f "$BUILD_ROOT/keys/$_D/avb_pkmd.bin" ]] || _keys_ok=0
        done

        if [[ "$_consistent" == "1" && "$_keys_ok" == "1" ]]; then
            log "พบ build $_bn0 พร้อม flash ครบทุก device + keys ครบ"
            if ask_yes "ข้าม build แล้วไป pack GPG เลย? (กด N เพื่อ build ใหม่)"; then
                SKIP_BUILD=1
                BUILD_NUMBER="$_bn0"
                OUT_PATHS=("${_found_paths[@]}")
            else
                info "ผู้ใช้เลือก build ใหม่"
            fi
        else
            [[ "$_consistent" != "1" ]] && warn "build numbers ไม่ตรงกันทุก device — จะ build ใหม่"
            [[ "$_keys_ok"    != "1" ]] && warn "keys/ ไม่ครบ — จะ build ใหม่"
        fi
    fi
fi

if [[ "$SKIP_BUILD" == "1" ]]; then
    info "ข้าม STEP 0-8 — ใช้ artifact เดิม build $BUILD_NUMBER"
fi

# verify Guix System
if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    if [[ "${ID:-}" == "guix" ]]; then
        info "OS: ${PRETTY_NAME:-Guix System} ✓"
    else
        warn "OS ไม่ใช่ Guix System (เห็น ${PRETTY_NAME:-unknown}) — script ทดสอบกับ Guix System เท่านั้น"
        ask_yes "ดำเนินการต่อ?" || die "ยกเลิกตามคำสั่งผู้ใช้"
    fi
else
    warn "อ่าน /etc/os-release ไม่ได้ — ข้าม OS check"
fi

# Guix ไม่ต้อง sudo keepalive — ข้ามไป
# trap: log สถานะสุดท้าย
trap '_rc=$?; printf "\n%s[exit]%s rc=%d  started=%s ended=%s\n" "$([[ $_rc -eq 0 ]] && echo "$c_grn" || echo "$c_red")" "$c_off" "$_rc" "$_started_at" "$(date -Iseconds 2>/dev/null || date)"; exit $_rc' EXIT

if [[ "$SKIP_BUILD" != "1" ]]; then
# -------- detect spec --------
step "STEP 0/8 — ตรวจ spec เครื่อง + คำนวณ build params"
CPU_CORES=$(nproc)
MEM_GB=$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo)
SWAP_GB=$(awk '/SwapTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo)
mkdir -p "$(dirname "$BUILD_ROOT")"
DISK_TARGET="$(dirname "$BUILD_ROOT")"
DISK_AVAIL_GB=$(df -BG --output=avail "$DISK_TARGET" | tail -1 | tr -dc '0-9')

# คำนวณ -j เหมือน Ubuntu script
J_BY_RAM=$(( (MEM_GB - 4) / 4 ))
[[ $J_BY_RAM -lt 1 ]] && J_BY_RAM=1
JOBS=$(( J_BY_RAM < CPU_CORES ? J_BY_RAM : CPU_CORES ))
[[ $JOBS -lt 1 ]] && JOBS=1

# disk math
NUM_DEV=${#DEVICES[@]}
DISK_SOURCE_GB=170
DISK_PER_DEV_GB=140
EXISTING_GB=0
if [[ -d "$BUILD_ROOT/.repo" ]]; then
    EXISTING_GB=$(du -BG -s "$BUILD_ROOT" 2>/dev/null | awk '{gsub(/G/,"",$1); print $1}')
    [[ -z "$EXISTING_GB" ]] && EXISTING_GB=0
fi
DISK_PARALLEL_GB=$(( DISK_SOURCE_GB + NUM_DEV * DISK_PER_DEV_GB - EXISTING_GB ))
DISK_SERIAL_GB=$(( DISK_SOURCE_GB + DISK_PER_DEV_GB - EXISTING_GB ))
[[ $DISK_PARALLEL_GB -lt 50 ]] && DISK_PARALLEL_GB=50
[[ $DISK_SERIAL_GB   -lt 50 ]] && DISK_SERIAL_GB=50

cat <<EOF

  CPU cores      : $CPU_CORES
  RAM            : ${MEM_GB} GB  (swap ${SWAP_GB} GB)
  Disk available : ${DISK_AVAIL_GB} GB  @ ${DISK_TARGET}
  Devices        : ${DEVICES[*]} (${NUM_DEV})
  Build parallel : -j${JOBS}  (limited by $([[ $J_BY_RAM -lt $CPU_CORES ]] && echo RAM || echo CPU))
  Disk if parallel : ~${DISK_PARALLEL_GB} GB
  Disk if serial   : ~${DISK_SERIAL_GB} GB (clean out/ ระหว่าง devices)
  ccache         : ${CCACHE_DIR_VAR} (size ${CCACHE_SIZE})

EOF

# OOM check
if [[ $MEM_GB -lt 16 && $((MEM_GB + SWAP_GB)) -lt 24 ]]; then
    warn "RAM+Swap น้อยกว่า 24GB — build อาจ OOM"
    if [[ $((MEM_GB + SWAP_GB)) -lt 16 ]]; then
        warn "Guix System: ต้องเพิ่ม swap ด้วยตัวเอง (ไม่มี sudo อัตโนมัติ)"
        warn "เพิ่ม swap file 8GB ด้วย: su -c 'fallocate -l 8G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile'"
        ask_yes "RAM ตึง — ดำเนินการต่อ?" || die "ยกเลิก"
    else
        ask_yes "RAM ตึง — ดำเนินการต่อ?" || die "ยกเลิก"
    fi
fi

# Disk strategy
NEED_GB=$DISK_PARALLEL_GB
if [[ $DISK_AVAIL_GB -lt $NEED_GB ]]; then
    if [[ $DISK_AVAIL_GB -ge $DISK_SERIAL_GB ]]; then
        warn "Disk ${DISK_AVAIL_GB}GB ไม่พอ build parallel (${DISK_PARALLEL_GB}GB) แต่พอ build serial (${DISK_SERIAL_GB}GB)"
        info "→ จะ build ทีละ device แล้ว clean out/<DEV> ก่อน device ถัดไป"
        [[ "$CLEAN_OUT_AFTER" == "auto" ]] && CLEAN_OUT_AFTER=1
        ask_yes "ดำเนินการต่อ?" || die "ยกเลิก"
    else
        warn "Disk ${DISK_AVAIL_GB}GB ไม่พอแม้ build serial (${DISK_SERIAL_GB}GB)"
        warn "ต้องการอย่างน้อย ~${DISK_SERIAL_GB}GB ที่ ${DISK_TARGET}"
        ask_yes "ยังจะลองต่อ (อาจเต็ม disk กลางทาง)?" || die "ยกเลิกตามคำสั่งผู้ใช้"
        [[ "$CLEAN_OUT_AFTER" == "auto" ]] && CLEAN_OUT_AFTER=1
    fi
else
    [[ "$CLEAN_OUT_AFTER" == "auto" ]] && CLEAN_OUT_AFTER=0
fi

# -------- STEP 1: ติดตั้ง dependencies ผ่าน Guix --------
step "STEP 1/8 — ติดตั้ง dependencies (guix shell profile)"

# สร้าง Guix profile สำหรับ build environment
GUIX_PROFILE="$BUILD_ROOT/.guix-profile"
mkdir -p "$BUILD_ROOT"

# รายการ package ที่ต้องการจาก Guix channels
# อ้างอิง Ubuntu packages แปลงเป็น Guix packages:
# - build-essential → gcc-toolchain, make, binutils
# - openjdk-21-jdk → openjdk:jdk (หรือ openjdk@21 ถ้ามี)
# - python-is-python3 → python, python-wrapper
# - lib32z1-dev, lib32readline-dev → ใช้ glibc:lib แทน (multilib)
# - android-sdk-platform-tools-common → adb, fastboot (ใน android-udev-rules หรือ android-tools)

info "กำลังสร้าง Guix environment profile..."

# ลองหา package ที่มีใน Guix ก่อน
# Note: Guix มี Node.js 24.x แล้ว (ไม่ต้องติดตั้งแยก)
# Note: ccache, git, curl, rsync, imagemagick มีครบใน Guix channel
GUIX_PACKAGES=(
    "gcc-toolchain"
    "make"
    "binutils"
    "bc"
    "bison"
    "ccache"
    "curl"
    "flex"
    "git"
    "git-lfs"
    "gnupg"
    "gperf"
    "imagemagick"
    "libelf"
    "lz4"
    "openssl"
    "libxml2"
    "lzop"
    "pngcrush"
    "rsync"
    "squashfs-tools"
    "libxslt"
    "zip"
    "unzip"
    "zlib"
    "openjdk:jdk"
    "python"
    "python-wrapper"
    "util-linux"
    "jq"
    "node"
    "coreutils"
    "findutils"
    "grep"
    "sed"
    "gawk"
    "which"
    # schedtool ไม่มีใน Guix channel (ไม่จำเป็น — ใช้สำหรับ priority scheduling เท่านั้น)
)

# สร้าง environment ด้วย guix shell --pure หรือสร้าง profile
# ใช้ guix package -p <profile> เพื่อสร้าง persistent profile
info "ติดตั้ง packages: ${GUIX_PACKAGES[*]}"

# Build package list argument
PKG_ARGS=()
for pkg in "${GUIX_PACKAGES[@]}"; do
    PKG_ARGS+=("$pkg")
done

# ตรวจสอบว่า profile มีอยู่แล้วหรือไม่
if [[ -d "$GUIX_PROFILE" ]]; then
    info "พบ Guix profile เดิมที่ $GUIX_PROFILE — ใช้ต่อ"
else
    log "สร้าง Guix profile ใหม่ที่ $GUIX_PROFILE (อาจใช้เวลาหลายนาที...)"
    guix package -p "$GUIX_PROFILE" -i "${PKG_ARGS[@]}" || die "ติดตั้ง Guix packages ล้มเหลว"
fi

# Load profile environment (ปิด nounset ชั่วคราว เพราะ Guix profile script ใช้ตัวแปร unbound)
set +u
. "$GUIX_PROFILE/etc/profile"
set -u

# Export PATH explicitly (Guix profile bin must be first)
export PATH="$GUIX_PROFILE/bin:$HOME/.bin:$PATH"
export GUIX_LOCPATH="$GUIX_PROFILE/lib/locale"

# Verify critical binaries
if ! command -v python3 >/dev/null 2>&1; then
    die "python3 ไม่อยู่ใน PATH หลัง load Guix profile — ตรวจสอบ profile"
fi
info "Python: $(python3 --version)"

# ccache setup
mkdir -p "$CCACHE_DIR_VAR"
ccache -M "$CCACHE_SIZE" >/dev/null || warn "ccache config ล้มเหลว — build จะช้ากว่าปกติ"
export USE_CCACHE=1 CCACHE_EXEC="$(command -v ccache)" CCACHE_DIR="$CCACHE_DIR_VAR"

# Yarn: ติดตั้งผ่าน npm (Node.js ใน Guix มี npm มาด้วย)
if ! command -v yarn >/dev/null; then
    log "ติดตั้ง yarn ผ่าน npm"
    npm install -g yarn || warn "ติดตั้ง yarn ล้มเหลว — ลองต่อด้วย npx yarn"
    # ถ้า npm install -g ไม่ได้ (permission) → ใช้ npx yarn แทน
fi
info "Node.js: $(node --version 2>/dev/null || echo 'NOT FOUND')"
info "yarn: $(yarn --version 2>/dev/null || echo 'will use npx')"

# -------- STEP 2: repo + git identity + allowed_signers --------
step "STEP 2/8 — ติดตั้ง repo + ตั้ง git identity + allowed_signers"
mkdir -p "$HOME/.bin"
if [[ ! -x "$HOME/.bin/repo" ]]; then
    curl -fsSL https://storage.googleapis.com/git-repo-downloads/repo -o "$HOME/.bin/repo"
    chmod a+x "$HOME/.bin/repo"
fi
case ":$PATH:" in *":$HOME/.bin:"*) :;; *) export PATH="$HOME/.bin:$PATH";; esac
grep -q 'export PATH=$HOME/.bin:$PATH\|export PATH=~/.bin:$PATH' "$HOME/.bashrc" 2>/dev/null \
    || echo 'export PATH=$HOME/.bin:$PATH' >> "$HOME/.bashrc"

# git identity
HOST_FQDN="$(hostname -f 2>/dev/null || hostname)"
[[ -z "$HOST_FQDN" || "$HOST_FQDN" == "(none)" ]] && HOST_FQDN="localhost"
if ! git config --global user.email >/dev/null; then
    git config --global user.email "${GIT_EMAIL:-${USER}@${HOST_FQDN}}"
fi
if ! git config --global user.name >/dev/null; then
    git config --global user.name "${GIT_NAME:-${USER}}"
fi
info "git identity: $(git config --global user.name) <$(git config --global user.email)>"

mkdir -p "$HOME/.config/grapheneos"
if [[ ! -s "$HOME/.config/grapheneos/allowed_signers" ]]; then
    curl -fsSL https://grapheneos.org/allowed_signers \
        -o "$HOME/.config/grapheneos/allowed_signers"
fi
git config --global gpg.ssh.allowedSignersFile "$HOME/.config/grapheneos/allowed_signers"

# -------- STEP 3: repo init + verify tag + sync --------
step "STEP 3/8 — repo init/verify/sync (tag $GOS_TAG)"
mkdir -p "$BUILD_ROOT"
cd "$BUILD_ROOT"

if [[ "$SKIP_SYNC" == "1" && -d ".repo" ]]; then
    info "SKIP_SYNC=1 — ข้าม repo init/sync"
elif [[ -d ".repo" ]] && [[ -f ".repo/manifests/default.xml" ]] && \
     [[ -f ".gos-synced-tag" ]] && [[ "$(cat .gos-synced-tag)" == "$GOS_TAG" ]]; then
    info "พบ source tree ที่ sync tag $GOS_TAG ไว้แล้ว — ข้าม sync"
else
    repo init -u https://github.com/GrapheneOS/platform_manifest.git \
        -b "refs/tags/$GOS_TAG" --depth=1
    ( cd .repo/manifests && git verify-tag "$(git describe)" ) \
        || die "verify-tag ล้มเหลว — ลายเซ็น tag ไม่ผ่าน"
    info "verify-tag ผ่าน"
    REPO_TRIES=(8 4 2 1 1 1)
    SYNC_OK=0
    for _try_j in "${REPO_TRIES[@]}"; do
        _eff_j=$(( _try_j > JOBS ? JOBS : _try_j ))
        info "repo sync -j${_eff_j}"
        if repo sync -j"$_eff_j" --force-sync --no-clone-bundle --no-tags --fail-fast; then
            SYNC_OK=1
            break
        fi
        warn "repo sync ล้มเหลว — รอ 30s แล้วลองใหม่"
        sleep 30
    done
    [[ "$SYNC_OK" == "1" ]] || die "repo sync ล้มเหลวทั้งหมด"
    echo "$GOS_TAG" > .gos-synced-tag
fi

# -------- STEP 4: copy + run patch-grapheneos.sh --------
step "STEP 4/8 — patch source (ปิด Updater + สร้าง keys/AVB)"
cp -f "$PATCH_SRC" "$BUILD_ROOT/patch-grapheneos.sh"
chmod +x "$BUILD_ROOT/patch-grapheneos.sh"
"$BUILD_ROOT/patch-grapheneos.sh" "${DEVICES[@]}"
# ยืนยัน keys ครบ
for _D in "${DEVICES[@]}"; do
    for _K in bluetooth gmscompat_lib media networkstack nfc platform releasekey sdk_sandbox shared; do
        [[ -f "$BUILD_ROOT/keys/$_D/$_K.pk8" && -f "$BUILD_ROOT/keys/$_D/$_K.x509.pem" ]] \
            || die "Patch ไม่สมบูรณ์: ขาด keys/$_D/$_K"
    done
    [[ -f "$BUILD_ROOT/keys/$_D/avb.pem" && -f "$BUILD_ROOT/keys/$_D/avb_pkmd.bin" ]] \
        || die "Patch ไม่สมบูรณ์: ขาด keys/$_D/avb"
done
log "ยืนยัน keys ครบ"

# -------- STEP 5: adevtool yarn install + aapt2 --------
step "STEP 5/8 — เตรียม adevtool (yarn install) + build aapt2"
# ใช้ yarn หรือ npx yarn
YARN_CMD="yarn"
command -v yarn >/dev/null || YARN_CMD="npx yarn"

( cd "$BUILD_ROOT/vendor/adevtool" && $YARN_CMD install --frozen-lockfile ) \
    || ( warn "yarn frozen-lockfile fail — ลอง install ธรรมดา"; \
         cd "$BUILD_ROOT/vendor/adevtool" && $YARN_CMD install )

# Android build/envsetup.sh + m/lunch
(
    set +u
    cd "$BUILD_ROOT"
    # shellcheck disable=SC1091
    source build/envsetup.sh
    lunch sdk_phone64_x86_64-cur-user
    m -j"$JOBS" aapt2
)

# -------- STEP 6/7/8: per-device — vendor blobs + build + sign --------
BUILD_NUMBER="$(date +%Y%m%d)01"
mkdir -p "$ADEV_DL"

for DEVICE in "${DEVICES[@]}"; do
    step "STEP 6 [$DEVICE] — extract vendor blobs (adevtool generate-all)"
    (
        set +u
        cd "$BUILD_ROOT"
        export ADEVTOOL_IMG_DOWNLOAD_DIR="$ADEV_DL"
        node vendor/adevtool/bin/run generate-all -d "$DEVICE"
    )

    # ลบ adevtool intermediates
    if [[ -d "$BUILD_ROOT/out_adevtool_deps" ]]; then
        _ad_size=$(du -sh "$BUILD_ROOT/out_adevtool_deps" 2>/dev/null | awk '{print $1}')
        info "ลบ out_adevtool_deps ($_ad_size)"
        rm -rf "$BUILD_ROOT/out_adevtool_deps" 2>/dev/null || true
    fi

    step "STEP 7 [$DEVICE] — build (m target-files-package otatools-package -j$JOBS)"
    (
        set +u
        cd "$BUILD_ROOT"
        # shellcheck disable=SC1091
        source build/envsetup.sh
        lunch "${DEVICE}-cur-user"
        m -j"$JOBS" target-files-package otatools-package
    )

    step "STEP 8 [$DEVICE] — sign + factory/OTA zip"
    REL_DIR="$BUILD_ROOT/releases/$BUILD_NUMBER"
    mkdir -p "$REL_DIR"
    TF_SRC=$(ls "$BUILD_ROOT/out/target/product/$DEVICE/obj/PACKAGING/target_files_intermediates/"*target_files*.zip 2>/dev/null | head -1)
    [[ -f "$TF_SRC" ]] || die "ไม่พบ target_files.zip"
    cp "$TF_SRC" "$REL_DIR/${DEVICE}-target_files.zip"
    OTATOOLS_SRC=$(find "$BUILD_ROOT/out" -name "otatools.zip" -size +10M 2>/dev/null | head -1)
    [[ -f "$OTATOOLS_SRC" ]] || die "ไม่พบ otatools.zip"
    cp "$OTATOOLS_SRC" "$REL_DIR/${DEVICE}-otatools.zip"
    ( cd "$BUILD_ROOT" && password="" script/generate-release.sh "$DEVICE" "$BUILD_NUMBER" )
    OUT_PATHS+=("$REL_DIR/release-${DEVICE}-${BUILD_NUMBER}")

    if [[ "$CLEAN_OUT_AFTER" == "1" ]]; then
        info "[$DEVICE] CLEAN_OUT_AFTER=1 → ลบ out/target/product/$DEVICE"
        rm -rf "$BUILD_ROOT/out/target/product/$DEVICE" || true
    fi
done

fi  # end if SKIP_BUILD != 1

# -------- STEP 9: pack flashable + keys → GPG --------
SKIP_GPG="${SKIP_GPG:-0}"
GPG_OUT_DIR="${GPG_OUT_DIR:-$HOME}"
GPG_BUNDLE=""
GPG_MODE=""
if [[ "$SKIP_GPG" == "1" ]]; then
    info "SKIP_GPG=1 — ข้าม pack/encrypt"
else
    step "STEP 9/9 — pack flashable + keys → tar | gpg"
    command -v gpg >/dev/null || die "ไม่พบ gpg"
    mkdir -p "$GPG_OUT_DIR"

    BUNDLE_BASENAME="grapheneos-${BUILD_NUMBER}-$(IFS=_; echo "${DEVICES[*]}")"
    BUNDLE_TAR="$GPG_OUT_DIR/${BUNDLE_BASENAME}.tar"
    GPG_BUNDLE="${BUNDLE_TAR}.gpg"
    README_FILE="$GPG_OUT_DIR/${BUNDLE_BASENAME}.README.txt"

    TAR_INCLUDES=()
    for DEVICE in "${DEVICES[@]}"; do
        _rel="releases/$BUILD_NUMBER/release-${DEVICE}-${BUILD_NUMBER}"
        for _z in factory install ota_update img; do
            _f="${_rel}/${DEVICE}-${_z}-${BUILD_NUMBER}.zip"
            if [[ -f "$BUILD_ROOT/$_f" ]]; then
                TAR_INCLUDES+=("$_f")
            else
                warn "ไม่พบ ${_f} — ข้าม"
            fi
        done
        TAR_INCLUDES+=("keys/$DEVICE")
    done

    log "สร้าง tar: $BUNDLE_TAR"
    tar -C "$BUILD_ROOT" -cf "$BUNDLE_TAR" "${TAR_INCLUDES[@]}"
    BUNDLE_TAR_SIZE=$(du -h "$BUNDLE_TAR" | awk '{print $1}')
    info "tar size: $BUNDLE_TAR_SIZE"

    if [[ -n "${GPG_RECIPIENT:-}" ]]; then
        GPG_MODE="asymmetric (recipient: $GPG_RECIPIENT)"
        log "encrypt → $GPG_BUNDLE  [$GPG_MODE]"
        gpg --batch --yes --trust-model always \
            --output "$GPG_BUNDLE" \
            --encrypt --recipient "$GPG_RECIPIENT" \
            "$BUNDLE_TAR"
    else
        GPG_MODE="symmetric AES256"
        if [[ -n "${GPG_PASSPHRASE:-}" ]]; then
            log "encrypt → $GPG_BUNDLE  [$GPG_MODE, passphrase จาก env]"
            gpg --batch --yes --pinentry-mode loopback \
                --passphrase "$GPG_PASSPHRASE" \
                --symmetric --cipher-algo AES256 \
                --output "$GPG_BUNDLE" \
                "$BUNDLE_TAR"
        else
            log "encrypt → $GPG_BUNDLE  [$GPG_MODE, จะ prompt passphrase]"
            warn "เก็บ passphrase ไว้ให้ดี — ถ้าลืมไฟล์นี้จะถอดไม่ได้"
            gpg --symmetric --cipher-algo AES256 \
                --output "$GPG_BUNDLE" \
                "$BUNDLE_TAR"
        fi
    fi

    # ลบ tar plain
    shred -u "$BUNDLE_TAR" 2>/dev/null || rm -f "$BUNDLE_TAR"

    GPG_SIZE=$(du -h "$GPG_BUNDLE" | awk '{print $1}')
    GPG_SHA=$(sha256sum "$GPG_BUNDLE" | awk '{print $1}')

    # README
    cat > "$README_FILE" <<README
GrapheneOS Flashable Bundle (Built on Guix System)
============================
Build number : $BUILD_NUMBER
Devices      : ${DEVICES[*]}
Encrypt mode : $GPG_MODE
Bundle file  : $GPG_BUNDLE
Bundle size  : $GPG_SIZE
SHA-256      : $GPG_SHA
Created at   : $(date -Iseconds 2>/dev/null || date)
Source host  : $(hostname -f 2>/dev/null || hostname)

วิธีย้ายไปเครื่องอื่น (host ที่ต่อ Pixel ผ่าน USB)
--------------------------------------------------
1) คัดลอก 2 ไฟล์นี้ไปเครื่องปลายทาง:
     - $(basename "$GPG_BUNDLE")
     - $(basename "$README_FILE")

2) ตรวจ SHA-256:
     sha256sum $(basename "$GPG_BUNDLE")

3) ถอดรหัส + extract:
$(if [[ -n "${GPG_RECIPIENT:-}" ]]; then cat <<R
   (โหมด asymmetric)
     gpg --decrypt $(basename "$GPG_BUNDLE") | tar -xvf -
R
else cat <<R
   (โหมด symmetric)
     gpg --decrypt $(basename "$GPG_BUNDLE") | tar -xvf -
R
fi)

4) Flash + lock bootloader — ดูรายละเอียดใน Ubuntu script README
README

    info "README: $README_FILE"
fi

# -------- รายงานผลลัพธ์ --------
step "เสร็จสิ้น — สรุปผลลัพธ์"
echo
echo "==================== READY TO FLASH ===================="
echo "Build number : $BUILD_NUMBER"
echo "Source root  : $BUILD_ROOT"
echo "Log file     : $LOG_FILE"
echo
echo "AVB / signing keys per device:"
for DEVICE in "${DEVICES[@]}"; do
    echo "  - $BUILD_ROOT/keys/$DEVICE/"
done
echo
echo "Flashable artifacts:"
for p in "${OUT_PATHS[@]}"; do
    echo "  - $p"
done
echo
if [[ -n "$GPG_BUNDLE" && -f "$GPG_BUNDLE" ]]; then
    echo "==================== GPG BUNDLE ===================="
    echo "Bundle    : $GPG_BUNDLE"
    echo "README    : $README_FILE"
    echo "Size      : $(du -h "$GPG_BUNDLE" | awk '{print $1}')"
    echo "SHA-256   : $(sha256sum "$GPG_BUNDLE" | awk '{print $1}')"
    echo "===================================================="
fi
echo "========================================================"
