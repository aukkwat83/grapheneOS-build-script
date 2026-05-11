# Guix System - FHS Symlinks Setup สำหรับ AOSP Build

**วันที่**: 2026-05-11  
**สถานะ**: ✅ ตั้งค่าเสร็จสมบูรณ์

---

## ปัญหา: AOSP ต้องการ FHS (Filesystem Hierarchy Standard)

AOSP build system (Soong, Make, envsetup.sh) hardcode paths ตาม FHS standard:
- `/bin/bash`, `/bin/pwd`, `/bin/env`
- `/lib64/ld-linux-x86-64.so.2` (dynamic linker)
- `/lib/x86_64-linux-gnu/libgcc_s.so.1` และ libraries อื่น ๆ

**Guix System ไม่ใช้ FHS** → ทุกอย่างอยู่ใน `/gnu/store/...` และ `/run/current-system/...`

---

## ✅ การแก้ไข (Root Access Required)

### 1. สร้าง `/bin` Symlinks

```bash
sudo mkdir -p /bin

# pwd, env, bash
sudo ln -sf /run/current-system/profile/bin/pwd /bin/pwd
sudo ln -sf /run/current-system/profile/bin/env /bin/env
sudo ln -sf /run/current-system/profile/bin/bash /bin/bash

# ตรวจสอบ
ls -la /bin/
```

**ผลลัพธ์**:
```
lrwxrwxrwx 1 root root 35 /bin/env -> /run/current-system/profile/bin/env
lrwxrwxrwx 1 root root 35 /bin/pwd -> /run/current-system/profile/bin/pwd
lrwxrwxrwx 1 root root 36 /bin/bash -> /run/current-system/profile/bin/bash
```

### 2. สร้าง `/lib64` Dynamic Linker Symlink

```bash
sudo mkdir -p /lib64

# หา glibc ld-linux ใน /gnu/store
LINKER=$(find /gnu/store -name "ld-linux-x86-64.so.2" -type f 2>/dev/null | grep glibc | head -1)
echo "Found linker: $LINKER"

# สร้าง symlink
sudo ln -sf "$LINKER" /lib64/ld-linux-x86-64.so.2

# ตรวจสอบ
ls -la /lib64/ld-linux-x86-64.so.2
/lib64/ld-linux-x86-64.so.2 --version
```

**ผลลัพธ์**:
```
lrwxrwxrwx 1 root root 79 /lib64/ld-linux-x86-64.so.2 -> /gnu/store/.../glibc-2.41/lib/ld-linux-x86-64.so.2
ld.so (GNU libc) stable release version 2.41
```

### 3. สร้าง `/lib/x86_64-linux-gnu` Libraries Symlinks

```bash
sudo mkdir -p /lib/x86_64-linux-gnu

# หา glibc และ gcc-lib stores
GLIBC_STORE=$(find /gnu/store -maxdepth 1 -name "*glibc-2*" -type d | head -1)
GCC_STORE=$(find /gnu/store -maxdepth 1 -name "*gcc-*-lib" -type d | head -1)

echo "glibc: $GLIBC_STORE"
echo "gcc-lib: $GCC_STORE"

# Link ทุก libraries
sudo ln -sf $GLIBC_STORE/lib/* /lib/x86_64-linux-gnu/
sudo ln -sf $GCC_STORE/lib/* /lib/x86_64-linux-gnu/

# Link /lib64 → /lib/x86_64-linux-gnu (สำหรับ legacy)
sudo ln -sf /lib/x86_64-linux-gnu /lib64/

# ตรวจสอบ libraries สำคัญ
ls -la /lib/x86_64-linux-gnu/libgcc_s.so.1
ls -la /lib/x86_64-linux-gnu/libc.so.6
ls -la /lib/x86_64-linux-gnu/libstdc++.so.6
```

**ผลลัพธ์**:
```
lrwxrwxrwx 1 root root 76 /lib/x86_64-linux-gnu/libgcc_s.so.1 -> /gnu/store/.../gcc-14.3.0-lib/lib/libgcc_s.so.1
lrwxrwxrwx 1 root root 68 /lib/x86_64-linux-gnu/libc.so.6 -> /gnu/store/.../glibc-2.41/lib/libc.so.6
...
```

---

## 🔧 Script One-Liner (รัน 1 ครั้งพอ)

```bash
#!/bin/bash
# run-as-root.sh - สร้าง FHS symlinks ทั้งหมด

echo "=== Creating FHS symlinks for AOSP build ==="

# 1. /bin
mkdir -p /bin
ln -sf /run/current-system/profile/bin/pwd /bin/pwd
ln -sf /run/current-system/profile/bin/env /bin/env
ln -sf /run/current-system/profile/bin/bash /bin/bash

# 2. /lib64 dynamic linker
mkdir -p /lib64
LINKER=$(find /gnu/store -name "ld-linux-x86-64.so.2" -type f 2>/dev/null | grep glibc | head -1)
ln -sf "$LINKER" /lib64/ld-linux-x86-64.so.2

# 3. /lib/x86_64-linux-gnu libraries
mkdir -p /lib/x86_64-linux-gnu
GLIBC_STORE=$(find /gnu/store -maxdepth 1 -name "*glibc-2*" -type d | head -1)
GCC_STORE=$(find /gnu/store -maxdepth 1 -name "*gcc-*-lib" -type d | head -1)
ln -sf $GLIBC_STORE/lib/* /lib/x86_64-linux-gnu/ 2>/dev/null
ln -sf $GCC_STORE/lib/* /lib/x86_64-linux-gnu/ 2>/dev/null

# Verify
echo
echo "✓ Symlinks created:"
ls -la /bin/{pwd,env,bash}
ls -la /lib64/ld-linux-x86-64.so.2
ls -la /lib/x86_64-linux-gnu/libgcc_s.so.1
echo
echo "✅ AOSP build should work now!"
```

รันด้วย:
```bash
sudo bash run-as-root.sh
```

---

## 📋 ตรวจสอบว่าตั้งค่าเรียบร้อย

```bash
# 1. Test /bin utilities
/bin/bash --version
/bin/pwd
/bin/env | head

# 2. Test dynamic linker
/lib64/ld-linux-x86-64.so.2 --version

# 3. Test AOSP prebuilt binary
cd ~/grapheneos
export LD_LIBRARY_PATH=/lib/x86_64-linux-gnu:$LD_LIBRARY_PATH
prebuilts/build-tools/linux-x86/bin/ckati 2>&1 | head -3
# ถ้าไม่มี error "cannot open shared object file" = สำเร็จ!

# 4. Test envsetup.sh
source build/envsetup.sh
echo "✓ envsetup.sh loaded"
```

---

## ⚠️ หมายเหตุสำคัญ

### 1. **Symlinks เหล่านี้จะหายหลัง Guix system reconfigure**

Guix System rebuild จะลบ `/bin`, `/lib`, `/lib64` ต้องรัน script ใหม่หลัง `guix system reconfigure`

### 2. **ไม่ conflict กับ Guix packages**

Symlinks เหล่านี้ไม่กระทบ Guix package manager เพราะ:
- Guix packages ไม่ใช้ `/bin` หรือ `/lib`
- Guix profile ใช้ `/gnu/store/...` paths
- User environment ใช้ `~/.guix-profile/bin`

### 3. **LD_LIBRARY_PATH ต้องตั้งในแต่ละ session**

เพิ่มใน `~/.bash_profile` (สำหรับ AOSP build):
```bash
export LD_LIBRARY_PATH=/lib/x86_64-linux-gnu:$LD_LIBRARY_PATH
```

หรือใน build script:
```bash
export LD_LIBRARY_PATH=/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH:-}
```

---

## 🚀 สรุป

**สำหรับ GrapheneOS Build บน Guix System ต้องตั้งค่า**:

| Symlink | ที่อยู่ | เหตุผล |
|---------|---------|--------|
| `/bin/pwd` | `/run/current-system/profile/bin/pwd` | envsetup.sh ใช้ |
| `/bin/env` | `/run/current-system/profile/bin/env` | scripts ใช้ |
| `/bin/bash` | `/run/current-system/profile/bin/bash` | shebang `#!/bin/bash` |
| `/lib64/ld-linux-x86-64.so.2` | `/gnu/store/.../glibc-.../lib/ld-...` | dynamic linker สำหรับ ELF binaries |
| `/lib/x86_64-linux-gnu/*` | `/gnu/store/.../glibc & gcc-lib/lib/*` | prebuilt binaries ต้องการ |
| `LD_LIBRARY_PATH` | `/lib/x86_64-linux-gnu:...` | runtime library search path |

**ทั้งหมดต้องใช้ root access และรันครั้งเดียว** → AOSP build ใช้งานได้ปกติ! ✅
