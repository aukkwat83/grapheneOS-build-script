#!/usr/bin/env bash
# pack-gpg-guix.sh — pack flashable GrapheneOS artifacts + keys → tar | gpg
#
# ─── ออกแบบ ────────────────────────────────────────────────────────────
# แยกออกจาก one-all-stop-build-grapheneos-on-guixsystem-150withgpg.sh
# เพื่อให้รันแยกได้หลัง build เสร็จ (ไม่ต้อง re-trigger Phase 1 ของ main script)
#
# Phase 1 (outside container) → re-exec เข้า FHS container (มี gpg + tar + shred)
# Phase 2 (inside  container) → tar artifacts + keys → encrypt → shred plain
#
# ─── การใช้งาน ─────────────────────────────────────────────────────────
#   bash pack-gpg-guix.sh [OPTIONS] DEVICE [DEVICE...]
#
# Options (env หรือ flag):
#   --build-number YYYYMMDDxx    (required) build เลขที่จะ pack
#   --build-root PATH            default: ~/grapheneos
#   --out-dir PATH               default: ~ (ที่เก็บ .tar.gpg + README)
#   --skip-encrypt               เก็บ tar plain ไว้ (debug — ปลอดภัยน้อย)
#
# Env ที่ใช้ได้ (แทน flag):
#   BUILD_NUMBER, BUILD_ROOT, GPG_OUT_DIR
#   GPG_PASSPHRASE=<pw>          symmetric AES256 (batch ไม่ prompt)
#   GPG_RECIPIENT=<key|email>    asymmetric encrypt (แนะนำ — ไม่ leak passphrase)
#   ถ้าไม่ตั้งทั้งคู่ + เป็น TTY → script จะ prompt passphrase ด้วย read -s
#   ถ้าไม่ตั้งทั้งคู่ + ไม่ใช่ TTY → die (ใช้ env หรือใส่ -t ใน ssh)
#
# ─── ตัวอย่าง ───────────────────────────────────────────────────────────
#   BUILD_NUMBER=2026051201 bash pack-gpg-guix.sh shiba
#   BUILD_NUMBER=2026051201 GPG_RECIPIENT=me@x.com bash pack-gpg-guix.sh shiba husky
#   ssh -t guix@vm 'bash pack-gpg-guix.sh --build-number 2026051201 shiba'   # interactive
#
# ─── ไฟล์ผลลัพธ์ ────────────────────────────────────────────────────────
#   $GPG_OUT_DIR/grapheneos-<BUILD_NUMBER>-<DEVICES>.tar.gpg
#   $GPG_OUT_DIR/grapheneos-<BUILD_NUMBER>-<DEVICES>.README.txt

set -Eeuo pipefail

# ─── color helpers (no-op ถ้าไม่ใช่ tty) ─────────────────────────────
if [[ -t 2 ]]; then
    c_grn='\033[1;32m'; c_red='\033[1;31m'; c_yel='\033[1;33m'
    c_blu='\033[1;34m'; c_cya='\033[1;36m'; c_off='\033[0m'
else
    c_grn=''; c_red=''; c_yel=''; c_blu=''; c_cya=''; c_off=''
fi
log()  { printf "${c_grn}[+]${c_off} %s\n" "$*" >&2; }
info() { printf "${c_blu}[i]${c_off} %s\n" "$*" >&2; }
warn() { printf "${c_yel}[!]${c_off} %s\n" "$*" >&2; }
die()  { printf "${c_red}[x]${c_off} %s\n" "$*" >&2; exit 1; }
step() { printf "\n${c_cya}==== %s ====${c_off}\n" "$*" >&2; }

# ─── parse args ───────────────────────────────────────────────────────
DEVICES=()
SKIP_ENCRYPT=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            sed -n '2,32p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        --build-number)  BUILD_NUMBER="$2"; shift 2 ;;
        --build-root)    BUILD_ROOT="$2";   shift 2 ;;
        --out-dir)       GPG_OUT_DIR="$2";  shift 2 ;;
        --skip-encrypt)  SKIP_ENCRYPT=1;    shift   ;;
        --) shift; DEVICES+=("$@"); break ;;
        -*) die "unknown option: $1" ;;
        *)  DEVICES+=("$1"); shift ;;
    esac
done

BUILD_ROOT="${BUILD_ROOT:-$HOME/grapheneos}"
GPG_OUT_DIR="${GPG_OUT_DIR:-$HOME}"
[[ -n "${BUILD_NUMBER:-}" ]] || die "--build-number ไม่ได้ระบุ (หรือ env BUILD_NUMBER)"
[[ ${#DEVICES[@]} -gt 0 ]]    || die "ต้องระบุอย่างน้อย 1 device (เช่น shiba)"
[[ -d "$BUILD_ROOT" ]]        || die "ไม่พบ BUILD_ROOT: $BUILD_ROOT"

# ─── Phase 1 — Outside FHS container ─────────────────────────────────
# Re-exec เข้า guix shell ถ้ายังไม่อยู่ใน container (detect ด้วย GOS_GPG_INSIDE)
if [[ "${GOS_GPG_INSIDE:-0}" != "1" ]]; then
    info "Phase 1 — เตรียม Guix FHS container"

    # หา guix-manifest.scm จาก BUILD_ROOT → script dir → cwd
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    MANIFEST=""
    for c in "$BUILD_ROOT/guix-manifest.scm" \
             "$SCRIPT_DIR/guix-manifest.scm" \
             "$PWD/guix-manifest.scm"; do
        if [[ -f "$c" ]]; then MANIFEST="$c"; break; fi
    done
    [[ -n "$MANIFEST" ]] || die "ไม่พบ guix-manifest.scm (ค้นใน $BUILD_ROOT, $SCRIPT_DIR, $PWD)"
    info "manifest: $MANIFEST"

    # คัดลอก script เข้า BUILD_ROOT (shared) ถ้ายังไม่อยู่ — กัน /tmp ใน container หาย
    SCRIPT_IN_ROOT="$BUILD_ROOT/pack-gpg-guix.sh"
    if [[ "$(readlink -f "${BASH_SOURCE[0]}")" != "$(readlink -f "$SCRIPT_IN_ROOT" 2>/dev/null)" ]]; then
        cp -f "${BASH_SOURCE[0]}" "$SCRIPT_IN_ROOT"
    fi
    chmod +x "$SCRIPT_IN_ROOT"

    mkdir -p "$BUILD_ROOT/.tmp" "$HOME/.gnupg" "$GPG_OUT_DIR"
    chmod 700 "$HOME/.gnupg"

    command -v guix >/dev/null || die "ไม่พบ guix — ต้องรันบน Guix System"

    export GOS_GPG_INSIDE=1
    export BUILD_NUMBER BUILD_ROOT GPG_OUT_DIR
    export GOS_DEVICES="${DEVICES[*]}"
    export SKIP_ENCRYPT

    info "เข้า FHS container..."
    exec guix shell -m "$MANIFEST" \
        --container --emulate-fhs --network \
        --preserve='^GOS_|^GPG_|^BUILD_|^SKIP_ENCRYPT$|^HOME$|^USER$|^TERM$|^LANG$' \
        --share="$BUILD_ROOT" \
        --share="$HOME/.gnupg" \
        --share="$GPG_OUT_DIR" \
        --share="$BUILD_ROOT/.tmp=/tmp" \
        -- bash "$SCRIPT_IN_ROOT" "${DEVICES[@]}" \
           --build-number "$BUILD_NUMBER" \
           --build-root "$BUILD_ROOT" \
           --out-dir "$GPG_OUT_DIR"
fi

# ─── Phase 2 — Inside FHS container ──────────────────────────────────
step "pack-gpg — รวม flashable + keys → tar | gpg"
command -v gpg  >/dev/null || die "ไม่พบ gpg ใน container — ตรวจ manifest"
command -v tar  >/dev/null || die "ไม่พบ tar"

# DEVICES อาจหายจาก argv (re-exec) — ใช้ env GOS_DEVICES สำรอง
if [[ ${#DEVICES[@]} -eq 0 ]]; then
    read -r -a DEVICES <<<"${GOS_DEVICES:-}"
fi
[[ ${#DEVICES[@]} -gt 0 ]] || die "ไม่มี device — ตรวจ args/GOS_DEVICES"

BUNDLE_BASENAME="grapheneos-${BUILD_NUMBER}-$(IFS=_; echo "${DEVICES[*]}")"
BUNDLE_TAR="$GPG_OUT_DIR/${BUNDLE_BASENAME}.tar"
GPG_BUNDLE="${BUNDLE_TAR}.gpg"
README_FILE="$GPG_OUT_DIR/${BUNDLE_BASENAME}.README.txt"

# ─── หา artifacts ของแต่ละ device ───
TAR_INCLUDES=()
for DEVICE in "${DEVICES[@]}"; do
    _rel="releases/$BUILD_NUMBER/release-${DEVICE}-${BUILD_NUMBER}"
    [[ -d "$BUILD_ROOT/$_rel" ]] || die "ไม่พบ $BUILD_ROOT/$_rel (build $BUILD_NUMBER สำหรับ $DEVICE ยังไม่มี?)"
    _found_any=0
    for _z in factory install ota_update img; do
        _f="${_rel}/${DEVICE}-${_z}-${BUILD_NUMBER}.zip"
        if [[ -f "$BUILD_ROOT/$_f" ]]; then
            TAR_INCLUDES+=("$_f"); _found_any=1
        else
            warn "ไม่พบ $_f — ข้าม"
        fi
    done
    [[ "$_found_any" == "1" ]] || die "[$DEVICE] ไม่พบ flashable zip ใดเลย"
    [[ -d "$BUILD_ROOT/keys/$DEVICE" ]] && TAR_INCLUDES+=("keys/$DEVICE") \
        || warn "ไม่พบ keys/$DEVICE — ข้าม"
done

# ─── tar ───
mkdir -p "$GPG_OUT_DIR"
log "สร้าง tar: $BUNDLE_TAR (${#TAR_INCLUDES[@]} entries)"
tar -C "$BUILD_ROOT" -cf "$BUNDLE_TAR" "${TAR_INCLUDES[@]}"
BUNDLE_TAR_SIZE=$(du -h "$BUNDLE_TAR" | awk '{print $1}')
info "tar size: $BUNDLE_TAR_SIZE"

# ─── --skip-encrypt → จบ ───
if [[ "${SKIP_ENCRYPT:-0}" == "1" ]]; then
    warn "--skip-encrypt: เก็บ tar plain ไว้ (ไม่ encrypt)"
    info "ไฟล์: $BUNDLE_TAR"
    info "SHA-256: $(sha256sum "$BUNDLE_TAR" | awk '{print $1}')"
    exit 0
fi

# ─── encrypt ───
GPG_MODE=""
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
        # ─── interactive: prompt + loopback (FHS container ไม่มี pinentry) ───
        if [[ ! -t 0 ]]; then
            die "ไม่ใช่ TTY และไม่ได้ตั้ง GPG_PASSPHRASE/GPG_RECIPIENT
     วิธี:  ssh -t ... bash pack-gpg-guix.sh ...           (interactive)
     หรือ:  GPG_PASSPHRASE='...' bash pack-gpg-guix.sh ...  (env)
     หรือ:  GPG_RECIPIENT='you@x.com' bash pack-gpg-guix.sh ...  (asymmetric)"
        fi
        warn "เก็บ passphrase ไว้ให้ดี — ถ้าลืมไฟล์นี้จะถอดไม่ได้"
        while :; do
            printf "ตั้ง GPG passphrase: " >&2
            read -rs _gpg_pw; echo >&2
            [[ -n "$_gpg_pw" ]] || { warn "ว่างไม่ได้"; continue; }
            printf "ยืนยัน passphrase อีกครั้ง: " >&2
            read -rs _gpg_pw2; echo >&2
            [[ "$_gpg_pw" == "$_gpg_pw2" ]] && break
            warn "ไม่ตรงกัน ลองใหม่"
        done
        log "encrypt → $GPG_BUNDLE  [$GPG_MODE]"
        gpg --batch --yes --pinentry-mode loopback \
            --passphrase-fd 0 \
            --symmetric --cipher-algo AES256 \
            --output "$GPG_BUNDLE" \
            "$BUNDLE_TAR" <<<"$_gpg_pw"
        unset _gpg_pw _gpg_pw2
    fi
fi

# ─── shred tar plain (เก็บเฉพาะ .gpg) ───
shred -u "$BUNDLE_TAR" 2>/dev/null || rm -f "$BUNDLE_TAR"

GPG_SIZE=$(du -h "$GPG_BUNDLE" | awk '{print $1}')
GPG_SHA=$(sha256sum "$GPG_BUNDLE" | awk '{print $1}')

# ─── README ───
cat > "$README_FILE" <<README
GrapheneOS Flashable Bundle (Built on Guix System via FHS container)
====================================================================
Build number : $BUILD_NUMBER
Devices      : ${DEVICES[*]}
Encrypt mode : $GPG_MODE
Bundle file  : $GPG_BUNDLE
Bundle size  : $GPG_SIZE
SHA-256      : $GPG_SHA
Created at   : $(date -Iseconds 2>/dev/null || date)

วิธีย้ายไปเครื่องอื่น (host ที่ต่อ Pixel ผ่าน USB)
--------------------------------------------------
1) คัดลอก 2 ไฟล์: $(basename "$GPG_BUNDLE") + $(basename "$README_FILE")
2) ตรวจ SHA-256:  sha256sum $(basename "$GPG_BUNDLE")   # ต้องตรงกับ $GPG_SHA
3) ถอดรหัส + extract:
$(if [[ -n "${GPG_RECIPIENT:-}" ]]; then cat <<R
   (asymmetric — เครื่องปลายทางต้องมี private key ของ $GPG_RECIPIENT)
     gpg --decrypt $(basename "$GPG_BUNDLE") | tar -xvf -
R
else cat <<R
   (symmetric — ใช้ passphrase ที่ตั้งตอน encrypt)
     gpg --decrypt $(basename "$GPG_BUNDLE") | tar -xvf -
R
fi)

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

# ─── สรุปผล ───
echo
echo "==================== GPG BUNDLE READY ===================="
echo "Bundle  : $GPG_BUNDLE"
echo "README  : $README_FILE"
echo "Mode    : $GPG_MODE"
echo "Size    : $GPG_SIZE"
echo "SHA-256 : $GPG_SHA"
echo "==========================================================="
