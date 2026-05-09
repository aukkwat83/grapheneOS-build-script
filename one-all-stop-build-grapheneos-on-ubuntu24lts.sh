#!/usr/bin/env bash
# =====================================================================
# one-all-stop-build-grapheneos-on-ubuntu24lts.sh
#
# One-stop script: clean Ubuntu 24.04 LTS  ->  flashable GrapheneOS
# (custom AVB key, ไม่มี OTA in-place) ตาม Readme.md + patch-grapheneos.sh
#
# วิธีใช้ (รันเป็น user ธรรมดา ไม่ใช่ root — script จะ sudo เอง):
#   ./one-all-stop-build-grapheneos-on-ubuntu24lts.sh husky
#   ./one-all-stop-build-grapheneos-on-ubuntu24lts.sh husky tangorpro
#
# Env override (ทางเลือก):
#   GOS_TAG=2026042100         GrapheneOS source tag
#   BUILD_ROOT=$HOME/grapheneos
#   ADEV_DL=$HOME/adevtool-downloads
#   CCACHE_DIR=$HOME/.cache/ccache
#   CCACHE_SIZE=50G
#   GIT_NAME / GIT_EMAIL       ใช้ตั้ง git identity ครั้งแรก
#   ASSUME_YES=1               ตอบ yes อัตโนมัติเมื่อ disk ไม่พอ
#   SKIP_SYNC=1                ข้าม repo init/sync (ถ้าทำไว้แล้ว)
#   CLEAN_OUT_AFTER=1          ลบ out/target/product/<DEV>/ หลัง build เพื่อเซฟ disk
#                              สำหรับ device ตัวถัดไป (default 1 ถ้า disk ตึง)
#   LOG_FILE=$HOME/gos-build.log
# =====================================================================

set -o errexit -o nounset -o pipefail

# -------- ค่าตั้งต้น --------
GOS_TAG="${GOS_TAG:-2026042100}"
BUILD_ROOT="${BUILD_ROOT:-$HOME/grapheneos}"
ADEV_DL="${ADEV_DL:-$HOME/adevtool-downloads}"
# CCACHE_DIR ต้องอยู่ใน build tree เพราะ Soong nsjail mount สิ่งอื่น read-only
# (ถ้าตั้งไว้ที่ $HOME/.cache/ccache → clang ใน sandbox จะ fail "Read-only filesystem")
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
[[ "$EUID" -ne 0 ]] || die "ห้ามรันเป็น root — รันเป็น user ปกติ (script จะใช้ sudo เอง)"
[[ $# -ge 1 ]]      || die "ระบุ codename อย่างน้อย 1 ตัว เช่น: $0 husky"
[[ -f "$PATCH_SRC" ]] || die "ไม่พบ patch-grapheneos.sh ที่ $PATCH_SRC"

DEVICES=("$@")

# log ทุกอย่างไปไฟล์ด้วย (ทำหลัง pre-flight เพื่อให้ usage error ออก stderr ปกติ)
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1
info "Log file: $LOG_FILE"

# verify ubuntu 24.04
if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    if [[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "24.04" ]]; then
        info "OS: ${PRETTY_NAME:-Ubuntu 24.04} ✓"
    else
        warn "OS ไม่ใช่ Ubuntu 24.04 (เห็น ${PRETTY_NAME:-unknown}) — script ทดสอบกับ 24.04 เท่านั้น"
        ask_yes "ดำเนินการต่อ?" || die "ยกเลิกตามคำสั่งผู้ใช้"
    fi
else
    warn "อ่าน /etc/os-release ไม่ได้ — ข้าม OS check"
fi

# sudo prime + keepalive (เก็บ credential ไว้ใช้ตลอด session)
step "ขอ sudo ล่วงหน้า"
if sudo -n true 2>/dev/null; then
    info "sudo NOPASSWD ตรวจสอบผ่าน — ไม่ต้องใส่ password"
else
    log "ใส่ password sudo (ครั้งเดียว — keep-alive จะรีเฟรชระหว่าง build)"
    sudo -v
fi
( while true; do sudo -n true 2>/dev/null; sleep 50; kill -0 "$$" 2>/dev/null || exit; done ) &
SUDO_KEEPALIVE_PID=$!
# รวม trap: kill keepalive + log สถานะสุดท้าย (กัน wrapper จับ $? ผิด)
trap '_rc=$?; kill $SUDO_KEEPALIVE_PID 2>/dev/null || true; printf "\n%s[exit]%s rc=%d  started=%s ended=%s\n" "$([[ $_rc -eq 0 ]] && echo "$c_grn" || echo "$c_red")" "$c_off" "$_rc" "$_started_at" "$(date -Iseconds 2>/dev/null || date)"; exit $_rc' EXIT

# -------- detect spec --------
step "STEP 0/8 — ตรวจ spec เครื่อง + คำนวณ build params"
CPU_CORES=$(nproc)
MEM_GB=$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo)
SWAP_GB=$(awk '/SwapTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo)
mkdir -p "$(dirname "$BUILD_ROOT")"
DISK_TARGET="$(dirname "$BUILD_ROOT")"
DISK_AVAIL_GB=$(df -BG --output=avail "$DISK_TARGET" | tail -1 | tr -dc '0-9')

# คำนวณ -j: AOSP build ใช้ R8/proguard/dex ที่ -JXmx4G ต่อ job → ต้องเผื่อ ~4GB ต่อ job
# กฎเก่า "1 thread ต่อ 2GB" จะ OOM ในเฟส dex/proguard (เห็น crash จริง 16 jobs / 31GB RAM)
# สูตรปลอดภัย: jobs = (RAM - 4) / 4 (กัน 4GB ให้ OS + 4GB ต่อ job)
J_BY_RAM=$(( (MEM_GB - 4) / 4 ))
[[ $J_BY_RAM -lt 1 ]] && J_BY_RAM=1
JOBS=$(( J_BY_RAM < CPU_CORES ? J_BY_RAM : CPU_CORES ))
[[ $JOBS -lt 1 ]] && JOBS=1

# disk math: 1 source tree (~160GB) + ต่อ device: out/ ~80-120GB transient + adevtool dl ~30GB + release ~5GB
# ถ้า source sync ไว้แล้ว (BUILD_ROOT/.repo มี) → หักลบขนาดที่ใช้อยู่ออกจากที่ต้องการเพิ่ม
NUM_DEV=${#DEVICES[@]}
DISK_SOURCE_GB=170    # repo sync + .repo cache + ccache 50G
DISK_PER_DEV_GB=140   # out/ ~80-120 + adevtool ~30 + release 5 + buffer
EXISTING_GB=0
if [[ -d "$BUILD_ROOT/.repo" ]]; then
    EXISTING_GB=$(du -BG -s "$BUILD_ROOT" 2>/dev/null | awk '{gsub(/G/,"",$1); print $1}')
    [[ -z "$EXISTING_GB" ]] && EXISTING_GB=0
fi
DISK_PARALLEL_GB=$(( DISK_SOURCE_GB + NUM_DEV * DISK_PER_DEV_GB - EXISTING_GB ))
DISK_SERIAL_GB=$(( DISK_SOURCE_GB + DISK_PER_DEV_GB - EXISTING_GB ))
[[ $DISK_PARALLEL_GB -lt 50 ]] && DISK_PARALLEL_GB=50    # floor
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
        log "เพิ่ม swap file 8GB ที่ /swapfile-gos (ลบเองได้หลัง build)"
        if [[ ! -f /swapfile-gos ]]; then
            sudo fallocate -l 8G /swapfile-gos || sudo dd if=/dev/zero of=/swapfile-gos bs=1M count=8192
            sudo chmod 600 /swapfile-gos
            sudo mkswap /swapfile-gos
        fi
        sudo swapon /swapfile-gos 2>/dev/null || true
        SWAP_GB=$(awk '/SwapTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo)
        info "swap ใหม่: ${SWAP_GB} GB"
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
        warn "ทางออก: (1) เพิ่ม disk / resize partition  (2) ใช้ external storage  (3) ลด device list"
        ask_yes "ยังจะลองต่อ (อาจเต็ม disk กลางทาง)?" || die "ยกเลิกตามคำสั่งผู้ใช้"
        [[ "$CLEAN_OUT_AFTER" == "auto" ]] && CLEAN_OUT_AFTER=1
    fi
else
    [[ "$CLEAN_OUT_AFTER" == "auto" ]] && CLEAN_OUT_AFTER=0
fi

# -------- STEP 1: install deps --------
step "STEP 1/8 — ติดตั้ง dependencies (sudo apt + Node ${NODE_MAJOR_REQ:-24} + yarn)"
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -y
sudo apt-get install -y \
    bc bison build-essential ccache curl flex git git-lfs \
    gnupg gperf imagemagick lib32readline-dev lib32z1-dev \
    libelf-dev liblz4-tool libsdl1.2-dev libssl-dev \
    libxml2-utils lzop pngcrush rsync schedtool squashfs-tools \
    xsltproc zip zlib1g-dev openjdk-21-jdk python3 python-is-python3 \
    unzip android-sdk-platform-tools-common \
    util-linux jq

# ccache size + dir
mkdir -p "$CCACHE_DIR_VAR"
ccache -M "$CCACHE_SIZE" >/dev/null
export USE_CCACHE=1 CCACHE_EXEC=/usr/bin/ccache CCACHE_DIR="$CCACHE_DIR_VAR"

# Ubuntu 24.04 มี 2 ชั้นที่ block Soong nsjail (sandbox สำหรับ build):
#   1) sysctl kernel.apparmor_restrict_unprivileged_userns=1 → ห้าม unshare(NEWUSER) เลย
#   2) AppArmor profile 'unprivileged_userns' (apply auto กับทุก userns) → deny mount/setgid/setuid
# ผลที่เกิด: ccache ใน clang sandbox เห็น filesystem เป็น RO → build fail กลางทาง
# วิธีแก้: ปิด sysctl + unload profile (link ไป disable/) ให้ persist ข้าม reboot
if [[ "$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null)" == "1" ]]; then
    log "ปิด apparmor_restrict_unprivileged_userns (Ubuntu 24.04 default)"
    sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0 >/dev/null
    echo 'kernel.apparmor_restrict_unprivileged_userns=0' | sudo tee /etc/sysctl.d/99-gos-build-userns.conf >/dev/null
fi
if [[ -f /etc/apparmor.d/unprivileged_userns ]] \
   && sudo aa-status 2>/dev/null | grep -q '^\s*unprivileged_userns\b'; then
    log "Unload AppArmor profile 'unprivileged_userns' (block mount/setgid ใน nsjail sandbox)"
    sudo apparmor_parser -R /etc/apparmor.d/unprivileged_userns 2>/dev/null || true
    sudo mkdir -p /etc/apparmor.d/disable
    sudo ln -sf /etc/apparmor.d/unprivileged_userns /etc/apparmor.d/disable/unprivileged_userns
fi

# Node.js: Ubuntu 24.04 มาเฉพาะ Node 18.19 ซึ่งเก่า adevtool@latest บังคับใน bin/run ว่า MIN_NODE=24
# ติดตั้ง Node 24 จาก NodeSource (replace nodejs Ubuntu + ลบ yarnpkg deb อัตโนมัติ)
NODE_MAJOR_REQ=24
NODE_VER=$(node --version 2>/dev/null | sed 's/^v//' | cut -d. -f1)
if [[ -z "$NODE_VER" || "$NODE_VER" -lt "$NODE_MAJOR_REQ" ]]; then
    log "ติดตั้ง Node.js ${NODE_MAJOR_REQ}.x จาก NodeSource (Ubuntu 24.04 มี node ${NODE_VER:-?} ซึ่งเก่าเกินไป)"
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR_REQ}.x" | sudo -E bash -
    sudo apt-get install -y nodejs
    info "Node.js ใหม่: $(node --version)"
fi

# Yarn: ติดตั้งผ่าน npm (Debian package yarnpkg ไม่ compatible กับ NodeSource nodejs)
if ! command -v yarn >/dev/null; then
    log "ติดตั้ง yarn (classic 1.x) ผ่าน npm"
    sudo npm install -g yarn
    info "yarn version: $(yarn --version)"
fi

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

# git identity (ใช้ค่า env หรือ user@hostname เป็น default)
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
        || die "verify-tag ล้มเหลว — ลายเซ็น tag ไม่ผ่าน (อาจโดน MITM/repo ปลอม)"
    info "verify-tag ผ่าน"
    REPO_J=$(( JOBS > 8 ? 8 : JOBS ))    # repo sync เกิน -j8 มักจะโดน rate-limit
    repo sync -j"$REPO_J" --force-sync --no-clone-bundle --no-tags
    echo "$GOS_TAG" > .gos-synced-tag
fi

# -------- STEP 4: copy + run patch-grapheneos.sh --------
step "STEP 4/8 — patch source (ปิด Updater + สร้าง keys/AVB)"
cp -f "$PATCH_SRC" "$BUILD_ROOT/patch-grapheneos.sh"
chmod +x "$BUILD_ROOT/patch-grapheneos.sh"
"$BUILD_ROOT/patch-grapheneos.sh" "${DEVICES[@]}"
# ยืนยันว่า patch สร้าง keys ครบทุก device (กัน case ที่ patch-grapheneos.sh fail แต่ exit code โดน mask)
for _D in "${DEVICES[@]}"; do
    for _K in bluetooth gmscompat_lib media networkstack nfc platform releasekey sdk_sandbox shared; do
        [[ -f "$BUILD_ROOT/keys/$_D/$_K.pk8" && -f "$BUILD_ROOT/keys/$_D/$_K.x509.pem" ]] \
            || die "Patch ไม่สมบูรณ์: ขาด keys/$_D/$_K.pk8|.x509.pem"
    done
    [[ -f "$BUILD_ROOT/keys/$_D/avb.pem" && -f "$BUILD_ROOT/keys/$_D/avb_pkmd.bin" ]] \
        || die "Patch ไม่สมบูรณ์: ขาด keys/$_D/avb.pem|avb_pkmd.bin"
done
log "ยืนยัน keys ครบ ($(echo "${DEVICES[@]}" | wc -w) device × 9 signing + AVB)"

# -------- STEP 5: adevtool yarn install + aapt2 --------
step "STEP 5/8 — เตรียม adevtool (yarn install) + build aapt2"
( cd "$BUILD_ROOT/vendor/adevtool" && yarn install --frozen-lockfile ) \
    || ( warn "yarn frozen-lockfile fail — ลอง install โดยอนุญาตให้ regenerate lock"; \
         cd "$BUILD_ROOT/vendor/adevtool" && yarn install )

# Android build/envsetup.sh + m/lunch ใช้ตัวแปร unset เยอะ → ต้อง set +u รอบ ๆ
# ใช้ subshell เพื่อ isolate ทั้ง set +u และ envvar ที่ envsetup ใส่ให้ (TOP, ANDROID_*, etc.)
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
declare -a OUT_PATHS=()
mkdir -p "$ADEV_DL"

for DEVICE in "${DEVICES[@]}"; do
    step "STEP 6 [$DEVICE] — extract vendor blobs (adevtool generate-all)"
    # หมายเหตุ: adevtool flag -b คือ "stock image build ID" (เช่น BP4A.260205.001)
    #          ไม่ใช่ GrapheneOS source tag — ปล่อยว่างให้ใช้ default จาก device config
    #          generate-all จะ auto-download stock images ผ่าน Google เอง
    (
        set +u
        cd "$BUILD_ROOT"
        export ADEVTOOL_IMG_DOWNLOAD_DIR="$ADEV_DL"
        node vendor/adevtool/bin/run generate-all -d "$DEVICE"
    )

    # ก่อน build จริง: ลบ adevtool intermediates (~12GB) เพื่อเซฟ disk
    # adevtool ใช้ out_adevtool_deps แค่ตอน generate-all (build ของ adevtool เอง)
    if [[ -d "$BUILD_ROOT/out_adevtool_deps" ]]; then
        _ad_size=$(du -sh "$BUILD_ROOT/out_adevtool_deps" 2>/dev/null | awk '{print $1}')
        info "ลบ out_adevtool_deps ($_ad_size) เพื่อเซฟ disk ก่อน build $DEVICE"
        rm -rf "$BUILD_ROOT/out_adevtool_deps" 2>/dev/null || true
    fi

    step "STEP 7 [$DEVICE] — build (m target-files-package otatools-package -j$JOBS)"
    # หมายเหตุ: tag เก่า GrapheneOS เคยมี target 'vanilla' (vanilla flavor) แต่ปัจจุบันถูกเลิก
    #          lunch target husky-cur-user เป็นตัวกำหนด flavor อยู่แล้ว
    #          target-files-package + otatools-package คือสิ่งที่ generate-release.sh ใช้ต่อ
    #          (otatools เป็น target เก่าเปลี่ยนเป็น otatools-package ใน AOSP ใหม่)
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
    # AOSP เก่าตั้งชื่อ `*-target_files-*.zip` แต่ tag 2026042100 ใช้ `<DEVICE>-target_files.zip`
    TF_SRC=$(ls "$BUILD_ROOT/out/target/product/$DEVICE/obj/PACKAGING/target_files_intermediates/"*target_files*.zip 2>/dev/null | head -1)
    [[ -f "$TF_SRC" ]] || die "ไม่พบ target_files.zip ใน out/target/product/$DEVICE/obj/PACKAGING/target_files_intermediates/"
    cp "$TF_SRC" "$REL_DIR/${DEVICE}-target_files.zip"
    # otatools.zip ย้ายไปอยู่ใน soong intermediates (out/host/linux-x86/otatools.zip ไม่มีแล้ว)
    OTATOOLS_SRC=$(find "$BUILD_ROOT/out" -name "otatools.zip" -size +10M 2>/dev/null | head -1)
    [[ -f "$OTATOOLS_SRC" ]] || die "ไม่พบ otatools.zip — ตรวจ build target otatools-package"
    cp "$OTATOOLS_SRC" "$REL_DIR/${DEVICE}-otatools.zip"
    # generate-release.sh เรียก decrypt-keys ที่ prompt password — set password="" ให้ skip
    ( cd "$BUILD_ROOT" && password="" script/generate-release.sh "$DEVICE" "$BUILD_NUMBER" )
    OUT_PATHS+=("$REL_DIR/release-${DEVICE}-${BUILD_NUMBER}")

    if [[ "$CLEAN_OUT_AFTER" == "1" ]]; then
        info "[$DEVICE] CLEAN_OUT_AFTER=1 → ลบ out/target/product/$DEVICE เพื่อเซฟ disk"
        rm -rf "$BUILD_ROOT/out/target/product/$DEVICE" || true
    fi
done

# -------- รายงานผลลัพธ์ --------
step "เสร็จสิ้น — สรุปผลลัพธ์"
echo
echo "==================== READY TO FLASH ===================="
echo "Build number : $BUILD_NUMBER"
echo "Source root  : $BUILD_ROOT"
echo "Log file     : $LOG_FILE"
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
