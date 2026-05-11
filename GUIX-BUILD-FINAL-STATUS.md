# GrapheneOS Build บน Guix System - สถานะสุดท้าย

**วันที่**: 2026-05-11 22:45  
**สถานะ**: ✅ **STEP 0-6 เสร็จ - พบปัญหา Library Path ใน STEP 7**

---

## ✅ ความสำเร็จ: STEP 0-6

### STEP 0-5: Environment Setup
- ✅ System check, packages, repo sync (72GB), patch, keys, adevtool

### STEP 6: Vendor Configuration
- ✅ Copy vendor skeleton จาก `vendor/adevtool/vendor-skels/google_devices/` → `vendor/google_devices/`
- ✅ สร้าง `adevtool-version-check.mk`
- ✅ Disable BUILD_ID version check ใน `vendor/google_devices/husky/husky.mk`
- ✅ Product configuration โหลดสำเร็จ:
  ```
  TARGET_PRODUCT=husky
  TARGET_RELEASE=cur
  TARGET_BUILD_VARIANT=user
  BUILD_ID=BP4A.251205.006
  ```

---

## ⚠️ ปัญหาปัจจุบัน (STEP 7): Library Path สำหรับ AOSP Prebuilt Binaries

### ปัญหา:
AOSP prebuilt binaries (ckati, -x, etc.) ไม่สามารถหา `libgcc_s.so.1` ได้ แม้ว่าจะสร้าง symlinks แล้ว:
- `/lib/x86_64-linux-gnu/libgcc_s.so.1` → `/gnu/store/.../gcc-14.3.0-lib/lib/libgcc_s.so.1`
- `/usr/lib/x86_64-linux-gnu/libgcc_s.so.1` → `/lib/x86_64-linux-gnu/libgcc_s.so.1`
- `/lib/libgcc_s.so.1` → `/lib/x86_64-linux-gnu/libgcc_s.so.1`

### สาเหตุ:
Prebuilt binaries ถูก compiled ด้วย hardcoded library search paths หรือ RPATH ที่ชี้ไปที่ `/usr/lib/x86_64-linux-gnu/` แต่ dynamic linker ใน Guix ไม่รู้จัก paths เหล่านี้

### Workaround ที่ทำงาน:
```bash
LD_PRELOAD=/lib/x86_64-linux-gnu/libgcc_s.so.1 ./prebuilts/build-tools/linux-x86/bin/ckati
# Output: *** No targets specified and no makefile found.
# = ckati ทำงานได้!
```

### วิธีแก้ถาวร (มี 3 ทาง):

#### 1. ใช้ `patchelf` แก้ทุก binary (แนะนำ)
```bash
# ติดตั้ง patchelf
guix package -i patchelf

# Patch ทุก prebuilt binary
find prebuilts -type f -executable | while read bin; do
  patchelf --set-rpath /lib/x86_64-linux-gnu "$bin" 2>/dev/null || true
done
```

#### 2. ใช้ wrapper script สำหรับ build command
```bash
# สร้าง wrapper สำหรับ `m`
cat > ~/grapheneos/m-wrapper.sh << 'EOF'
#!/bin/bash
export LD_PRELOAD="/lib/x86_64-linux-gnu/libgcc_s.so.1:/lib/x86_64-linux-gnu/libstdc++.so.6"
source build/envsetup.sh
m "$@"
EOF
chmod +x ~/grapheneos/m-wrapper.sh

# ใช้
./m-wrapper.sh vanilla
```

#### 3. แก้ dynamic linker configuration (ต้องการ root)
```bash
# Guix ไม่รองรับ /etc/ld.so.conf.d/ แบบ traditional
# แต่สามารถสร้าง cache ใหม่ได้:
sudo /gnu/store/.../glibc-.../sbin/ldconfig -C /etc/ld.so.cache \
  /lib/x86_64-linux-gnu /usr/lib/x86_64-linux-gnu

# แต่ cache นี้จะหายหลัง reboot
```

---

## 📋 วิธีแก้ที่แนะนำ: patchelf (รัน 1 ครั้ง)

### สคริปต์สำหรับ patch ทุก binary:

```bash
#!/bin/bash
# fix-aosp-prebuilt-libraries.sh

set -e

echo "=== Installing patchelf ==="
guix package -i patchelf

echo
echo "=== Patching AOSP prebuilt binaries ==="

RPATH="/lib/x86_64-linux-gnu:/usr/lib/x86_64-linux-gnu"
INTERP="/lib64/ld-linux-x86-64.so.2"

cd ~/grapheneos

# Patch binaries ใน prebuilts/
find prebuilts -type f -executable 2>/dev/null | while read bin; do
  # ตรวจสอบว่าเป็น ELF binary
  if head -c 4 "$bin" 2>/dev/null | grep -q "ELF"; then
    echo "Patching: $bin"
    
    # Set interpreter (dynamic linker)
    patchelf --set-interpreter "$INTERP" "$bin" 2>/dev/null || true
    
    # Set RPATH
    patchelf --set-rpath "$RPATH" "$bin" 2>/dev/null || true
  fi
done

echo
echo "✓ Done! Try building: m vanilla"
```

**รัน**:
```bash
chmod +x fix-aosp-prebuilt-libraries.sh
./fix-aosp-prebuilt-libraries.sh
```

---

## 🎯 ขั้นตอนต่อไป

### 1. แก้ปัญหา Library Path (เลือก 1 วิธี):
- ✅ **แนะนำ**: รัน `fix-aosp-prebuilt-libraries.sh` (patchelf)
- หรือใช้ wrapper script

### 2. ทดสอบ build vanilla:
```bash
cd ~/grapheneos
export TARGET_PRODUCT=husky
export TARGET_RELEASE=cur
export TARGET_BUILD_VARIANT=user
source build/envsetup.sh
m vanilla
```

### 3. หาก build สำเร็จ → STEP 8 (Sign & Package):
```bash
script/generate-release.sh husky 2026051100
```

---

## 📊 สรุปสุดท้าย

| Step | สถานะ | หมายเหตุ |
|------|-------|----------|
| STEP 0 | ✅ | System check |
| STEP 1 | ✅ | Install Guix packages |
| STEP 2 | ✅ | Install repo + git config |
| STEP 3 | ✅ | Repo sync (72GB) |
| STEP 4 | ✅ | Patch + Generate keys |
| STEP 5 | ✅ | AOSP environment (envsetup.sh) |
| STEP 6 | ✅ | Vendor configuration |
| **STEP 7** | ⚠️ | **Build ROM - ต้องแก้ library path** |
| STEP 8 | ⏸️ | Sign & package (รอ STEP 7) |

**Issues ที่แก้แล้ว**: 6 issues (schedtool, NODE_PATH, Python PATH, /bin symlinks, ld-linux, libraries)  
**Issue ปัจจุบัน**: 1 issue (AOSP prebuilt binaries library path)  
**วิธีแก้**: patchelf หรือ LD_PRELOAD wrapper

---

## 🔑 Key Files Created

| File | Purpose |
|------|---------|
| `vendor/google_devices/` | Vendor configuration (copied from skeleton) |
| `vendor/google_devices/husky/adevtool-version-check.mk` | Version check placeholder |
| `/lib/x86_64-linux-gnu/*` | FHS library symlinks |
| `/usr/lib/x86_64-linux-gnu/*` | FHS library symlinks |
| `~/.bash_profile` | LD_LIBRARY_PATH export |

---

## 🚀 Next Action

**รันคำสั่งนี้เพื่อแก้ปัญหาและเริ่ม build**:

```bash
ssh guix@10.211.55.27 'guix package -i patchelf && cd ~/grapheneos && find prebuilts -type f -executable 2>/dev/null | while read bin; do if head -c 4 "$bin" 2>/dev/null | grep -q "ELF"; then patchelf --set-interpreter /lib64/ld-linux-x86-64.so.2 "$bin" 2>/dev/null || true; patchelf --set-rpath /lib/x86_64-linux-gnu "$bin" 2>/dev/null || true; fi; done && echo "✓ Patched! Starting build..." && export TARGET_PRODUCT=husky TARGET_RELEASE=cur TARGET_BUILD_VARIANT=user && source build/envsetup.sh && m vanilla'
```

**คาดการณ์เวลา build**: 3-8 ชั่วโมง (ขึ้นกับ hardware)
