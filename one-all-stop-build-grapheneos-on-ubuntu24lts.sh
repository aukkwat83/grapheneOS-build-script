#!/usr/bin/env bash
# =====================================================================
# one-all-stop-build-grapheneos-on-ubuntu24lts.sh
#
# One-stop script: clean Ubuntu 24.04 LTS -> flashable GrapheneOS
# (custom AVB key, no OTA) ตาม Readme.md + patch-grapheneos.sh
#
# วิธีใช้ (รันเป็น user ธรรมดา ไม่ใช่ root — script จะ sudo เอง):
#   ./one-all-stop-build-grapheneos-on-ubuntu24lts.sh husky tangorpro
#
# Env override (ทางเลือก):
#   GOS_TAG=2026042100         # GrapheneOS source tag
#   BUILD_ROOT=$HOME/grapheneos
#   ADEV_DL=$HOME/adevtool-downloads
#   GIT_NAME / GIT_EMAIL       # ใช้ตั้ง git identity ครั้งแรก
#   ASSUME_YES=1               # ตอบ yes อัตโนมัติเมื่อ disk ไม่พอ
#   SKIP_SYNC=1                # ข้าม repo init/sync (ถ้าทำไว้แล้ว)
# =====================================================================

set -o errexit -o nounset -o pipefail

# -------- ค่าตั้งต้น --------
GOS_TAG="${GOS_TAG:-2026042100}"
BUILD_ROOT="${BUILD_ROOT:-$HOME/grapheneos}"
ADEV_DL="${ADEV_DL:-$HOME/adevtool-downloads}"
ASSUME_YES="${ASSUME_YES:-0}"
SKIP_SYNC="${SKIP_SYNC:-0}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_SRC="$SCRIPT_DIR/patch-grapheneos.sh"

# -------- สี / log --------
c_red=$'\e[1;31m'; c_grn=$'\e[1;32m'; c_ylw=$'\e[1;33m'; c_blu=$'\e[1;34m'; c_off=$'\e[0m'
log()  { printf '%s[+]%s %s\n' "$c_grn" "$c_off" "$*"; }
warn() { printf '%s[!]%s %s\n' "$c_ylw" "$c_off" "$*" >&2; }
info() { printf '%s[i]%s %s\n' "$c_blu" "$c_off" "$*"; }
die()  { printf '%s[x]%s %s\n' "$c_red" "$c_off" "$*" >&2; exit 1; }

ask_yes() {
    local prompt="$1"
    if [[ "$ASSUME_YES" == "1" ]]; then info "auto-yes: $prompt"; return 0; fi
    read -r -p "$prompt [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]]
}

# -------- pre-flight --------
[[ "$EUID" -ne 0 ]] || die "ห้ามรันเป็น root — รันเป็น user ปกติ (script จะใช้ sudo เอง)"
[[ $# -ge 1 ]]      || die "ระบุ codename อย่างน้อย 1 ตัว เช่น: $0 husky tangorpro"
[[ -f "$PATCH_SRC" ]] || die "ไม่พบ patch-grapheneos.sh ที่ $PATCH_SRC"

DEVICES=("$@")

# verify ubuntu 24.04
if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    [[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "24.04" ]] \
        || warn "OS ไม่ใช่ Ubuntu 24.04 (เห็น ${PRETTY_NAME:-unknown}) — script ทดสอบกับ 24.04 เท่านั้น"
else
    warn "อ่าน /etc/os-release ไม่ได้ — ข้าม OS check"
fi

# sudo (จะ prompt password ครั้งเดียวล่วงหน้า เพื่อให้ build ยาว ๆ ไม่ค้างกลางทาง)
log "ขอ sudo ล่วงหน้า (เก็บ credential ไว้ใช้ตลอด session)"
sudo -v
( while true; do sudo -n true; sleep 60; kill -0 "$$" 2>/dev/null || exit; done ) &
SUDO_KEEPALIVE_PID=$!
trap 'kill $SUDO_KEEPALIVE_PID 2>/dev/null || true' EXIT

# -------- detect spec --------
log "STEP 0/7 - ตรวจ spec เครื่อง"
CPU_CORES=$(nproc)
MEM_GB=$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo)
mkdir -p "$(dirname "$BUILD_ROOT")"
DISK_AVAIL_GB=$(df -BG --output=avail "$(dirname "$BUILD_ROOT")" | tail -1 | tr -dc '0-9')

# คำนวณ -j: 1 thread ต่อ ~2GB RAM, ไม่เกิน CPU cores
J_BY_RAM=$(( MEM_GB / 2 ))
[[ $J_BY_RAM -lt 1 ]] && J_BY_RAM=1
JOBS=$(( J_BY_RAM < CPU_CORES ? J_BY_RAM : CPU_CORES ))
[[ $JOBS -lt 1 ]] && JOBS=1

# disk ต้องการ: 400GB base + 80GB ต่อ device เพิ่มเติม
NUM_DEV=${#DEVICES[@]}
DISK_NEED_GB=$(( 400 + (NUM_DEV - 1) * 80 ))

cat <<EOF
  CPU cores      : $CPU_CORES
  RAM            : ${MEM_GB} GB
  Disk available : ${DISK_AVAIL_GB} GB  @ $(dirname "$BUILD_ROOT")
  Devices        : ${DEVICES[*]} (${NUM_DEV})
  Disk needed    : ~${DISK_NEED_GB} GB
  Build parallel : -j${JOBS}  (limited by $([[ $J_BY_RAM -lt $CPU_CORES ]] && echo RAM || echo CPU))
EOF

if [[ $MEM_GB -lt 16 ]]; then
    warn "RAM น้อยกว่า 16GB — build อาจ OOM"
    ask_yes "ยังจะรันต่อหรือไม่?" || die "ยกเลิกตามคำสั่งผู้ใช้"
fi
if [[ $DISK_AVAIL_GB -lt $DISK_NEED_GB ]]; then
    warn "Disk ว่างไม่พอ (มี ${DISK_AVAIL_GB}GB ต้อง ~${DISK_NEED_GB}GB)"
    ask_yes "ยังจะดำเนินการต่อหรือไม่?" || die "ยกเลิกตามคำสั่งผู้ใช้"
fi

# -------- STEP 1: install deps --------
log "STEP 1/7 - ติดตั้ง dependencies (sudo apt)"
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -y
sudo apt-get install -y \
    bc bison build-essential ccache curl flex git git-lfs \
    gnupg gperf imagemagick lib32readline-dev lib32z1-dev \
    libelf-dev liblz4-tool libsdl1.2-dev libssl-dev \
    libxml2-utils lzop pngcrush rsync schedtool squashfs-tools \
    xsltproc zip zlib1g-dev openjdk-21-jdk python3 python-is-python3 \
    yarnpkg unzip android-sdk-platform-tools-common

# -------- STEP 2: repo + git identity + allowed_signers --------
log "STEP 2/7 - ติดตั้ง repo + ตั้ง git identity + allowed_signers"
mkdir -p "$HOME/.bin"
if [[ ! -x "$HOME/.bin/repo" ]]; then
    curl -fsSL https://storage.googleapis.com/git-repo-downloads/repo -o "$HOME/.bin/repo"
    chmod a+x "$HOME/.bin/repo"
fi
case ":$PATH:" in *":$HOME/.bin:"*) :;; *) export PATH="$HOME/.bin:$PATH";; esac
grep -q 'export PATH=~/.bin:$PATH' "$HOME/.bashrc" 2>/dev/null \
    || echo 'export PATH=~/.bin:$PATH' >> "$HOME/.bashrc"

if ! git config --global user.email >/dev/null; then
    git config --global user.email "${GIT_EMAIL:-${USER}@$(hostname -f 2>/dev/null || hostname)}"
fi
if ! git config --global user.name >/dev/null; then
    git config --global user.name "${GIT_NAME:-${USER}}"
fi

mkdir -p "$HOME/.config/grapheneos"
if [[ ! -s "$HOME/.config/grapheneos/allowed_signers" ]]; then
    curl -fsSL https://grapheneos.org/allowed_signers \
        -o "$HOME/.config/grapheneos/allowed_signers"
fi
git config --global gpg.ssh.allowedSignersFile "$HOME/.config/grapheneos/allowed_signers"

# -------- STEP 3: repo init + verify tag + sync --------
log "STEP 3/7 - repo init/verify/sync (tag $GOS_TAG)"
mkdir -p "$BUILD_ROOT"
cd "$BUILD_ROOT"

if [[ "$SKIP_SYNC" == "1" && -d ".repo" ]]; then
    info "SKIP_SYNC=1 — ข้าม repo init/sync"
else
    repo init -u https://github.com/GrapheneOS/platform_manifest.git \
        -b "refs/tags/$GOS_TAG" --depth=1
    ( cd .repo/manifests && git verify-tag "$(git describe)" ) \
        || die "verify-tag ล้มเหลว — ลายเซ็น tag ไม่ผ่าน (อาจโดน MITM)"
    repo sync -j"$JOBS" --force-sync
fi

# -------- STEP 4: copy + run patch-grapheneos.sh --------
log "STEP 4/7 - patch source (ปิด Updater + สร้าง keys/AVB)"
cp -f "$PATCH_SRC" "$BUILD_ROOT/patch-grapheneos.sh"
chmod +x "$BUILD_ROOT/patch-grapheneos.sh"
"$BUILD_ROOT/patch-grapheneos.sh" "${DEVICES[@]}"

# -------- STEP 5: adevtool vendor blobs --------
log "STEP 5/7 - extract vendor blobs ด้วย adevtool"
( cd "$BUILD_ROOT/vendor/adevtool" && yarnpkg install )

# shellcheck disable=SC1091
source "$BUILD_ROOT/build/envsetup.sh"
( cd "$BUILD_ROOT" && lunch sdk_phone64_x86_64-cur-user && m -j"$JOBS" aapt2 )

mkdir -p "$ADEV_DL"
for DEVICE in "${DEVICES[@]}"; do
    log "  [$DEVICE] download stock + generate vendor"
    ( cd "$BUILD_ROOT" && \
      yarnpkg --cwd vendor/adevtool/ admin:download -d "$DEVICE" -b "$GOS_TAG" "$ADEV_DL" )
    ( cd "$BUILD_ROOT" && \
      yarnpkg --cwd vendor/adevtool/ generate-all -d "$DEVICE" -s "$ADEV_DL" )
done

# -------- STEP 6: build + sign per device --------
log "STEP 6/7 - build + sign แต่ละ device"
BUILD_NUMBER="$(date +%Y%m%d)01"
declare -a OUT_PATHS=()

for DEVICE in "${DEVICES[@]}"; do
    log "  [$DEVICE] lunch + m vanilla -j$JOBS"
    ( cd "$BUILD_ROOT" && \
      source build/envsetup.sh && \
      lunch "${DEVICE}-cur-user" && \
      m -j"$JOBS" vanilla && \
      m -j"$JOBS" target-files-package otatools )

    REL_DIR="$BUILD_ROOT/releases/$BUILD_NUMBER"
    mkdir -p "$REL_DIR"
    cp "$BUILD_ROOT/out/target/product/$DEVICE/obj/PACKAGING/target_files_intermediates/"*-target_files-*.zip \
       "$REL_DIR/${DEVICE}-target_files.zip"
    cp "$BUILD_ROOT/out/host/linux-x86/otatools.zip" \
       "$REL_DIR/${DEVICE}-otatools.zip"

    log "  [$DEVICE] generate-release"
    ( cd "$BUILD_ROOT" && script/generate-release.sh "$DEVICE" "$BUILD_NUMBER" )

    OUT_PATHS+=("$REL_DIR/release-${DEVICE}-${BUILD_NUMBER}")
done

# -------- STEP 7: report --------
log "STEP 7/7 - เสร็จสิ้น"
echo
echo "==================== READY TO FLASH ===================="
echo "Build number : $BUILD_NUMBER"
echo "Source root  : $BUILD_ROOT"
echo
echo "Patch script : $BUILD_ROOT/patch-grapheneos.sh"
echo "AVB / signing keys per device:"
for DEVICE in "${DEVICES[@]}"; do
    echo "  - $BUILD_ROOT/keys/$DEVICE/   (avb_pkmd.bin, avb.pem, *.pk8/x509.pem)"
done
echo
echo "Flashable artifacts:"
for p in "${OUT_PATHS[@]}"; do
    echo "  - $p"
    echo "      ├── *-factory-${BUILD_NUMBER}.zip   (flash-all.sh ข้างใน)"
    echo "      ├── *-ota_update-${BUILD_NUMBER}.zip"
    echo "      └── *-img-${BUILD_NUMBER}.zip"
done
echo
echo "ขั้นตอน flash + lock bootloader (ทำที่เครื่อง host ที่ต่อ Pixel):"
echo "  1) เปิด OEM unlocking ใน Developer options ของเครื่อง Pixel"
echo "  2) adb reboot bootloader"
echo "  3) fastboot flashing unlock                 (ครั้งแรกเท่านั้น, จะ wipe)"
echo "  4) cd <release-dir>/<DEVICE>-install-${BUILD_NUMBER}/ && ./flash-all.sh"
echo "  5) fastboot flash avb_custom_key $BUILD_ROOT/keys/<DEVICE>/avb_pkmd.bin"
echo "  6) fastboot flashing lock                   (กด Volume Up confirm — wipe อีกครั้ง)"
echo "  7) บูตเข้า OS หน้าจอจะเป็นสีเหลือง 'Custom OS' (ปกติ)"
echo
echo "ดู NEXT-STEPS.txt: $BUILD_ROOT/NEXT-STEPS.txt"
echo "========================================================"
