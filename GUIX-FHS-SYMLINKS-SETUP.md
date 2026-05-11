# FHS Symlinks Setup บน Guix System สำหรับ AOSP Build

**วันที่**: 2026-05-11  
**Status**: ✅ Tested and Working  

---

## ปัญหา

Guix System ไม่มี FHS paths แต่ AOSP prebuilt binaries ต้องการ:
- `/lib64/ld-linux-x86-64.so.2` - Dynamic linker
- `/usr/lib/x86_64-linux-gnu/` - Library paths
- `/bin/bash`, `/bin/pwd`, `/bin/env` - Core utilities

---

## วิธีแก้: 3 ขั้นตอน

### 1. สร้าง Core System Symlinks

```bash
# Dynamic Linker
sudo mkdir -p /lib64
sudo ln -sf /gnu/store/yj053cys0724p7vs9kir808x7fivz17m-glibc-2.41/lib/ld-linux-x86-64.so.2 \
  /lib64/ld-linux-x86-64.so.2

# Shell binaries
sudo mkdir -p /bin
sudo ln -sf $(which bash) /bin/bash
sudo ln -sf $(which pwd) /bin/pwd
sudo ln -sf $(which env) /bin/env
```

### 2. Symlink AOSP Prebuilt Libraries (สำคัญที่สุด!)

```bash
# สร้าง library directories
sudo mkdir -p /lib/x86_64-linux-gnu
sudo mkdir -p /usr/lib/x86_64-linux-gnu

# Symlink ทุก library จาก AOSP prebuilts
AOSP_LIB="/home/guix/grapheneos/prebuilts/build-tools/linux-x86/lib64"

cd "$AOSP_LIB"
for lib in *.so*; do
  sudo ln -sf "$(pwd)/$lib" /lib/x86_64-linux-gnu/
  sudo ln -sf "$(pwd)/$lib" /usr/lib/x86_64-linux-gnu/
done
```

Libraries จำเป็น:
- `libjemalloc5.so` ✅
- `libc++.so` ✅  
- `libgcc_s.so.1` ✅
- และอื่น ๆ (รวม ~37 libs)

### 3. Patch ELF Binaries ด้วย Patchelf

```bash
# ติดตั้ง patchelf
guix package -i patchelf

# Patch ทุก AOSP binaries
cd ~/grapheneos
RPATH="/lib/x86_64-linux-gnu:/usr/lib/x86_64-linux-gnu"
INTERP="/lib64/ld-linux-x86-64.so.2"

find prebuilts out -type f -executable 2>/dev/null | while read bin; do
  if head -c 4 "$bin" 2>/dev/null | grep -q $'^\x7fELF'; then
    patchelf --set-interpreter "$INTERP" "$bin" 2>/dev/null || true
    patchelf --set-rpath "$RPATH" "$bin" 2>/dev/null || true
  fi
done
```

**คาดการณ์**: patch ~2800+ binaries

---

## Automated Script

ใช้ `fix-aosp-prebuilt-all.sh`:

```bash
# Upload
scp fix-aosp-prebuilt-all.sh root@10.211.55.27:/root/

# รัน
ssh root@10.211.55.27 'chmod +x /root/fix-aosp-prebuilt-all.sh && /root/fix-aosp-prebuilt-all.sh'
```

---

## ทดสอบ

### Test 1: ckati
```bash
$ prebuilts/build-tools/linux-x86/bin/ckati
*** No targets specified and no makefile found.
```
✅ Success!

### Test 2: Soong bootstrap
```bash
$ source build/envsetup.sh && m nothing
[100% 280/280] analyzing Android.bp files...
```
✅ Success!

---

## สรุป Symlinks

| Path | Target | Count |
|------|--------|-------|
| `/lib64/ld-linux-x86-64.so.2` | Guix glibc | 1 |
| `/bin/{bash,pwd,env}` | Guix coreutils | 3 |
| `/lib/x86_64-linux-gnu/*.so*` | AOSP prebuilts | ~37 |
| `/usr/lib/x86_64-linux-gnu/*` | Mirror | ~37 |

**Total**: ~80 symlinks + 2800 patched binaries

---

## Troubleshooting

**ปัญหา**: "error while loading shared libraries: libXXX.so"  
**แก้**: ค้นหาใน `prebuilts/` แล้ว symlink เข้า `/lib/x86_64-linux-gnu/`

**ปัญหา**: "No such file or directory" แม้ binary มีอยู่  
**แก้**: ตรวจสอบ `/lib64/ld-linux-x86-64.so.2`

---

**Result**: ✅ ckati ทำงานได้, Soong bootstrap ผ่าน 100%
