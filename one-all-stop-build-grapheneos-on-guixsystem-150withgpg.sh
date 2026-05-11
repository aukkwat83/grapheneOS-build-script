#!/usr/bin/env bash
# =====================================================================
# one-all-stop-build-grapheneos-on-guixsystem-150withgpg.sh
#
# One-stop script: Guix System 1.5.x  ->  flashable GrapheneOS
# (custom AVB key, ไม่มี OTA in-place) — เทียบเท่า Ubuntu version
#
# ─── การออกแบบใหม่ (rewrite จาก opus, ของเดิม sonnet 4.5 กากมาก) ──────
# ใช้ `guix shell --container --emulate-fhs` เป็นเครื่องมือหลัก แทนที่จะ
# พยายามแฮก /lib, /lib64 ของ host system (ซึ่งต้อง root + หายหลัง
# guix system reconfigure + ต้อง patchelf 2800 binaries)
#
# FHS container ของ Guix:
#   • สร้าง /bin, /lib, /lib64, /usr/bin layout แบบ FHS ชั่วคราว
#   • ทำงานใน user namespace แยก → ไม่ต้อง root, ไม่กระทบ host
#   • nested namespaces (Soong nsjail) ใช้งานได้ปกติ
#   • AOSP prebuilt binaries (ckati, soong_zip ฯลฯ) รันได้ทันที
#     เพียงใส่ LD_LIBRARY_PATH=prebuilts/build-tools/linux-x86/lib64
#
# ─── ที่มาของ dependencies (audit trail) ───────────────────────────────
#   1) Guix official channel  — แทบทุก package (ดู guix-manifest.scm)
#   2) Node.js corepack       — มาพร้อม node@22 ของ Guix → yarn classic
#   3) Google storage         — `repo` (curl ดึงตอน STEP 2, มี checksum)
#   4) GrapheneOS source tree — AOSP prebuilts ใน prebuilts/ (verify ด้วย tag)
#
# ─── วิธีใช้ ─────────────────────────────────────────────────────────────
# รันเป็น user ธรรมดา (Guix ไม่ต้อง sudo, ไม่ต้อง root):
#   ./one-all-stop-build-grapheneos-on-guixsystem-150withgpg.sh shiba
#   ./one-all-stop-build-grapheneos-on-guixsystem-150withgpg.sh husky tangorpro
#
# Env override (เหมือน Ubuntu version):
#   GOS_TAG=2026042100         GrapheneOS source tag
#   BUILD_ROOT=$HOME/grapheneos
#   ADEV_DL=$HOME/adevtool-downloads
#   CCACHE_DIR=$BUILD_ROOT/.ccache  (ต้องอยู่ใน source tree — Soong nsjail mount)
#   CCACHE_SIZE=50G
#   GIT_NAME / GIT_EMAIL       git identity (default = user@hostname)
#   ASSUME_YES=1               ตอบ yes อัตโนมัติ
#   SKIP_SYNC=1                ข้าม repo init/sync (ถ้าทำไว้แล้ว)
#   CLEAN_OUT_AFTER=1          ลบ out/target/product/<DEV>/ หลัง build
#   LOG_FILE=$HOME/gos-build.log
#   GPG_RECIPIENT=<key>        asymmetric encrypt (แนะนำ)
#   GPG_PASSPHRASE=<pw>        symmetric AES256
#   SKIP_GPG=1                 ข้าม pack/encrypt
#   FORCE_REBUILD=1            build ใหม่แม้พบ artifact เดิม
# =====================================================================

set -o errexit -o nounset -o pipefail

# ─── ค่าตั้งต้น ───────────────────────────────────────────────────────────
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
MANIFEST_SRC="$SCRIPT_DIR/guix-manifest.scm"

# ─── สี / log ────────────────────────────────────────────────────────────
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

# ─── pre-flight ──────────────────────────────────────────────────────────
[[ "$EUID" -ne 0 ]] || die "ห้ามรันเป็น root — รันเป็น user ปกติ (Guix ไม่ต้องใช้ root)"
[[ $# -ge 1 ]]      || die "ระบุ codename อย่างน้อย 1 ตัว เช่น: $0 shiba"
[[ -f "$PATCH_SRC" ]]    || die "ไม่พบ patch-grapheneos.sh ที่ $PATCH_SRC"
[[ -f "$MANIFEST_SRC" ]] || die "ไม่พบ guix-manifest.scm ที่ $MANIFEST_SRC"

DEVICES=("$@")

mkdir -p "$(dirname "$LOG_FILE")"

# ═══════════════════════════════════════════════════════════════════════
# Phase 1 — OUTSIDE container: pre-flight + re-exec เข้า FHS container
# ═══════════════════════════════════════════════════════════════════════
if [[ "${GOS_GUIX_INSIDE:-0}" != "1" ]]; then

    exec > >(tee -a "$LOG_FILE") 2>&1
    info "Log file: $LOG_FILE"

    # verify Guix System
    if [[ -r /etc/os-release ]]; then
        . /etc/os-release
        if [[ "${ID:-}" == "guix" ]]; then
            info "OS: ${PRETTY_NAME:-Guix System} ✓"
        else
            warn "OS ไม่ใช่ Guix System (เห็น ${PRETTY_NAME:-unknown})"
            ask_yes "ดำเนินการต่อ?" || die "ยกเลิก"
        fi
    fi

    command -v guix >/dev/null || die "ไม่พบ guix command — อยู่บน Guix System จริงไหม?"

    # ─── STEP 0: ตรวจ spec เครื่อง + คำนวณ build params ───
    step "STEP 0/9 — ตรวจ spec เครื่อง + คำนวณ build params"
    CPU_CORES=$(nproc)
    MEM_GB=$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo)
    SWAP_GB=$(awk '/SwapTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo)
    mkdir -p "$(dirname "$BUILD_ROOT")"
    DISK_TARGET="$(dirname "$BUILD_ROOT")"
    DISK_AVAIL_GB=$(df -BG --output=avail "$DISK_TARGET" | tail -1 | tr -dc '0-9')

    # สูตร -j: R8/proguard ใช้ JVM heap 4GB ต่อ job → กัน 4GB ให้ OS
    J_BY_RAM=$(( (MEM_GB - 4) / 4 ))
    [[ $J_BY_RAM -lt 1 ]] && J_BY_RAM=1
    JOBS=$(( J_BY_RAM < CPU_CORES ? J_BY_RAM : CPU_CORES ))
    [[ $JOBS -lt 1 ]] && JOBS=1

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
  Guix manifest  : ${MANIFEST_SRC}

EOF

    if [[ $((MEM_GB + SWAP_GB)) -lt 16 ]]; then
        warn "RAM+Swap น้อยกว่า 16GB — Guix System: เพิ่ม swap ด้วยตัวเอง"
        warn "  เช่น: su -c 'fallocate -l 8G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile'"
        ask_yes "RAM ตึง — ดำเนินการต่อ?" || die "ยกเลิก"
    fi

    NEED_GB=$DISK_PARALLEL_GB
    if [[ $DISK_AVAIL_GB -lt $NEED_GB ]]; then
        if [[ $DISK_AVAIL_GB -ge $DISK_SERIAL_GB ]]; then
            warn "Disk ${DISK_AVAIL_GB}GB ไม่พอ build parallel — จะ build serial + clean out/<DEV>"
            [[ "$CLEAN_OUT_AFTER" == "auto" ]] && CLEAN_OUT_AFTER=1
            ask_yes "ดำเนินการต่อ?" || die "ยกเลิก"
        else
            warn "Disk ${DISK_AVAIL_GB}GB ไม่พอแม้ build serial (${DISK_SERIAL_GB}GB)"
            ask_yes "ยังจะลองต่อ?" || die "ยกเลิก"
            [[ "$CLEAN_OUT_AFTER" == "auto" ]] && CLEAN_OUT_AFTER=1
        fi
    else
        [[ "$CLEAN_OUT_AFTER" == "auto" ]] && CLEAN_OUT_AFTER=0
    fi

    # ─── pre-check: artifact เดิมพร้อม flash? ───
    FORCE_REBUILD="${FORCE_REBUILD:-0}"
    SKIP_BUILD=0
    if [[ "$FORCE_REBUILD" != "1" && -d "$BUILD_ROOT/releases" ]]; then
        step "PRE-CHECK — ตรวจหา build เดิมที่พร้อม flash"
        declare -a _found_paths=() _found_bn=()
        _all_ok=1
        for _D in "${DEVICES[@]}"; do
            _latest=""
            for _cand in $(ls -d "$BUILD_ROOT/releases/"*/"release-${_D}-"*/ 2>/dev/null | sort -r); do
                _bn=$(basename "$(dirname "$_cand")")
                _has_install=0
                [[ -f "${_cand}${_D}-install-${_bn}.zip" ]] && _has_install=1
                [[ -x "${_cand}${_D}-install-${_bn}/flash-all.sh" ]] && _has_install=1
                if [[ -f "${_cand}${_D}-factory-${_bn}.zip" && -f "${_cand}${_D}-ota_update-${_bn}.zip" && "$_has_install" == "1" ]]; then
                    _latest="$_cand"; break
                fi
            done
            if [[ -n "$_latest" ]]; then
                _found_paths+=("${_latest%/}"); _found_bn+=("$(basename "$(dirname "$_latest")")")
                info "พบ [$_D]: $_latest"
            else
                warn "ไม่พบ build พร้อม flash สำหรับ [$_D]"; _all_ok=0
            fi
        done

        if [[ "$_all_ok" == "1" ]]; then
            _bn0="${_found_bn[0]}"; _consistent=1
            for _b in "${_found_bn[@]}"; do [[ "$_b" == "$_bn0" ]] || _consistent=0; done
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
                    export GOS_SKIP_BUILD=1 GOS_BUILD_NUMBER="$_bn0"
                    export GOS_OUT_PATHS="$(IFS=':'; echo "${_found_paths[*]}")"
                fi
            fi
        fi
    fi

    # ─── เตรียม BUILD_ROOT + คัดลอก patch-grapheneos.sh ───
    # หมายเหตุ: ต้องสร้างทุก dir ก่อน exec เข้า container เพราะ --share=
    #          จะ fail ถ้า source dir ไม่มี (statfs error)
    mkdir -p "$BUILD_ROOT" "$ADEV_DL" \
             "$HOME/.bin" "$HOME/.local/bin" \
             "$HOME/.cache/corepack" "$HOME/.cache/ccache" \
             "$HOME/.config/grapheneos" \
             "$HOME/.gnupg"
    chmod 700 "$HOME/.gnupg"
    cp -f "$PATCH_SRC" "$BUILD_ROOT/patch-grapheneos.sh"
    chmod +x "$BUILD_ROOT/patch-grapheneos.sh"

    # ─── STEP 1: เตรียม Guix profile (long install ครั้งแรก) ───
    step "STEP 1/9 — Guix shell pre-warm (manifest = $MANIFEST_SRC)"
    info "ครั้งแรกอาจดาวน์โหลด ~200MB; รอบถัดไปใช้ cache"
    # Trick: รัน `guix shell -m ... -- true` ครั้งหนึ่งเพื่อ pre-build profile
    # (เก็บใน /gnu/store; ครั้งหน้า guix shell ใช้ทันที)
    guix shell -m "$MANIFEST_SRC" --container --emulate-fhs --network --no-cwd \
        -- true || die "Guix shell pre-warm ล้มเหลว — ตรวจ manifest หรือ network"
    log "Guix profile พร้อม"

    # ─── Re-exec เข้า FHS container ───
    step "เข้า FHS container (guix shell --emulate-fhs --container)"
    info "ตั้งแต่นี้ทุก step ทำงานในนาเมสเปซแยก — ไม่กระทบ host"

    export GOS_GUIX_INSIDE=1
    export GOS_JOBS="$JOBS"
    export GOS_CLEAN_OUT_AFTER="$CLEAN_OUT_AFTER"
    export GOS_DEVICES="${DEVICES[*]}"

    # คัดลอก .gitconfig ของ host (ถ้ามี) → $BUILD_ROOT/.gitconfig
    # เพื่อให้ git inside container เห็น identity เดิม และ "เขียนได้" (ไม่ติด bind-mount file)
    # ─── issue: --share=$HOME/.gitconfig (file mount) → git config rename fails ──
    if [[ -f "$HOME/.gitconfig" && ! -f "$BUILD_ROOT/.gitconfig" ]]; then
        cp "$HOME/.gitconfig" "$BUILD_ROOT/.gitconfig"
    fi
    touch "$BUILD_ROOT/.gitconfig"
    export GOS_GIT_CONFIG_GLOBAL="$BUILD_ROOT/.gitconfig"

    # หมายเหตุ: bind mounts (--share)
    #   --network             → DNS + HTTPS สำหรับ curl/git/repo/adevtool
    #   --preserve=...        → keep env vars ที่จำเป็นข้ามเข้า container
    #   --share=$BUILD_ROOT   → bind-mount source tree (read-write)
    #   --share=$ADEV_DL      → bind-mount adevtool downloads
    #   --share=$HOME/.bin    → repo binary (Google upstream)
    #   --share=$HOME/.local  → corepack yarn shim
    #   --share=$HOME/.cache  → corepack cache + ccache (ถ้าไม่ใช้ in-tree)
    #   --share=$HOME/.config → allowed_signers (GrapheneOS pub key list)
    #   --share=$HOME/.gnupg  → keyring สำหรับ git verify-tag + GPG pack
    exec guix shell -m "$MANIFEST_SRC" \
        --container --emulate-fhs --network \
        --preserve='^GOS_|^HOME$|^USER$|^TERM$|^LOG_FILE$|^BUILD_ROOT$|^ADEV_DL$|^GOS_TAG$|^GIT_NAME$|^GIT_EMAIL$|^SKIP_SYNC$|^CCACHE_SIZE$|^CCACHE_DIR_VAR$|^FORCE_REBUILD$|^SKIP_GPG$|^GPG_RECIPIENT$|^GPG_PASSPHRASE$|^GPG_OUT_DIR$|^ASSUME_YES$|^LANG$' \
        --share="$BUILD_ROOT" \
        --share="$ADEV_DL" \
        --share="$HOME/.bin" \
        --share="$HOME/.local" \
        --share="$HOME/.cache" \
        --share="$HOME/.config" \
        --share="$HOME/.gnupg" \
        -- bash "$0" "${DEVICES[@]}"
fi  # end Phase 1

# ═══════════════════════════════════════════════════════════════════════
# Phase 2 — INSIDE FHS container: ทุก build step
# ═══════════════════════════════════════════════════════════════════════
exec > >(tee -a "$LOG_FILE") 2>&1
info "(inside FHS container) PID=$$ HOME=$HOME PATH=$PATH"

# Restore deferred env vars
JOBS="${GOS_JOBS:-4}"
CLEAN_OUT_AFTER="${GOS_CLEAN_OUT_AFTER:-0}"
SKIP_BUILD="${GOS_SKIP_BUILD:-0}"
BUILD_NUMBER="${GOS_BUILD_NUMBER:-}"
declare -a OUT_PATHS=()
if [[ -n "${GOS_OUT_PATHS:-}" ]]; then
    IFS=':' read -ra OUT_PATHS <<< "$GOS_OUT_PATHS"
fi

# Env สำหรับ FHS container — กำหนดให้ AOSP prebuilt binaries หา libs เจอ
export PATH="$HOME/.local/bin:$HOME/.bin:$PATH"
export LD_LIBRARY_PATH="$BUILD_ROOT/prebuilts/build-tools/linux-x86/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
# git config: ใช้ไฟล์ที่ writable ใน $BUILD_ROOT (bind-mount file rename ไม่ได้)
export GIT_CONFIG_GLOBAL="${GOS_GIT_CONFIG_GLOBAL:-$BUILD_ROOT/.gitconfig}"
# ccache settings (CCACHE_EXEC ตั้งทีหลังเมื่อ ccache available)
export USE_CCACHE=1 CCACHE_DIR="$CCACHE_DIR_VAR"

# ─── locales — สำคัญสำหรับ Soong (Go binary ต้องการ C.UTF-8) ─────────
# ปัญหา: Soong (build/soong/ui/build/config.go:configureLocale) เรียก
#       `locale -a` เพื่อตรวจว่า C.UTF-8 มีไหม แต่ Guix glibc-for-fhs's
#       locale binary มี bug — return แค่ "C\nPOSIX" ถึงแม้ /usr/lib/locale/2.41/
#       จะมี C.UTF-8 ครบ → Soong fail "doesn't support C.UTF-8"
# วิธีแก้: shim locale wrapper ใน $HOME/.local/bin/locale ที่ list directory ตรง ๆ
if [[ -z "${GUIX_LOCPATH:-}" ]]; then
    _glp=$(ls -d /gnu/store/*-profile/lib/locale 2>/dev/null | head -1)
    [[ -n "$_glp" ]] && export GUIX_LOCPATH="$_glp"
fi
export LANG="${LANG:-C.UTF-8}" LC_ALL="${LC_ALL:-C.UTF-8}"
# ติดตั้ง locale wrapper (intercept -a เพื่อให้ Soong build ผ่าน)
if [[ ! -x "$HOME/.local/bin/locale" ]]; then
    cat > "$HOME/.local/bin/locale" <<'LOCWRAPPER'
#!/usr/bin/env bash
# locale wrapper — แก้ bug glibc-for-fhs's `locale -a` (Guix FHS container)
# ─── จำเป็นเพราะ Soong UI (Go) ใช้ `locale -a` ตรวจ C.UTF-8 (audit) ───
REAL_LOCALE=/gnu/store/$(ls /gnu/store 2>/dev/null | grep -E '^[a-z0-9]+-glibc-for-fhs-[0-9.]+$' | head -1)/bin/locale
[[ -x "$REAL_LOCALE" ]] || REAL_LOCALE=/usr/bin/locale.real
if [[ "$1" == "-a" ]]; then
    for d in /usr/lib/locale/[0-9]*; do
        [[ -d "$d" ]] && ls -1 "$d" 2>/dev/null
    done | sort -u
    echo C
    echo POSIX
else
    exec "$REAL_LOCALE" "$@"
fi
LOCWRAPPER
    chmod +x "$HOME/.local/bin/locale"
fi

# CA certs (Guix nss-certs)
export SSL_CERT_DIR="${SSL_CERT_DIR:-/etc/ssl/certs}"
export GIT_SSL_CAINFO="${GIT_SSL_CAINFO:-$SSL_CERT_DIR/ca-bundle.crt}"
export CURL_CA_BUNDLE="${CURL_CA_BUNDLE:-/etc/ssl/certs/ca-certificates.crt}"

# trap: log สถานะสุดท้าย
trap '_rc=$?; printf "\n%s[exit]%s rc=%d  started=%s ended=%s\n" "$([[ $_rc -eq 0 ]] && echo "$c_grn" || echo "$c_red")" "$c_off" "$_rc" "$_started_at" "$(date -Iseconds 2>/dev/null || date)"; exit $_rc' EXIT

if [[ "$SKIP_BUILD" != "1" ]]; then

# ─── STEP 2: ติดตั้ง repo + git identity + allowed_signers ───
step "STEP 2/9 — ติดตั้ง repo + ตั้ง git identity + allowed_signers"
# audit: `repo` มาจาก Google Storage (upstream tool, ไม่มีใน Guix)
#         storage.googleapis.com/git-repo-downloads/repo
if [[ ! -x "$HOME/.bin/repo" ]]; then
    curl -fsSL https://storage.googleapis.com/git-repo-downloads/repo \
         -o "$HOME/.bin/repo"
    chmod a+x "$HOME/.bin/repo"
fi

# git identity (ใช้ค่า env หรือ user@hostname เป็น default)
# fallback: HOSTNAME shell builtin → /etc/hostname → localhost (กัน container ไม่มี hostname binary)
HOST_FQDN="$(hostname -f 2>/dev/null || hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || echo "${HOSTNAME:-localhost}")"
[[ -z "$HOST_FQDN" || "$HOST_FQDN" == "(none)" ]] && HOST_FQDN="localhost"
if ! git config --global user.email >/dev/null 2>&1; then
    git config --global user.email "${GIT_EMAIL:-${USER}@${HOST_FQDN}}"
fi
if ! git config --global user.name >/dev/null 2>&1; then
    git config --global user.name "${GIT_NAME:-${USER}}"
fi
info "git identity: $(git config --global user.name) <$(git config --global user.email)>"

# allowed_signers (GrapheneOS pub keys สำหรับ verify-tag)
# audit: ดาวน์โหลดจาก https://grapheneos.org/allowed_signers (upstream)
if [[ ! -s "$HOME/.config/grapheneos/allowed_signers" ]]; then
    curl -fsSL https://grapheneos.org/allowed_signers \
         -o "$HOME/.config/grapheneos/allowed_signers"
fi
git config --global gpg.ssh.allowedSignersFile "$HOME/.config/grapheneos/allowed_signers"

# ccache (ติดตั้งจาก Guix manifest — set max-size)
mkdir -p "$CCACHE_DIR_VAR"
ccache -M "$CCACHE_SIZE" >/dev/null 2>&1 || warn "ccache config ล้มเหลว"
export CCACHE_EXEC="$(command -v ccache)"

# corepack yarn (มากับ Node ของ Guix — ไม่ใช่ Guix package เอง)
# audit: corepack 0.31.0 มากับ node@22 (Node.js project upstream)
if [[ ! -x "$HOME/.local/bin/yarn" ]]; then
    log "เปิด corepack + เตรียม yarn classic 1.22.x"
    export COREPACK_HOME="$HOME/.cache/corepack"
    corepack prepare yarn@1.22.22 --activate >/dev/null 2>&1 || true
    corepack enable yarn --install-directory "$HOME/.local/bin" \
        2>&1 | head -3 || warn "corepack enable yarn fail — จะใช้ npx yarn"
fi
if command -v yarn >/dev/null 2>&1; then
    info "yarn version: $(yarn --version 2>&1 | head -1)"
fi

# ─── STEP 3: repo init + verify tag + sync ───
step "STEP 3/9 — repo init/verify/sync (tag $GOS_TAG)"
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
            SYNC_OK=1; break
        fi
        warn "repo sync ล้มเหลว — รอ 30 วินาทีแล้วลองใหม่ด้วย -j ที่ต่ำลง"
        sleep 30
    done
    [[ "$SYNC_OK" == "1" ]] || die "repo sync ล้มเหลวทั้งหมด"
    echo "$GOS_TAG" > .gos-synced-tag
fi

# ─── STEP 4: patch source + generate keys ───
step "STEP 4/9 — patch source (ปิด Updater + สร้าง keys/AVB)"
"$BUILD_ROOT/patch-grapheneos.sh" "${DEVICES[@]}"
for _D in "${DEVICES[@]}"; do
    for _K in bluetooth gmscompat_lib media networkstack nfc platform releasekey sdk_sandbox shared; do
        [[ -f "$BUILD_ROOT/keys/$_D/$_K.pk8" && -f "$BUILD_ROOT/keys/$_D/$_K.x509.pem" ]] \
            || die "Patch ไม่สมบูรณ์: ขาด keys/$_D/$_K"
    done
    [[ -f "$BUILD_ROOT/keys/$_D/avb.pem" && -f "$BUILD_ROOT/keys/$_D/avb_pkmd.bin" ]] \
        || die "Patch ไม่สมบูรณ์: ขาด keys/$_D/avb"
done
log "ยืนยัน keys ครบ"

# ─── STEP 4.3: patch adevtool ให้ทำงานบน Node 22 ───
# ─── issue: vendor/adevtool/bin/run hardcode `MIN_NODE_MAJOR_VERSION = 24`
#           แต่ Guix official channel มี Node แค่ 22.14.0 (latest)
# ─── ทดสอบแล้ว: adevtool ทำงานได้บน Node 22 — version check overly cautious
# ─── audit: patch ในไฟล์ source tree (จาก repo manifest GrapheneOS)
#           ครั้งหน้า repo sync จะ revert → ต้อง patch ใหม่
ADEV_RUN="$BUILD_ROOT/vendor/adevtool/bin/run"
if [[ -f "$ADEV_RUN" ]] && grep -q "MIN_NODE_MAJOR_VERSION = 24" "$ADEV_RUN"; then
    step "STEP 4.3/9 — patch adevtool: ลด MIN_NODE_MAJOR_VERSION 24 → 22"
    sed -i 's/MIN_NODE_MAJOR_VERSION = 24/MIN_NODE_MAJOR_VERSION = 22/' "$ADEV_RUN"
    log "patch adevtool/bin/run แล้ว"
fi

# ─── issue: adevtool reject stderr "Build sandboxing disabled due to nsjail error."
#           Soong nsjail ทำงานในซ้อน guix container ไม่ได้ → fallback (warning ที่ stderr)
#           แต่ adevtool's isStderrLineAllowed อนุญาตแค่ "setpriority(5): Permission denied"
# ─── audit: patch ใน vendor/adevtool/src/config/paths.ts (จาก repo manifest GrapheneOS)
#           ครั้งหน้า repo sync จะ revert → script patch ใหม่อัตโนมัติ
ADEV_PATHS="$BUILD_ROOT/vendor/adevtool/src/config/paths.ts"
if [[ -f "$ADEV_PATHS" ]] && ! grep -q "Build sandboxing disabled" "$ADEV_PATHS"; then
    info "patch adevtool/src/config/paths.ts: allow nsjail warning"
    # ใช้ sed line replace แทน s/// เพราะ || + " ใน expression ทำให้ sed บางตัวงง
    _line=$(grep -n "setpriority(5): Permission denied" "$ADEV_PATHS" | head -1 | cut -d: -f1)
    if [[ -n "$_line" ]]; then
        sed -i "${_line}c\\
        return line.endsWith(\"setpriority(5): Permission denied\") || line.includes(\"Build sandboxing disabled\")" "$ADEV_PATHS"
    fi
fi

# ─── STEP 4.4: ล้าง vendor/google_devices/ ทั้งหมด — STEP 6 จะ regen ใหม่ ───
# ─── issue: adevtool generate-all เก่าทิ้ง vendor blob ค้างไว้
#           ที่อาจไม่ครบ (system_ext/bin/gs_watchdogd, ฯลฯ) → Soong fail
# ─── audit: vendor/google_devices/* ทั้งหมดเกิดจาก adevtool (ไม่ใช่ repo manifest)
#           ปลอดภัยที่จะลบทั้งหมด — STEP 6 ก่อน build (STEP 7) จะ regen ใหม่
# ─── สำคัญ: ลบทั้งหมด ไม่ใช่แค่ device ที่ไม่ใช้ เพราะ stale blob ของ DEVICE
#            ที่จะ build อาจไม่ครบ (เช่น run ก่อนหน้า crash กลางทาง)
if [[ -d "$BUILD_ROOT/vendor/google_devices" ]]; then
    step "STEP 4.4/9 — ล้าง vendor/google_devices/ ทั้งหมด (STEP 6 จะ regen)"
    _removed=0
    for _d in "$BUILD_ROOT/vendor/google_devices"/*/; do
        _dname=$(basename "$_d")
        rm -rf "$_d"
        _removed=$((_removed + 1))
    done
    log "ลบไป $_removed device dirs"
fi

# ─── STEP 4.5: patchelf AOSP prebuilts (one-time per repo sync) ───
# ─── issue: Soong filters LD_LIBRARY_PATH ทำให้ ninja หา libjemalloc5.so ไม่เจอ
#           แก้ด้วย patchelf RUNPATH=$ORIGIN/../lib64 (binary หา lib ได้จาก path สัมพัทธ์)
#           audit: ใช้ patchelf จาก Guix manifest, ปรับเฉพาะ binary ใน prebuilts/build-tools/
PATCHELF_MARK="$BUILD_ROOT/.gos-patchelf-done-$GOS_TAG"
if [[ ! -f "$PATCHELF_MARK" ]]; then
    step "STEP 4.5/9 — patchelf AOSP prebuilts (one-time)"
    _patched=0
    # Disable errexit ระหว่าง patchelf (บาง binary ไม่มี dynamic section → patchelf fail)
    set +e

    # ── helper: ตรวจว่าไฟล์เป็น Python zipapp (มี ZIP appended ที่ท้าย ELF) ──
    # ─── issue: patchelf จะทำให้ section header shift → offsets ใน ZIP central
    #           directory ไม่ตรง → py3-cmd ใช้งานไม่ได้ ("encodings not found")
    # ─── detect: tail 64KB หา PK signature (ZIP EOCD/CDR markers)
    is_zipapp() {
        local _f="$1"
        tail -c 65536 "$_f" 2>/dev/null | LC_ALL=C grep -aqP '\x50\x4b\x05\x06|\x50\x4b\x01\x02'
    }

    # ── Phase A: bin/ binaries → RPATH=$ORIGIN/<rel-to-lib> ──
    declare -a PATCH_PAIRS=(
        "prebuilts/build-tools/linux-x86/bin:../lib64"
    )
    for _clangdir in "$BUILD_ROOT"/prebuilts/clang/host/linux-x86/clang-*; do
        [[ -d "$_clangdir/bin" && -d "$_clangdir/lib" ]] || continue
        _rel=${_clangdir#$BUILD_ROOT/}
        PATCH_PAIRS+=("$_rel/bin:../lib")
    done
    for _rustdir in "$BUILD_ROOT"/prebuilts/rust/linux-x86/*/; do
        [[ -d "${_rustdir}bin" && -d "${_rustdir}lib" ]] || continue
        _rel=${_rustdir#$BUILD_ROOT/}
        _rel=${_rel%/}
        PATCH_PAIRS+=("$_rel/bin:../lib")
    done
    for _godir in "$BUILD_ROOT"/prebuilts/go/linux-x86; do
        [[ -d "$_godir/bin" ]] || continue
        _rel=${_godir#$BUILD_ROOT/}
        PATCH_PAIRS+=("$_rel/bin:../lib")
    done
    for _jdkdir in "$BUILD_ROOT"/prebuilts/jdk/jdk*/linux-x86; do
        [[ -d "$_jdkdir/bin" ]] || continue
        _rel=${_jdkdir#$BUILD_ROOT/}
        PATCH_PAIRS+=("$_rel/bin:../lib")
    done
    for _pair in "${PATCH_PAIRS[@]}"; do
        _bindir="$BUILD_ROOT/${_pair%:*}"
        _libRel="${_pair#*:}"
        [[ -d "$_bindir" ]] || continue
        info "patchelf bin $_bindir → \$ORIGIN/$_libRel"
        while IFS= read -r -d '' _bin; do
            if head -c 4 "$_bin" 2>/dev/null | grep -q $'^\x7fELF'; then
                # ข้าม Python zipapp — patchelf จะทำลาย ZIP offsets
                if is_zipapp "$_bin"; then
                    info "  skip zipapp: $(basename "$_bin")"
                    continue
                fi
                if patchelf --set-rpath "\$ORIGIN/$_libRel" "$_bin" 2>/dev/null; then
                    _patched=$((_patched + 1))
                fi
            fi
        done < <(find "$_bindir" -maxdepth 1 -type f -executable -print0)
    done

    # ── Phase B: lib/*.so transitive deps → RPATH=$ORIGIN (same dir) ──
    # librustc_driver-*.so มี hardcoded RPATH=/lib/x86_64-linux-gnu → หา libLLVM ไม่เจอ
    # AOSP prebuilt ส่วนใหญ่ขนของไว้ใน lib/ เดียวกัน → $ORIGIN พอแล้ว
    declare -a LIB_DIRS=(
        "$BUILD_ROOT/prebuilts/build-tools/linux-x86/lib64"
    )
    for _clangdir in "$BUILD_ROOT"/prebuilts/clang/host/linux-x86/clang-*; do
        [[ -d "$_clangdir/lib" ]] && LIB_DIRS+=("$_clangdir/lib")
        [[ -d "$_clangdir/lib64" ]] && LIB_DIRS+=("$_clangdir/lib64")
    done
    for _rustdir in "$BUILD_ROOT"/prebuilts/rust/linux-x86/*/; do
        [[ -d "${_rustdir}lib" ]] && LIB_DIRS+=("${_rustdir%/}/lib")
    done
    # RPATH = $ORIGIN (same dir) + ../lib + ../lib64 — handle lib/lib64 split
    # (e.g. rust: libc++.so อยู่ lib64/, librustc_driver.so อยู่ lib/)
    for _libdir in "${LIB_DIRS[@]}"; do
        [[ -d "$_libdir" ]] || continue
        info "patchelf lib $_libdir → \$ORIGIN:\$ORIGIN/../lib:\$ORIGIN/../lib64"
        while IFS= read -r -d '' _so; do
            if head -c 4 "$_so" 2>/dev/null | grep -q $'^\x7fELF'; then
                if patchelf --set-rpath '$ORIGIN:$ORIGIN/../lib:$ORIGIN/../lib64' "$_so" 2>/dev/null; then
                    _patched=$((_patched + 1))
                fi
            fi
        done < <(find "$_libdir" -maxdepth 1 -name '*.so*' -type f -print0)
    done
    # rust ยังมี lib64/ ที่ต้อง patchelf (libc++.so)
    declare -a LIB64_DIRS=()
    for _rustdir in "$BUILD_ROOT"/prebuilts/rust/linux-x86/*/; do
        [[ -d "${_rustdir}lib64" ]] && LIB64_DIRS+=("${_rustdir%/}/lib64")
    done
    for _libdir in "${LIB64_DIRS[@]}"; do
        [[ -d "$_libdir" ]] || continue
        info "patchelf lib64 $_libdir → \$ORIGIN:\$ORIGIN/../lib:\$ORIGIN/../lib64"
        while IFS= read -r -d '' _so; do
            if head -c 4 "$_so" 2>/dev/null | grep -q $'^\x7fELF'; then
                if patchelf --set-rpath '$ORIGIN:$ORIGIN/../lib:$ORIGIN/../lib64' "$_so" 2>/dev/null; then
                    _patched=$((_patched + 1))
                fi
            fi
        done < <(find "$_libdir" -maxdepth 1 -name '*.so*' -type f -print0)
    done

    set -e
    log "patchelf เสร็จ ($_patched ELF files)"
    touch "$PATCHELF_MARK"
fi

# ─── STEP 5: adevtool yarn install + aapt2 ───
step "STEP 5/9 — เตรียม adevtool (yarn install) + build aapt2"
YARN_CMD="yarn"
command -v yarn >/dev/null 2>&1 || YARN_CMD="npx --yes yarn@1.22.22"

(
    set +u
    cd "$BUILD_ROOT/vendor/adevtool"
    $YARN_CMD install --frozen-lockfile \
        || ( warn "yarn frozen-lockfile fail — ลอง install ธรรมดา"; $YARN_CMD install )
)

(
    set +u
    cd "$BUILD_ROOT"
    # shellcheck disable=SC1091
    source build/envsetup.sh
    lunch sdk_phone64_x86_64-cur-user
    m -j"$JOBS" aapt2
)

# ─── STEP 6/7/8: per-device — vendor blobs + build + sign ───
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

    # ตรวจว่า adevtool extract blob ได้จริง (กัน case ที่ exit 0 แต่ไม่ได้ blob)
    if ! ls "$BUILD_ROOT/vendor/google_devices/$DEVICE/proprietary/" 2>/dev/null | head -3 | grep -q .; then
        die "STEP 6 [$DEVICE] — adevtool ไม่ extract blob (ตรวจ network/factory URL)"
    fi

    # ลบ adevtool intermediates เพื่อเซฟ disk
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
    ) || die "STEP 7 [$DEVICE] — m build ล้มเหลว"

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

# ─── STEP 9: pack flashable + keys → GPG ───
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

    DEVICES_ARR=( ${GOS_DEVICES:-${DEVICES[*]}} )
    BUNDLE_BASENAME="grapheneos-${BUILD_NUMBER}-$(IFS=_; echo "${DEVICES_ARR[*]}")"
    BUNDLE_TAR="$GPG_OUT_DIR/${BUNDLE_BASENAME}.tar"
    GPG_BUNDLE="${BUNDLE_TAR}.gpg"
    README_FILE="$GPG_OUT_DIR/${BUNDLE_BASENAME}.README.txt"

    TAR_INCLUDES=()
    for DEVICE in "${DEVICES_ARR[@]}"; do
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
            log "encrypt → $GPG_BUNDLE  [$GPG_MODE]"
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

    shred -u "$BUNDLE_TAR" 2>/dev/null || rm -f "$BUNDLE_TAR"
    GPG_SIZE=$(du -h "$GPG_BUNDLE" | awk '{print $1}')
    GPG_SHA=$(sha256sum "$GPG_BUNDLE" | awk '{print $1}')

    cat > "$README_FILE" <<README
GrapheneOS Flashable Bundle (Built on Guix System via FHS container)
====================================================================
Build number : $BUILD_NUMBER
Devices      : ${DEVICES_ARR[*]}
Encrypt mode : $GPG_MODE
Bundle file  : $GPG_BUNDLE
Bundle size  : $GPG_SIZE
SHA-256      : $GPG_SHA
Created at   : $(date -Iseconds 2>/dev/null || date)
Source host  : $(hostname -f 2>/dev/null || hostname) (Guix System)

วิธีย้ายไปเครื่องอื่น (host ที่ต่อ Pixel ผ่าน USB)
--------------------------------------------------
1) คัดลอก 2 ไฟล์: $(basename "$GPG_BUNDLE") + $(basename "$README_FILE")
2) ตรวจ SHA-256:  sha256sum $(basename "$GPG_BUNDLE")   # ต้องตรงกับ $GPG_SHA
3) ถอดรหัส + extract:
     gpg --decrypt $(basename "$GPG_BUNDLE") | tar -xvf -

4) Flash + lock bootloader (Pixel):
     # เปิด OEM unlocking ใน Developer options ก่อน
     cd releases/$BUILD_NUMBER/release-<DEVICE>-${BUILD_NUMBER}/
     unzip -o <DEVICE>-factory-${BUILD_NUMBER}.zip
     adb reboot bootloader
     fastboot flashing unlock                            # ครั้งแรก, จะ wipe
     cd <DEVICE>-factory-${BUILD_NUMBER}/
     ./flash-all.sh                                      # Linux/macOS
     fastboot flash avb_custom_key ../../../../keys/<DEVICE>/avb_pkmd.bin
     fastboot flashing lock                              # wipe อีกครั้ง
     fastboot reboot

หมายเหตุ: keys/<DEVICE>/*.pk8 + avb.pem เป็น private keys ห้าม leak
README

    info "README: $README_FILE"
fi

# ─── รายงานผลลัพธ์ ───
step "เสร็จสิ้น — สรุปผลลัพธ์"
DEVICES_DISP=( ${GOS_DEVICES:-${DEVICES[*]}} )
echo
echo "==================== READY TO FLASH ===================="
echo "Build number : $BUILD_NUMBER"
echo "Source root  : $BUILD_ROOT (Guix System + FHS container)"
echo "Log file     : $LOG_FILE"
echo
echo "AVB / signing keys per device:"
for DEVICE in "${DEVICES_DISP[@]}"; do
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
