# สรุปความคืบหน้า - Build GrapheneOS on Guix System Script

**วันที่**: 2026-05-11  
**สถานะ**: 🔨 กำลังพัฒนาและทดสอบ (รอเครื่อง Guix VM กลับมา online)

---

## ✅ ความสำเร็จที่ทำไปแล้ว

### 1. สร้าง script `one-all-stop-build-grapheneos-on-guixsystem-150withgpg.sh`
- แปลงจาก `one-all-stop-build-grapheneos-on-ubuntu24lts-withgpg.sh` ครบทุก step
- รองรับ environment variables เหมือน Ubuntu version
- ใช้ Guix package manager แทน apt-get
- ไม่ต้องพึ่งพา sudo (Guix design)

### 2. แก้ปัญหาที่เจอระหว่างพัฒนา

#### Issue #1: Package `schedtool` ไม่มีใน Guix channel
- **ปัญหา**: `guix package: error: schedtool: unknown package`
- **วิธีแก้**: ลบ schedtool ออก (ไม่จำเป็น — ใช้สำหรับ priority scheduling เท่านั้น)
- **Commit**: `7187f2f` - Fix: ลบ schedtool ออก (ไม่มีใน Guix channel)

#### Issue #2: Guix profile script ใช้ตัวแปร unbound (NODE_PATH)
- **ปัญหา**: `/home/guix/grapheneos/.guix-profile/etc/profile: line 12: NODE_PATH: unbound variable`
- **วิธีแก้**: เพิ่ม `set +u` ก่อน source profile และ `set -u` หลังจากนั้น
- **Commit**: `55fdaf0` - Fix: เพิ่ม set +u รอบ source Guix profile

### 3. Guix packages ติดตั้งสำเร็จ (37 packages)

ทุก package มาจาก **Guix Official Channel เท่านั้น** (ไม่ใช้ NonGuix):

```
gcc-toolchain 15.2.0, make 4.4.1, binutils 2.44, bc 1.08.2, bison 3.8.2,
ccache 4.8.3, curl 8.6.0, flex 2.6.4, git 2.52.0, git-lfs 3.7.0,
gnupg 2.4.7, gperf 3.3, imagemagick 6.9.13-5, libelf 0.8.13,
lz4 1.10.0, openssl 3.0.8, libxml2 2.14.6, lzop 1.04, pngcrush 1.8.13,
rsync 3.4.1, squashfs-tools 4.6.1, libxslt 1.1.43, zip 3.0, unzip 6.0,
zlib 1.3.1, openjdk:jdk 25, python 3.11.14, python-wrapper 3.11.14,
util-linux 2.40.4, jq 1.8.1, node 22.14.0, coreutils 9.1,
findutils 4.10.0, grep 3.11, sed 4.9, gawk 5.3.0, which 2.21
```

### 4. Script ผ่าน STEP 0-2 สำเร็จ
- ✅ STEP 0: ตรวจ spec เครื่อง (16 cores, 31GB RAM, 403GB disk)
- ✅ STEP 1: ติดตั้ง dependencies (37 Guix packages)
- ✅ STEP 2: ติดตั้ง repo + git identity + allowed_signers
- 🔄 STEP 3: เริ่ม repo init/sync แล้ว → **เครื่อง VM down ระหว่างนี้**

---

## 🔴 ปัญหาปัจจุบัน

### Issue #3: เครื่อง Guix VM down ระหว่าง repo sync
- **เวลาที่เกิด**: 2026-05-11 20:11:04 (ระหว่าง `repo sync -j6`)
- **สาเหตุที่เป็นไปได้**:
  1. Timeout หรือ resource หมดระหว่าง download (~160GB)
  2. Network issue ระหว่าง sync จาก googlesource.com
  3. VM memory/disk issue
- **สถานะ**: รอเครื่อง VM กลับมา online
- **Log ที่ต้องตรวจสอบ**:
  - `/tmp/guix-test.log`
  - `/home/guix/gos-build-20260511-201104.log`

### Issue #4: npm ไม่สามารถติดตั้ง yarn globally ได้
- **ปัญหา**: `npm error enoent ENOENT: no such file or directory, mkdir '/gnu/store/.../node_modules/yarn'`
- **สาเหตุ**: Guix packages เก็บใน `/gnu/store` ซึ่งเป็น read-only (immutable by design)
- **ทางออก**: 
  - Script รองรับ fallback เป็น `npx yarn` แล้ว (ไม่น่ามีปัญหา)
  - หรือติดตั้ง yarn ผ่าน `guix package -i node-yarn` ถ้ามีใน channel
- **สถานะ**: ✅ ไม่เป็นปัญหา (script จัดการได้)

---

## 📝 Git Commits (branch `forguix`)

1. **33ab555** - เพิ่ม script build GrapheneOS บน Guix System (version 1.0 - initial)
2. **7187f2f** - Fix: ลบ schedtool ออก (ไม่มีใน Guix channel)  
3. **55fdaf0** - Fix: เพิ่ม set +u รอบ source Guix profile (แก้ปัญหา NODE_PATH unbound)

---

## 🎯 ขั้นตอนต่อไป (เมื่อเครื่อง Guix กลับมา)

### 1. ตรวจสอบสถานะ VM
```bash
ssh guix@10.211.55.27 'uptime'
ssh guix@10.211.55.27 'df -h'
ssh guix@10.211.55.27 'free -h'
```

### 2. ตรวจสอบ log
```bash
ssh guix@10.211.55.27 'tail -100 /tmp/guix-test.log'
ssh guix@10.211.55.27 'tail -100 /home/guix/gos-build-*.log'
```

### 3. ตรวจสอบว่า repo sync เสร็จหรือยัง
```bash
ssh guix@10.211.55.27 'ls -lh ~/grapheneos/.gos-synced-tag'
ssh guix@10.211.55.27 'du -sh ~/grapheneos'
```

### 4. ทดสอบต่อ
- ถ้า sync เสร็จแล้ว: ใช้ `SKIP_SYNC=1` แล้วทดสอบ STEP 4-8
- ถ้ายังไม่เสร็จ: รัน script ใหม่เพื่อทำ sync ต่อ (repo sync เป็น idempotent)

### 5. แก้ไข issue ที่เจอใน STEP 4-8
- STEP 4: patch source (ต้องมี `patch-grapheneos.sh`)
- STEP 5: adevtool + aapt2 (อาจเจอ issue กับ npm/yarn)
- STEP 6-8: build per device

### 6. ทดสอบ full build
```bash
ASSUME_YES=1 ~/one-all-stop-build-grapheneos-on-guixsystem-150withgpg.sh husky
```

---

## 📊 สรุปเปรียบเทียบ Ubuntu vs Guix

| ส่วน | Ubuntu Script | Guix Script | หมายเหตุ |
|------|--------------|-------------|----------|
| Package Manager | apt-get | guix package | Guix ใช้ profile แทน global install |
| Sudo | ต้องใช้ sudo | ไม่ต้อง sudo | Guix design: user-space packages |
| Node.js | ติดตั้งจาก NodeSource | ใช้ใน Guix (v22.14) | Guix มี Node.js version ใหม่แล้ว |
| Yarn | npm install -g | npx yarn | Guix /gnu/store เป็น read-only |
| AppArmor | ต้องปิด profile | ไม่มี | Guix ไม่ใช้ AppArmor |
| Packages | 100% available | 100% available | ยกเว้น schedtool (ไม่จำเป็น) |

---

**สถานะสุดท้าย**: 🔄 รอเครื่อง Guix VM กลับมา online เพื่อทดสอบต่อ STEP 3-8
