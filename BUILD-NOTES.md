# สรุปการ Build GrapheneOS บน Ubuntu 24.04 LTS Clean Image

เอกสารนี้สรุปปัญหาที่เจอและวิธีแก้เมื่อ build GrapheneOS tag `2026042100` (Android 16 QPR2) แบบ unofficial บน Ubuntu 24.04.4 LTS เครื่องเปล่าใหม่ (clean image) สำหรับ Pixel 8 Pro (codename `husky`) โดย sign ด้วย custom AVB key เพื่อ lock bootloader ของตัวเอง

วันที่ทดสอบ: 2026-05-09  
เป้าหมาย: ทำให้ user ทั่วไปที่ไม่มีความรู้ Linux รัน script เดียวแล้วได้ flashable images

---

## สารบัญ

- [สเปคเครื่องและเป้าหมาย](#สเปคเครื่องและเป้าหมาย)
- [ภาพรวมของ Pipeline (8 Step)](#ภาพรวมของ-pipeline-8-step)
- [ปัญหาที่พบและการแก้ไข](#ปัญหาที่พบและการแก้ไข)
  - [1. make_key มี trap exit 1 เสมอ](#1-make_key-มี-trap-exit-1-เสมอ)
  - [2. ลายเซ็น tmux จับ exit code ผิด](#2-ลายเซ็น-tmux-จับ-exit-code-ผิด)
  - [3. Node 18 ของ Ubuntu noble เก่าเกินไปสำหรับ adevtool](#3-node-18-ของ-ubuntu-noble-เก่าเกินไปสำหรับ-adevtool)
  - [4. yarnpkg ถูกลบเมื่อ replace nodejs](#4-yarnpkg-ถูกลบเมื่อ-replace-nodejs)
  - [5. set -u ทะเลาะกับ build/envsetup.sh](#5-set--u-ทะเลาะกับ-buildenvsetupsh)
  - [6. adevtool เปลี่ยน API จาก yarn-script เป็น oclif](#6-adevtool-เปลี่ยน-api-จาก-yarn-script-เป็น-oclif)
  - [7. -b ของ adevtool หมายถึง stock build ID ไม่ใช่ GrapheneOS tag](#7--b-ของ-adevtool-หมายถึง-stock-build-id-ไม่ใช่-grapheneos-tag)
  - [8. AppArmor ของ Ubuntu 24.04 บล็อก nsjail sandbox](#8-apparmor-ของ-ubuntu-2404-บล็อก-nsjail-sandbox)
  - [9. ccache เห็น filesystem เป็น Read-only ใน sandbox](#9-ccache-เห็น-filesystem-เป็น-read-only-ใน-sandbox)
  - [10. Target m vanilla ถูกเลิก](#10-target-m-vanilla-ถูกเลิก)
  - [11. -j16 + R8/proguard กิน RAM = OOM kill](#11--j16--r8proguard-กิน-ram--oom-kill)
  - [12. ชื่อ target_files.zip เปลี่ยนรูปแบบ](#12-ชื่อ-target_fileszip-เปลี่ยนรูปแบบ)
  - [13. Target otatools เปลี่ยนเป็น otatools-package](#13-target-otatools-เปลี่ยนเป็น-otatools-package)
  - [14. otatools.zip ย้ายตำแหน่ง](#14-otatoolszip-ย้ายตำแหน่ง)
  - [15. script/decrypt-keys รอ password prompt](#15-scriptdecrypt-keys-รอ-password-prompt)
- [สูตรคำนวณทรัพยากร](#สูตรคำนวณทรัพยากร)
- [ผลลัพธ์สุดท้าย](#ผลลัพธ์สุดท้าย)
- [วิธีใช้ script ปัจจุบัน](#วิธีใช้-script-ปัจจุบัน)

---

## สเปคเครื่องและเป้าหมาย

| รายการ | ค่า |
|---|---|
| OS | Ubuntu 24.04.4 LTS (noble) |
| Kernel | Linux 6.8.0-111-generic |
| CPU | 16 cores (x86_64) |
| RAM | 31 GB |
| Swap (เริ่มต้น) | 4 GB |
| Disk root | 293 GB total, ~273 GB ว่าง (เริ่มต้น) |
| Build target | husky (Pixel 8 Pro) |
| GrapheneOS tag | 2026042100 |

ขั้นตอนเตรียมเครื่อง (ก่อนรัน script):
- ssh key auth (`ssh-copy-id`)
- `/etc/sudoers.d/90-aukkwat-nopasswd` ให้ user มี passwordless sudo
- ติดตั้ง tmux

---

## ภาพรวมของ Pipeline (8 Step)

```
STEP 0  ตรวจ spec + คำนวณ JOBS, disk, RAM
STEP 1  apt-get install dependencies + ติดตั้ง Node 24 จาก NodeSource + ติดตั้ง yarn ผ่าน npm
STEP 2  ติดตั้ง repo, ตั้ง git identity, ดาวน์โหลด allowed_signers ของ GrapheneOS
STEP 3  repo init -b refs/tags/<TAG> --depth=1, verify-tag, repo sync
STEP 4  รัน patch-grapheneos.sh: ปิด Updater + สร้าง signing keys (9 ชุด) + AVB key
STEP 5  yarn install (adevtool) + m aapt2 (ผ่าน lunch sdk_phone64_x86_64)
STEP 6  adevtool generate-all -d <DEVICE> (auto-download stock factory + extract vendor blobs)
STEP 7  lunch <DEVICE>-cur-user + m target-files-package otatools-package (1-3 ชั่วโมง)
STEP 8  cp target_files.zip + otatools.zip + รัน script/generate-release.sh → ได้ flashable zips
```

---

## ปัญหาที่พบและการแก้ไข

### 1. make_key มี trap exit 1 เสมอ

**Symptom:** STEP 4 (patch-grapheneos.sh) แจ้ง `make_key ล้มเหลวสำหรับ bluetooth` ทั้ง ๆ ที่ไฟล์ key ถูกสร้างขึ้นจริง

**Root cause:** ใน `development/tools/make_key` มีบรรทัด:
```bash
trap 'rm -rf ${tmpdir}; echo; exit 1' EXIT INT QUIT
```
ทำให้ **ออกด้วย exit code 1 เสมอ** ไม่ว่าจะสำเร็จหรือล้มเหลว

**Fix:** แก้ `patch-grapheneos.sh:generate_apk_key()` ให้เช็ค file existence แทน exit code:
```bash
( cd "$key_dir" && printf '\n' | bash "$GOS_ROOT/development/tools/make_key" "$key_name" "$KEY_SUBJECT" rsa ) \
    >/dev/null 2>&1 || true
[[ -f "$key_dir/$key_name.pk8" && -f "$key_dir/$key_name.x509.pem" ]] \
    || die "make_key ล้มเหลวสำหรับ $key_name (ไม่พบ output ที่คาดหวัง)"
```

---

### 2. ลายเซ็น tmux จับ exit code ผิด

**Symptom:** Log บันทึก `EXIT=0` ทั้ง ๆ ที่ script `die` ออกด้วย exit 1

**Root cause:** ใน command `tmux new-session -d -s gos "bash -lc \"...; echo EXIT=\$? >> log\""` เครื่องหมาย `\$?` ที่ตั้งใจจะให้ inner bash expand ดันถูก outer bash expand ก่อน → กลายเป็น `$?` ของ outer bash (ซึ่งคือ exit code ของ command ก่อนหน้า = 0) ก่อนที่ tmux จะได้รับ

**Fix:** สองส่วน:
1. แทน inline `echo EXIT=$?` ด้วย runner script:
   ```bash
   cat > /tmp/runner.sh <<"EOF"
   #!/bin/bash
   cd ~/build-script
   ./one-all-stop-build-grapheneos-on-ubuntu24lts.sh husky
   EOF
   tmux new-session -d -s gos /tmp/runner.sh
   ```
2. เพิ่ม EXIT trap ใน script เองให้ log สถานะปลายทาง:
   ```bash
   trap '_rc=$?; printf "\n[exit] rc=%d started=%s ended=%s\n" "$_rc" "$_started_at" "$(date -Iseconds)"; exit $_rc' EXIT
   ```

---

### 3. Node 18 ของ Ubuntu noble เก่าเกินไปสำหรับ adevtool

**Symptom:** `yarn install` ของ adevtool ล้มเหลวด้วย:
```
error @inquirer/prompts@8.3.0: The engine "node" is incompatible with this module.
Expected version ">=23.5.0 || ^22.13.0 || ^21.7.0 || ^20.12.0". Got "18.19.1"
```
เมื่อใช้งานจริงพบว่า `vendor/adevtool/bin/run` บังคับ:
```javascript
const MIN_NODE_MAJOR_VERSION = 24
```

**Root cause:** Ubuntu 24.04 noble ส่ง `nodejs` package version 18.19 แต่ adevtool ปัจจุบันต้องการ Node 24+

**Fix:** ติดตั้ง Node 24 จาก NodeSource (ไม่ใช้ apt):
```bash
NODE_MAJOR_REQ=24
NODE_VER=$(node --version 2>/dev/null | sed 's/^v//' | cut -d. -f1)
if [[ -z "$NODE_VER" || "$NODE_VER" -lt "$NODE_MAJOR_REQ" ]]; then
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR_REQ}.x" | sudo -E bash -
    sudo apt-get install -y nodejs
fi
```

---

### 4. yarnpkg ถูกลบเมื่อ replace nodejs

**Symptom:** หลังติดตั้ง Node 24 พบ:
```
./one-all-stop-build...sh: line 274: yarnpkg: command not found
```

**Root cause:** Debian package `yarnpkg` depend บน `libnode109` ที่มาคู่กับ `nodejs 18` เมื่อ NodeSource เข้าทับ nodejs ใหม่ apt จึงถอด libnode109 + yarnpkg อัตโนมัติ

**Fix:**
1. **ไม่ใส่** `yarnpkg` ใน `apt-get install` (เลี่ยงการติดตั้งซ้อนแล้วถูกถอด)
2. ติดตั้ง yarn ผ่าน npm หลัง Node ใหม่พร้อม:
   ```bash
   if ! command -v yarn >/dev/null; then
       sudo npm install -g yarn
   fi
   ```
3. แทนที่ทุก `yarnpkg` ในสคริปต์เป็น `yarn`

---

### 5. set -u ทะเลาะกับ build/envsetup.sh

**Symptom:**
```
/home/aukkwat/grapheneos/build/envsetup.sh: line 26: TOP: unbound variable
[exit] rc=1
```

**Root cause:** `set -o nounset` (set -u) ของ script ทำให้การเรียก `${TOP}` ที่ยังไม่ได้ตั้งใน envsetup.sh ของ AOSP โยน error

**Fix:** ห่อทุกบล็อกที่เรียก `source build/envsetup.sh` + `lunch` + `m` ใน subshell พร้อม `set +u`:
```bash
(
    set +u
    cd "$BUILD_ROOT"
    source build/envsetup.sh
    lunch "${DEVICE}-cur-user"
    m -j"$JOBS" target-files-package otatools-package
)
```
ใช้ subshell เพื่อ isolate ทั้ง `set +u` และ env variables ที่ envsetup.sh ตั้งให้ (TOP, ANDROID_BUILD_TOP, ฯลฯ)

---

### 6. adevtool เปลี่ยน API จาก yarn-script เป็น oclif

**Symptom:** STEP 6 รัน:
```
yarn admin:download -d husky -b 2026042100 ~/adevtool-downloads
→ error Command "admin:download" not found.
```

**Root cause:** README ของ GrapheneOS เก่ายังระบุคำสั่ง `yarn admin:download` แต่ adevtool ปัจจุบันถูก rewrite ด้วย **oclif framework** — คำสั่งอยู่ใน `lib/commands/*.js` เรียกผ่าน `bin/run`

**Fix:** เปลี่ยนรูปแบบเรียก:
```bash
# เก่า (ไม่ทำงานแล้ว)
yarn --cwd vendor/adevtool admin:download -d husky -b 2026042100 ~/adevtool-downloads
yarn --cwd vendor/adevtool generate-all -d husky -s ~/adevtool-downloads

# ใหม่ (ใช้ bin/run)
ADEVTOOL_IMG_DOWNLOAD_DIR=~/adevtool-downloads \
    node vendor/adevtool/bin/run generate-all -d husky
```

นอกจากนั้นคำสั่ง `admin:download` ถูกรวมเข้าไปใน `generate-all` แล้ว — `generate-all` จะ auto-download stock factory+OTA images ให้เองถ้าไม่มีในเครื่อง

---

### 7. -b ของ adevtool หมายถึง stock build ID ไม่ใช่ GrapheneOS tag

**Symptom:** เมื่อใส่ `-b 2026042100`:
```
Error: no images for 'husky 2026042100'
```

**Root cause:**
- `2026042100` = **GrapheneOS source tag** (date-based ของ GrapheneOS)
- `-b` ของ adevtool คาดหวัง **Google Pixel firmware build ID** เช่น `BP4A.260205.001`

ดูได้จาก `node vendor/adevtool/bin/run show-status`:
```
[no tag] | BP4A.260205.001: rango mustang blazer frankel tegu akita husky shiba felix tangorpro lynx
```

**Fix:** **อย่าใส่** `-b` เลย — ให้ adevtool ใช้ default จาก device config (`vendor/adevtool/config/device/<DEVICE>.yml`) ที่มีบรรทัด `build_id: BP4A.260205.001` กำหนดไว้:
```bash
node vendor/adevtool/bin/run generate-all -d "$DEVICE"
```

---

### 8. AppArmor ของ Ubuntu 24.04 บล็อก nsjail sandbox

**Symptom:** STEP 7 (m target-files-package) ล้มเหลวด้วย:
```
ccache: error: failed to create temporary file for
/home/aukkwat/.cache/ccache/tmp/cpp_stdout.tmp.XXX.ii: Read-only file system
```

ตรวจ `dmesg`:
```
apparmor="DENIED" operation="mount" profile="unprivileged_userns" 
    name="/" pid=93411 comm="nsjail" flags="rw, rprivate"
apparmor="DENIED" operation="capable" profile="unprivileged_userns" 
    capability=6 capname="setgid"
```

**Root cause:** Ubuntu 24.04 เป็น default มี **2 ชั้นที่บล็อก unprivileged user namespace**:
1. `kernel.apparmor_restrict_unprivileged_userns=1` — ห้ามสร้าง userns เลย
2. AppArmor profile `/etc/apparmor.d/unprivileged_userns` — เมื่อสร้าง userns ได้แล้ว profile นี้จะ apply auto และ deny mount/setgid/setuid

ผลคือ Soong's nsjail (เครื่องมือ sandbox สำหรับ build) ไม่สามารถ setup mount namespace ได้ → filesystem เห็น stale view → ccache เห็น `~/.cache/ccache` เป็น Read-only

**Fix:** ปิดทั้งสองชั้น:
```bash
# ชั้นที่ 1: sysctl
sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0
echo 'kernel.apparmor_restrict_unprivileged_userns=0' | \
    sudo tee /etc/sysctl.d/99-gos-build-userns.conf

# ชั้นที่ 2: AppArmor profile (unload ทั้งจาก runtime และ persist ผ่าน symlink)
sudo apparmor_parser -R /etc/apparmor.d/unprivileged_userns
sudo mkdir -p /etc/apparmor.d/disable
sudo ln -sf /etc/apparmor.d/unprivileged_userns \
    /etc/apparmor.d/disable/unprivileged_userns
```

---

### 9. ccache เห็น filesystem เป็น Read-only ใน sandbox

**Symptom:** ถึงแม้แก้ AppArmor แล้ว แต่ ccache ยังคง fail Read-only ใน sandbox

**Root cause:** Soong's nsjail bind-mount **เฉพาะ source tree + out/** เป็น read-write — ไม่ได้ mount `$HOME/.cache/` เข้าไปใน sandbox จึง access ไม่ได้

**Fix:** ย้าย `CCACHE_DIR` เข้าไปใน source tree:
```bash
# ก่อน
CCACHE_DIR_VAR="${CCACHE_DIR:-$HOME/.cache/ccache}"

# หลัง
CCACHE_DIR_VAR="${CCACHE_DIR:-$BUILD_ROOT/.ccache}"
```

ผลคือ ccache อยู่ใน `$BUILD_ROOT/.ccache` ซึ่งอยู่ในบริเวณที่ nsjail mount RW

---

### 10. Target m vanilla ถูกเลิก

**Symptom:**
```
FAILED: ninja: unknown target 'vanilla'
```

**Root cause:** GrapheneOS เก่าเคยมี target `vanilla` (build flavor) แต่ปัจจุบันถูกเลิก — `lunch husky-cur-user` กำหนด flavor เองได้

**Fix:** เปลี่ยนเป็น:
```bash
# เก่า
m -j$JOBS vanilla
m -j$JOBS target-files-package otatools

# ใหม่
m -j$JOBS target-files-package otatools-package
```
(หมายเหตุ: ดู #13 สำหรับ `otatools-package`)

---

### 11. -j16 + R8/proguard กิน RAM = OOM kill

**Symptom:** ที่ ~78% ของ build (ก่อนถึง dex/proguard phase) ninja ถูก kill:
```
ForkJoinPool-1- invoked oom-killer
Out of memory: Killed process 256422 (ninja) total-vm:8611672kB
FAILED: out/.../PackageInstaller.jar (และอีกหลายไฟล์)
error: action cancelled when ninja exited
```

**Root cause:** สูตรเก่า `JOBS = (RAM+SWAP)/2 = 17` ปัด -j16. แต่ละ R8 invocation ใช้ `-JXmx4096M` (JVM heap 4GB) ดังนั้นรัน 16 jobs พร้อมกันต้อง **64 GB RAM** เกิน 31 GB ของเครื่อง

**Fix:** สูตรใหม่ + เพิ่ม swap:
```bash
# จองอย่างน้อย 4GB ให้ OS + 4GB ต่อ build job (R8 heap)
J_BY_RAM=$(( (MEM_GB - 4) / 4 ))
JOBS=$(( J_BY_RAM < CPU_CORES ? J_BY_RAM : CPU_CORES ))
# 31GB → (31-4)/4 = 6 jobs
```
และเพิ่ม swap 16GB เป็น buffer:
```bash
sudo fallocate -l 16G /swapfile-gos16
sudo chmod 600 /swapfile-gos16
sudo mkswap /swapfile-gos16
sudo swapon /swapfile-gos16
```

ผลคือ build เสร็จใน 1h 18m (จากที่เคย OOM ตอน 3h 06m)

---

### 12. ชื่อ target_files.zip เปลี่ยนรูปแบบ

**Symptom:** STEP 8 cp ไฟล์ไม่เจอ:
```
cp: cannot stat
'.../target_files_intermediates/*-target_files-*.zip': No such file or directory
```

**Root cause:** AOSP เก่าใช้ pattern `<DEVICE>-target_files-<DATE>.zip` แต่ tag 2026042100 ใช้แค่ `<DEVICE>-target_files.zip` (ไม่มี date stamp)

**Fix:** ใช้ glob ที่ยืดหยุ่น + verify file exists:
```bash
TF_SRC=$(ls "$BUILD_ROOT/out/target/product/$DEVICE/obj/PACKAGING/target_files_intermediates/"*target_files*.zip 2>/dev/null | head -1)
[[ -f "$TF_SRC" ]] || die "ไม่พบ target_files.zip"
cp "$TF_SRC" "$REL_DIR/${DEVICE}-target_files.zip"
```

---

### 13. Target otatools เปลี่ยนเป็น otatools-package

**Symptom:** `m otatools` รันสำเร็จแต่ไม่สร้าง `otatools.zip`

**Root cause:** AOSP rename target เป็น `otatools-package` (เพิ่ม suffix) เพื่อเลี่ยงสับสนกับ source dir

**Fix:** เปลี่ยน target ที่เรียก:
```bash
# เก่า
m -j$JOBS target-files-package otatools

# ใหม่
m -j$JOBS target-files-package otatools-package
```

---

### 14. otatools.zip ย้ายตำแหน่ง

**Symptom:** STEP 8 cp ไม่เจอ otatools.zip ที่ path เดิม:
```
cp: cannot stat 'out/host/linux-x86/otatools.zip': No such file or directory
```

**Root cause:** AOSP ใหม่ produce `otatools.zip` ใน Soong intermediates ไม่ใช่ host bin dir แล้ว

**Fix:** ใช้ `find` หา zip ในที่ใหม่:
```bash
OTATOOLS_SRC=$(find "$BUILD_ROOT/out" -name "otatools.zip" -size +10M 2>/dev/null | head -1)
[[ -f "$OTATOOLS_SRC" ]] || die "ไม่พบ otatools.zip"
cp "$OTATOOLS_SRC" "$REL_DIR/${DEVICE}-otatools.zip"
```
(ตำแหน่งใหม่: `out/soong/.intermediates/build/make/tools/otatools_package/otatools-package/linux_glibc_x86_64/gen/otatools.zip`)

---

### 15. script/decrypt-keys รอ password prompt

**Symptom:** `script/generate-release.sh husky 2026050901` exit ทันทีไม่สร้าง factory zip

**Root cause:** `script/decrypt-keys` มีบรรทัด:
```bash
[[ "${password+defined}" = defined ]] || read -rp "Enter key passphrase (empty if none): " -s password
```
เมื่อรันผ่าน tmux/non-interactive shell `read -rp ... -s` block + EOF → exit 1 → ทำให้ `set -e` ของ generate-release.sh ปลด trap แล้ว exit ทันที

**Fix:** ตั้ง env variable `password=""` ให้ script เช็คว่า "defined" (เป็น empty string) → skip read prompt → ใช้ no-password code path:
```bash
( cd "$BUILD_ROOT" && password="" script/generate-release.sh "$DEVICE" "$BUILD_NUMBER" )
```

---

## สูตรคำนวณทรัพยากร

### Disk
```
source tree (.repo + sync)        : ~150 GB (one-time)
out/ during build                 : ~110 GB peak (target-files-package)
adevtool-downloads (factory+OTA)  : ~22 GB (cache)
.ccache                           : 5-50 GB (compresses well)
out_adevtool_deps                 : ~12 GB (transient)
release artifacts (per device)    : ~5-7 GB (factory+OTA+install zips)
```

**ขั้นต่ำที่แนะนำ: 300 GB** (สำหรับ 1 device build)

ถ้าจะ build หลาย device ต้อง cleanup ระหว่างกัน:
```bash
sudo rm -rf out/target/product/<prev-device>
sudo rm -rf out_adevtool_deps adevtool-downloads/*
```

### RAM
```
JOBS = max(1, min(CPU_CORES, (RAM_GB - 4) / 4))
```
| RAM | JOBS |
|---:|---:|
| 16 GB | 3 |
| 24 GB | 5 |
| 32 GB | 6-7 |
| 64 GB | 15 (capped CPU) |
| 128 GB | 16 (capped CPU) |

**ขั้นต่ำที่แนะนำ: 16 GB RAM + 16 GB swap** (build จะช้ามากกินเวลา 6-12 ชั่วโมง)  
**แนะนำจริง: 32 GB RAM ขึ้นไป** (1-3 ชั่วโมง)

### เวลา
| ขั้น | เวลา (16 cores, 31 GB RAM) |
|---|---:|
| repo sync (150 GB) | 30-60 นาที |
| patch-grapheneos.sh | < 1 นาที |
| yarn install + m aapt2 | 10-15 นาที |
| adevtool download + generate-all | 15-30 นาที (เครือข่ายเร็ว) |
| **m target-files-package otatools-package** | **1-3 ชั่วโมง** |
| script/generate-release.sh | 15-30 นาที |
| **รวม** | **3-5 ชั่วโมง (ครั้งแรก)** |

---

## ผลลัพธ์สุดท้าย

**Build husky สำเร็จ** เมื่อ 2026-05-09 23:31

ไฟล์ output ที่ `/home/aukkwat/grapheneos/releases/2026050901/release-husky-2026050901/`:

| ไฟล์ | ขนาด | ใช้สำหรับ |
|---|---:|---|
| `husky-factory-2026050901.zip` | 1.7 GB | First-time flash (มี flash-all.sh + bootloader + radio + image + avb_pkmd) |
| `husky-img-2026050901.zip` | 1.65 GB | `fastboot update` |
| `husky-install-2026050901.zip` | 1.65 GB | flash-all แบบ archived พร้อม signature |
| `husky-ota_update-2026050901.zip` | 1.27 GB | `adb sideload` (อัปเดตจาก recovery) |
| `husky-target_files.zip` | 3.3 GB | sign target ภายใน |

Keys ที่ `/home/aukkwat/grapheneos/keys/husky/`:
- 9 signing keys (`bluetooth`, `gmscompat_lib`, `media`, `networkstack`, `nfc`, `platform`, `releasekey`, `sdk_sandbox`, `shared`) แต่ละชุดมี `.pk8` + `.x509.pem`
- `avb.pem` (RSA-4096 private key สำหรับ AVB)
- `avb_pkmd.bin` (public key ใช้ `fastboot flash avb_custom_key` ก่อน lock bootloader)

---

## วิธีใช้ script ปัจจุบัน

### บน Ubuntu 24.04 LTS clean image (เครื่องเปล่า)

```bash
# 1) Clone หรือ copy script directory เข้าเครื่อง
git clone <repo> grapheneOS-build-script
cd grapheneOS-build-script

# 2) (ครั้งแรก) ตั้ง git identity — script จะตั้งให้เอง แต่ override ได้
export GIT_NAME="Your Name"
export GIT_EMAIL="you@example.com"

# 3) รันแบบ user ปกติ (ไม่ใช่ root)
ASSUME_YES=1 ./one-all-stop-build-grapheneos-on-ubuntu24lts.sh husky
```

### Environment variables ที่ override ได้

| Variable | Default | ใช้เมื่อ |
|---|---|---|
| `GOS_TAG` | `2026042100` | เปลี่ยนเป็น tag GrapheneOS อื่น |
| `BUILD_ROOT` | `$HOME/grapheneos` | เปลี่ยน source location |
| `ADEV_DL` | `$HOME/adevtool-downloads` | เปลี่ยน adevtool cache |
| `CCACHE_DIR` | `$BUILD_ROOT/.ccache` | (อย่าออกนอก source tree!) |
| `CCACHE_SIZE` | `50G` | จำกัด ccache size |
| `ASSUME_YES` | `0` | `1` = ตอบ yes อัตโนมัติเมื่อ disk เตือน |
| `SKIP_SYNC` | `0` | `1` = ข้าม repo init/sync (ถ้า source ทำไว้แล้ว) |
| `CLEAN_OUT_AFTER` | `auto` | `1` = ลบ `out/<DEVICE>` หลัง build เพื่อเซฟ disk |
| `LOG_FILE` | `$HOME/gos-build-<TIMESTAMP>.log` | log file |

### รันบน tmux (กัน SSH หลุดแล้ว build หยุด)

```bash
# สร้าง runner script
cat > /tmp/runner.sh <<EOF
#!/bin/bash
cd ~/grapheneOS-build-script
ASSUME_YES=1 ./one-all-stop-build-grapheneos-on-ubuntu24lts.sh husky
EOF
chmod +x /tmp/runner.sh

# เริ่มใน tmux session
tmux new-session -d -s gos /tmp/runner.sh

# ดู progress (ออกจาก tmux ด้วย Ctrl+b แล้ว d)
tmux attach -t gos

# หรือดู log แบบ realtime
tail -F ~/gos-build-*.log
```

### เช็ก progress

```bash
./check-status.sh
```
output ตัวอย่าง:
```
=== GrapheneOS Build Status ===
Log file : /home/aukkwat/gos-build.log

● tmux session 'gos' กำลัง active

ขั้นตอนล่าสุด: STEP 7/8 — build (m target-files-package -j6)

--- Disk usage ---
  Disk root: 200G used / 293G total (เหลือ 81G, 72% ใช้)
  Source tree: 145G
  out/ (build): 57G

--- Memory ---
  Mem: 31Gi total, 12Gi used, 18Gi avail

--- Active build processes ---
  158454  cpu=692  mem=0.9  etime=00:35  soong_ui
  ...
```

### Flash บน Pixel (husky)

```bash
# 1) ที่เครื่อง Pixel: เปิด OEM unlocking ใน Developer options
# 2) เข้า bootloader
adb reboot bootloader

# 3) Unlock (ครั้งแรก, จะ wipe — กด Volume Up confirm)
fastboot flashing unlock

# 4) Extract + flash factory
unzip husky-factory-2026050901.zip
cd husky-factory-2026050901
./flash-all.sh

# 5) Flash custom AVB key (ก่อน lock!)
fastboot flash avb_custom_key /path/to/keys/husky/avb_pkmd.bin

# 6) Lock bootloader (กด Volume Up confirm — wipe อีกครั้ง)
fastboot flashing lock

# 7) บูตเข้า OS
# หน้าจอ boot จะเป็นสีเหลือง "Custom OS" — ปกติสำหรับ AVB custom key
```

| สี boot | ความหมาย |
|---|---|
| เขียว | locked + stock key (Google) |
| **เหลือง** | **locked + custom key (เรา)** |
| ส้ม | unlocked |

---

## Troubleshooting อย่างย่อ

| Error | หาที่หัวข้อ |
|---|---|
| `make_key ล้มเหลว` | [#1](#1-make_key-มี-trap-exit-1-เสมอ) |
| `engine "node" is incompatible` | [#3](#3-node-18-ของ-ubuntu-noble-เก่าเกินไปสำหรับ-adevtool) |
| `yarnpkg: command not found` | [#4](#4-yarnpkg-ถูกลบเมื่อ-replace-nodejs) |
| `TOP: unbound variable` | [#5](#5-set--u-ทะเลาะกับ-buildenvsetupsh) |
| `Command "admin:download" not found` | [#6](#6-adevtool-เปลี่ยน-api-จาก-yarn-script-เป็น-oclif) |
| `no images for '<dev> <tag>'` | [#7](#7--b-ของ-adevtool-หมายถึง-stock-build-id-ไม่ใช่-grapheneos-tag) |
| `ccache: ... Read-only file system` | [#8](#8-apparmor-ของ-ubuntu-2404-บล็อก-nsjail-sandbox) + [#9](#9-ccache-เห็น-filesystem-เป็น-read-only-ใน-sandbox) |
| `ninja: unknown target 'vanilla'` | [#10](#10-target-m-vanilla-ถูกเลิก) |
| `Killed process ... (ninja)` (OOM) | [#11](#11--j16--r8proguard-กิน-ram--oom-kill) |
| `cannot stat ...target_files-*.zip` | [#12](#12-ชื่อ-target_fileszip-เปลี่ยนรูปแบบ) |
| `cannot stat .../otatools.zip` | [#14](#14-otatoolszip-ย้ายตำแหน่ง) |
| `generate-release.sh` exit ทันที | [#15](#15-scriptdecrypt-keys-รอ-password-prompt) |
