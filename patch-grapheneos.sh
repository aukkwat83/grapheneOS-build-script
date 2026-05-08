#!/usr/bin/env bash
# =====================================================================
# patch-grapheneos.sh
#
# Patch ต้นทาง GrapheneOS (tag 2026042100 / Android 16 QPR2) สำหรับ
# build แบบไม่เป็น official บน Ubuntu 24.04 โดย:
#
#   1) ปิด/ลบระบบ Updater (OTA) ทั้งหมด อัปเดตในเครื่องไม่ได้
#      ต้อง build ใหม่จาก source อย่างเดียวเพื่ออัปเกรดเวอร์ชัน
#   2) คงระบบ App Store ของ GrapheneOS (app.grapheneos.apps) ไว้ปกติ
#      เพื่อให้ติดตั้ง/อัปเดตแอพต่าง ๆ รวมถึง sandboxed Play Services
#      ได้ตามเดิม
#   3) สร้าง signing keys (releasekey, platform, shared, media,
#      networkstack, bluetooth, nfc, sdk_sandbox, gmscompat_lib) และ
#      AVB key ของตัวเอง ภายใต้ keys/<DEVICE>/  เพื่อใช้สำหรับ
#      sign_target_files_apks ตอน script/generate-release.sh
#   4) เตรียม avb_pkmd.bin สำหรับ `fastboot flash avb_custom_key`
#      เพื่อ Lock Bootloader ด้วยกุญแจของตัวเองได้ใน Pixel ที่รองรับ
#
# วิธีใช้:
#   chmod +x patch-grapheneos.sh
#   ./patch-grapheneos.sh <DEVICE> [<DEVICE2> ...]
#
#   ตัวอย่าง: ./patch-grapheneos.sh tokay
#             ./patch-grapheneos.sh shiba husky comet
#
# Codename ของ Pixel ที่ GrapheneOS รองรับ (ตรวจสอบใน
# script/common.sh):
#   tegu(9a) komodo(9PXL) caiman(9P) tokay(9) akita(8a) husky(8P)
#   shiba(8) felix(F) tangorpro(T) lynx(7a) cheetah(7P) panther(7)
#   bluejay(6a) raven(6P) oriole(6)
#   rango(10PXL) mustang(10P) blazer(10) frankel(10a)
#   stallion(8aR2)
# =====================================================================

set -o errexit -o nounset -o pipefail

# ----- ค่าตั้งต้น -----
GOS_ROOT="${GOS_ROOT:-$PWD}"
KEY_SUBJECT="${KEY_SUBJECT:-/CN=GrapheneOS-Custom}"
SIGNING_KEYS=(bluetooth gmscompat_lib media networkstack nfc platform releasekey sdk_sandbox shared)

# ----- ฟังก์ชันช่วยเหลือ -----
c_red=$'\e[1;31m'; c_grn=$'\e[1;32m'; c_ylw=$'\e[1;33m'; c_blu=$'\e[1;34m'; c_off=$'\e[0m'
log()  { printf '%s[+]%s %s\n' "$c_grn" "$c_off" "$*"; }
warn() { printf '%s[!]%s %s\n' "$c_ylw" "$c_off" "$*" >&2; }
info() { printf '%s[i]%s %s\n' "$c_blu" "$c_off" "$*"; }
die()  { printf '%s[x]%s %s\n' "$c_red" "$c_off" "$*" >&2; exit 1; }

backup_once() {
    local f="$1"
    [[ -f "$f.gosbak" ]] || cp -p "$f" "$f.gosbak"
}

# ----- ตรวจสอบ argument / environment -----
if [[ $# -lt 1 ]]; then
    cat <<'USAGE' >&2
ต้องระบุ codename อย่างน้อย 1 ตัว เช่น:
    ./patch-grapheneos.sh tokay
    ./patch-grapheneos.sh shiba husky comet
USAGE
    exit 2
fi

DEVICES=("$@")

[[ -d "$GOS_ROOT/.repo" ]]                       || die "ไม่พบ .repo ใน $GOS_ROOT (ต้องอยู่ใน GrapheneOS source root)"
[[ -d "$GOS_ROOT/build/make" ]]                  || die "ไม่พบ build/make"
[[ -f "$GOS_ROOT/development/tools/make_key" ]]  || die "ไม่พบ development/tools/make_key"
[[ -f "$GOS_ROOT/external/avb/avbtool.py" ]]     || die "ไม่พบ external/avb/avbtool.py"
command -v bash >/dev/null                       || die "ไม่พบ bash ใน PATH"
command -v openssl >/dev/null                    || die "ไม่พบ openssl ใน PATH"
command -v python3 >/dev/null                    || die "ไม่พบ python3 ใน PATH"

cd "$GOS_ROOT"

log "GrapheneOS source root: $GOS_ROOT"
log "Target devices        : ${DEVICES[*]}"

# =====================================================================
# 1) ปิด/ลบ Updater
# =====================================================================
log "STEP 1/4 - ปิด GrapheneOS Updater (OTA system)"

MEDIA_SYSTEM_MK="build/make/target/product/media_system.mk"
APK_YML="vendor/adevtool/config/device/common/apk.yml"

# 1a) ลบบล็อก ifeq($(OFFICIAL_BUILD),true)/PRODUCT_PACKAGES += Updater/endif
if [[ -f "$MEDIA_SYSTEM_MK" ]]; then
    backup_once "$MEDIA_SYSTEM_MK"
    python3 - <<'PYEOF'
import re, pathlib, sys
p = pathlib.Path("build/make/target/product/media_system.mk")
text = p.read_text()
pattern = re.compile(
    r'^ifeq\s*\(\$\(OFFICIAL_BUILD\),\s*true\)\s*\n'
    r'\s*PRODUCT_PACKAGES\s*\+=\s*Updater\s*\n'
    r'endif\s*\n',
    re.MULTILINE,
)
new = pattern.sub(
    "# Updater removed by patch-grapheneos.sh - "
    "no in-place OTA on self-built images\n",
    text,
)
if new == text:
    if "PRODUCT_PACKAGES += Updater" in text:
        sys.stderr.write("PATCH WARN: 'PRODUCT_PACKAGES += Updater' ยังอยู่แต่ไม่ตรงรูปแบบ if-block, "
                         "อาจต้องแก้มือ\n")
    else:
        sys.stderr.write("INFO: Updater ถูกถอดออกจาก media_system.mk แล้ว (idempotent)\n")
else:
    p.write_text(new)
    sys.stderr.write("INFO: ปิด Updater ใน media_system.mk สำเร็จ\n")
PYEOF
else
    warn "ไม่พบ $MEDIA_SYSTEM_MK - ข้าม"
fi

# 1b) ซ่อน Android.bp ของ Updater ไม่ให้ Soong มองเห็น (ป้องกัน build หลุด)
if [[ -f "packages/apps/Updater/Android.bp" ]]; then
    mv -f packages/apps/Updater/Android.bp packages/apps/Updater/Android.bp.disabled
    info "เปลี่ยนชื่อ packages/apps/Updater/Android.bp -> Android.bp.disabled"
elif [[ -f "packages/apps/Updater/Android.bp.disabled" ]]; then
    info "packages/apps/Updater/Android.bp ถูกปิดไว้แล้ว (idempotent)"
else
    warn "ไม่พบ packages/apps/Updater/Android.bp - ข้าม"
fi

# 1c) ตัดบรรทัด Updater.apk ออกจาก adevtool apk.yml (กันเช็ก consistency)
if [[ -f "$APK_YML" ]] && grep -q "system/priv-app/Updater/Updater.apk" "$APK_YML"; then
    backup_once "$APK_YML"
    sed -i '\#system/priv-app/Updater/Updater\.apk#d' "$APK_YML"
    info "ลบ Updater entry ออกจาก vendor/adevtool/config/device/common/apk.yml"
fi

# 1d) เพิ่มไฟล์ guard ใน packages/apps/Updater/ เพื่อบันทึกสถานะ
cat > packages/apps/Updater/.disabled <<'EOF'
ปิดโดย patch-grapheneos.sh
อย่ารวม Updater ใน build นี้
ต้อง build ใหม่จาก source เพื่ออัปเดต OS เท่านั้น
EOF

# =====================================================================
# 2) ตรวจสอบให้แน่ใจว่า GrapheneOS App Store ยังอยู่
# =====================================================================
log "STEP 2/4 - ตรวจสอบ GrapheneOS App Store"

if [[ -f "external/AppStore/Android.bp" ]] \
   && grep -q '^\s*AppStore\b' build/make/target/product/handheld_product.mk; then
    info "AppStore (app.grapheneos.apps) ยังอยู่ใน PRODUCT_PACKAGES ของ handheld_product.mk - OK"
    info "ผู้ใช้สามารถดาวน์โหลด/อัปเดต Sandboxed Play Services ผ่าน App Store ได้ตามปกติ"
else
    warn "ไม่พบ AppStore — โปรดตรวจสอบ external/AppStore/Android.bp และ handheld_product.mk ด้วยตัวเอง"
fi

# =====================================================================
# 3) สร้าง signing keys และ AVB keys ต่อ device
# =====================================================================
log "STEP 3/4 - สร้าง signing keys และ AVB key ใน keys/<DEVICE>/"

generate_apk_key() {
    local key_dir="$1" key_name="$2"
    if [[ -f "$key_dir/$key_name.pk8" && -f "$key_dir/$key_name.x509.pem" ]]; then
        info "    [skip] $key_name (มีอยู่แล้ว)"
        return 0
    fi
    rm -f "$key_dir/$key_name.pk8" "$key_dir/$key_name.x509.pem"
    info "    [gen ] $key_name"
    # ใช้ make_key ส่ง stdin "" สำหรับ password ว่าง (ภายหลังเข้ารหัสได้ด้วย script/encrypt-keys)
    # เรียกผ่าน bash โดยตรง เพื่อไม่พึ่ง /bin/bash shebang ของ make_key
    ( cd "$key_dir" && printf '\n' | bash "$GOS_ROOT/development/tools/make_key" "$key_name" "$KEY_SUBJECT" rsa ) \
        >/dev/null 2>&1 \
        || die "make_key ล้มเหลวสำหรับ $key_name"
}

generate_avb_key() {
    local key_dir="$1"
    if [[ -f "$key_dir/avb.pem" && -f "$key_dir/avb_pkmd.bin" ]]; then
        info "    [skip] avb.pem / avb_pkmd.bin (มีอยู่แล้ว)"
        return 0
    fi
    info "    [gen ] avb.pem (RSA-4096) + avb_pkmd.bin"
    openssl genrsa 4096 2>/dev/null \
      | openssl pkcs8 -topk8 -nocrypt -out "$key_dir/avb.pem"
    python3 "$GOS_ROOT/external/avb/avbtool.py" extract_public_key \
        --key "$key_dir/avb.pem" \
        --output "$key_dir/avb_pkmd.bin"
}

for DEVICE in "${DEVICES[@]}"; do
    KEY_DIR="keys/$DEVICE"
    mkdir -p "$KEY_DIR"
    log "  [$DEVICE] -> $KEY_DIR"
    for KEY in "${SIGNING_KEYS[@]}"; do
        generate_apk_key "$KEY_DIR" "$KEY"
    done
    generate_avb_key "$KEY_DIR"
    chmod 600 "$KEY_DIR"/*.pk8 "$KEY_DIR"/avb.pem 2>/dev/null || true
done

# =====================================================================
# 4) บันทึก/พิมพ์คำสั่งขั้นตอนถัดไปสำหรับผู้ใช้
# =====================================================================
log "STEP 4/4 - เขียนคำสั่งขั้นตอนถัดไป"

NEXT_STEPS_FILE="$GOS_ROOT/NEXT-STEPS.txt"
{
    echo "GrapheneOS custom-build next steps (สร้างเมื่อ: $(date -Iseconds))"
    echo "================================================================"
    echo
    echo "Devices ที่เตรียม keys ไว้: ${DEVICES[*]}"
    echo
    echo "[A] Build ระบบ"
    echo "    source build/envsetup.sh"
    for d in "${DEVICES[@]}"; do
        echo "    # สำหรับ $d:"
        echo "    lunch ${d}-cur-user        # หรือ ${d}-cur-userdebug ถ้าต้องการ debug"
        echo "    m vanilla"
        echo
    done
    echo "[B] Sign ด้วยกุญแจของตัวเอง (สร้าง factory + OTA zip)"
    for d in "${DEVICES[@]}"; do
        echo "    script/generate-release.sh $d <BUILD_NUMBER>"
        echo "    # ผลลัพธ์: releases/<BUILD_NUMBER>/release-${d}-<BUILD_NUMBER>/"
        echo
    done
    echo "[C] เข้ารหัส keys (ทางเลือก แต่แนะนำ)"
    for d in "${DEVICES[@]}"; do
        echo "    script/encrypt-keys keys/$d"
    done
    echo
    echo "[D] Flash + Lock Bootloader ด้วย AVB key ของตัวเอง"
    echo "    1) เปิด OEM unlocking ใน Developer options และปลดล็อก:"
    echo "         fastboot flashing unlock"
    echo "    2) Flash factory image:"
    echo "         cd releases/<BUILD>/release-<DEVICE>-<BUILD>/<DEVICE>-factory-<BUILD>/"
    echo "         ./flash-all.sh"
    echo "    3) (สำคัญ) flash AVB custom key ก่อน lock:"
    echo "         fastboot flash avb_custom_key $GOS_ROOT/keys/<DEVICE>/avb_pkmd.bin"
    echo "    4) Lock bootloader:"
    echo "         fastboot flashing lock"
    echo "    5) ยืนยันที่หน้าเครื่อง — VOLUME UP เพื่อ confirm"
    echo
    echo "หมายเหตุ:"
    echo " - ระบบจะไม่มี Updater อยู่ในตัวอีกต่อไป"
    echo " - การอัปเดต OS ต้อง build ใหม่ด้วย script/generate-release.sh"
    echo "   แล้วใช้ sideload หรือ flash factory image ใหม่"
    echo " - GrapheneOS App Store (app.grapheneos.apps) ยังใช้ได้ปกติ"
    echo "   ลง/อัปเดต Sandboxed Google Play / Vanadium / Auditor ฯลฯ ได้"
    echo " - หน้าจอ boot สีเหลืองเป็นเรื่องปกติเมื่อใช้ AVB custom key"
    echo "   (สีเขียว = stock key, สีเหลือง = custom key, สีส้ม = ปลดล็อก)"
} > "$NEXT_STEPS_FILE"

log "Patch สำเร็จ"
info "ขั้นตอนถัดไปบันทึกที่: $NEXT_STEPS_FILE"
echo
cat "$NEXT_STEPS_FILE"
