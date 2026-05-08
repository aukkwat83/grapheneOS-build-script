# วิธีใช้ `patch-grapheneos.sh`

Build GrapheneOS แบบ unofficial (custom keys, ไม่มี OTA) จาก source tag `2026042100` บน Ubuntu 24.04

## ภาพรวม

script นี้ทำ 3 อย่างก่อน build:

1. **ลบ Updater (OTA client)** ออกจากระบบ — เครื่องจะไม่มีปุ่ม "Check for updates" หรือ background auto-update อีกต่อไป
2. **คง App Store ของ GrapheneOS ไว้** — ติดตั้ง/อัปเดต Sandboxed Play Services และแอพอื่นได้ปกติ
3. **สร้าง signing keys + AVB key ของตัวเอง** ที่ `keys/<DEVICE>/` สำหรับ sign image และ lock bootloader

> **วิธีอัปเดต OS หลัง build แล้ว**: ต้อง build ใหม่จาก source อย่างเดียว แล้ว sideload OTA หรือ flash factory image ใหม่

---

## PART 0 — เตรียม Ubuntu 24.04

ติดตั้ง dependencies ตามคู่มือ GrapheneOS:

```bash
sudo apt update
sudo apt install -y \
    bc bison build-essential ccache curl flex git git-lfs \
    gnupg gperf imagemagick lib32readline-dev lib32z1-dev \
    libelf-dev liblz4-tool libsdl1.2-dev libssl-dev \
    libxml2-utils lzop pngcrush rsync schedtool squashfs-tools \
    xsltproc zip zlib1g-dev openjdk-21-jdk python3 python-is-python3
```

ติดตั้ง `repo`:

```bash
mkdir -p ~/.bin
curl https://storage.googleapis.com/git-repo-downloads/repo > ~/.bin/repo
chmod a+x ~/.bin/repo
echo 'export PATH=~/.bin:$PATH' >> ~/.bashrc
source ~/.bashrc
```

ตั้ง git identity (จำเป็นสำหรับ repo):

```bash
git config --global user.email "you@example.com"
git config --global user.name "Your Name"
```

---

## PART 1 — ดึง source GrapheneOS 2026042100

```bash
mkdir -p ~/grapheneos && cd ~/grapheneos

repo init -u https://github.com/GrapheneOS/platform_manifest.git \
    -b refs/tags/2026042100 --depth=1

# ตรวจสอบลายเซ็น tag (recommended)
cd .repo/manifests
git verify-tag $(git describe)   # ต้อง import GPG key ของ GrapheneOS ก่อน
cd ../..

repo sync -j8
```

---

## PART 2 — คัดลอก script ไปไว้ใน source root

```bash
cp /path/to/patch-grapheneos.sh ~/grapheneos/
cd ~/grapheneos
chmod +x patch-grapheneos.sh
```

---

## PART 3 — รัน patch

```bash
# ระบุ codename ของ Pixel ที่จะ build
./patch-grapheneos.sh tokay

# Build หลายเครื่องพร้อมกันก็ได้
./patch-grapheneos.sh shiba husky comet tokay
```

### ตาราง codename ของ Pixel

| รุ่น | Codename | รุ่น | Codename |
|---|---|---|---|
| Pixel 6 | oriole | Pixel 7 | panther |
| Pixel 6 Pro | raven | Pixel 7 Pro | cheetah |
| Pixel 6a | bluejay | Pixel 7a | lynx |
| | | Pixel Fold | felix |
| | | Pixel Tablet | tangorpro |
| Pixel 8 | shiba | Pixel 9 | tokay |
| Pixel 8 Pro | husky | Pixel 9 Pro | caiman |
| Pixel 8a | akita | Pixel 9 Pro XL | komodo |
| Pixel 8a R2 | stallion | Pixel 9a | tegu |
| | | Pixel 9 Pro Fold | comet |
| Pixel 10 | blazer | Pixel 10 Pro | mustang |
| Pixel 10 Pro XL | rango | Pixel 10a | frankel |

### ผลลัพธ์ที่ได้หลังรัน

- `keys/<DEVICE>/` มี 9 signing keys + `avb.pem` + `avb_pkmd.bin`
- `packages/apps/Updater/Android.bp` → `Android.bp.disabled`
- `build/make/target/product/media_system.mk` แก้บล็อก Updater
- `vendor/adevtool/config/device/common/apk.yml` ลบ Updater entry
- ทุกไฟล์ที่แก้มี backup `.gosbak` ให้ revert
- `NEXT-STEPS.txt` มีคำสั่งเฉพาะ device ของคุณ

**(ทางเลือก) เข้ารหัส private keys ด้วย passphrase:**

```bash
./script/encrypt-keys keys/tokay
```

---

## PART 4 — Extract vendor blobs ด้วย adevtool

```bash
cd ~/grapheneos/vendor/adevtool
yarnpkg install
cd ~/grapheneos
source build/envsetup.sh
lunch sdk_phone64_x86_64-cur-user
m aapt2

# ดาวน์โหลด stock factory + OTA images แล้วแตก vendor blobs
yarnpkg --cwd vendor/adevtool/ admin:download \
    -d tokay -b 2026042100 ~/adevtool-downloads
yarnpkg --cwd vendor/adevtool/ generate-all \
    -d tokay -s ~/adevtool-downloads
```

---

## PART 5 — Build

```bash
source build/envsetup.sh

# user build (production, ปลอดภัยสุด)
lunch tokay-cur-user

# หรือ userdebug ถ้าต้องการ adb root, debugging
# lunch tokay-cur-userdebug

m vanilla
```

---

## PART 6 — Sign image ด้วย custom keys

```bash
# กำหนด BUILD_NUMBER (เช่น วันที่ + ลำดับ)
BUILD_NUMBER=$(date +%Y%m%d)01

# package เป็น target_files.zip ก่อน
m target-files-package otatools

# คัดลอก output ไปที่ releases/<BUILD>/
mkdir -p releases/$BUILD_NUMBER
cp out/target/product/tokay/obj/PACKAGING/target_files_intermediates/*-target_files-*.zip \
   releases/$BUILD_NUMBER/tokay-target_files.zip
cp out/host/linux-x86/otatools.zip \
   releases/$BUILD_NUMBER/tokay-otatools.zip

# sign + สร้าง factory zip + OTA zip
script/generate-release.sh tokay $BUILD_NUMBER
```

ผลลัพธ์อยู่ที่ `releases/<BUILD>/release-tokay-<BUILD>/`:

```
├── tokay-factory-<BUILD>.zip      (flash-all.sh ข้างใน)
├── tokay-ota_update-<BUILD>.zip   (สำหรับ sideload)
└── tokay-img-<BUILD>.zip          (fastboot update)
```

---

## PART 7 — Flash + Lock Bootloader ด้วย AVB key ของตัวเอง

ขั้นตอนนี้ทำบนตัวเครื่อง Pixel:

### 1) เปิด Developer options + OEM unlocking

- Settings → About phone → tap **Build number** 7 ครั้ง
- Settings → System → Developer options → เปิด **OEM unlocking**

### 2) บูตเข้า bootloader

```bash
adb reboot bootloader
```

### 3) ปลดล็อก bootloader (ครั้งแรกเท่านั้น)

```bash
fastboot flashing unlock
```

กดปุ่ม **Volume Up** เพื่อ confirm ที่หน้าเครื่อง — *เครื่องจะ factory reset*

### 4) Flash factory image

```bash
cd ~/grapheneos/releases/$BUILD_NUMBER/release-tokay-$BUILD_NUMBER
unzip tokay-factory-$BUILD_NUMBER.zip
cd tokay-install-$BUILD_NUMBER
./flash-all.sh
```

### 5) Flash AVB custom key (ก่อน lock)

```bash
fastboot flash avb_custom_key ~/grapheneos/keys/tokay/avb_pkmd.bin
```

### 6) Lock bootloader

```bash
fastboot flashing lock
```

กด **Volume Up** เพื่อ confirm — *เครื่องจะ factory reset อีกครั้ง*

### 7) บูตเข้า OS

หน้าจอ boot screen จะเป็น **สีเหลือง** พร้อมข้อความ "Custom OS" — ปกติสำหรับ AVB custom key

| สี | ความหมาย |
|---|---|
| 🟢 เขียว | stock key |
| 🟡 เหลือง | custom key |
| 🟠 ส้ม | unlocked |

---

## PART 8 — การอัปเดต OS (ในอนาคต)

เมื่อมี GrapheneOS tag ใหม่ (เช่น `2026050100`):

```bash
cd ~/grapheneos
repo init -u https://github.com/GrapheneOS/platform_manifest.git \
    -b refs/tags/<NEW_TAG> --depth=1
repo sync -j8

# patch ใหม่ (script เป็น idempotent ใช้ key เดิม)
./patch-grapheneos.sh tokay

# build + sign
source build/envsetup.sh
lunch tokay-cur-user
m vanilla
m target-files-package otatools
# ... (ทำซ้ำ Part 6)

script/generate-release.sh tokay <NEW_BUILD_NUMBER>
```

ส่ง OTA เข้าเครื่อง:

**วิธีที่ 1: sideload จาก recovery**

```bash
adb reboot recovery
# ที่หน้า recovery: Volume + Power เลือก "Apply update from ADB"
adb sideload releases/<BUILD>/release-tokay-<BUILD>/tokay-ota_update-<BUILD>.zip
```

**วิธีที่ 2: flash factory image ใหม่** (รักษาข้อมูลด้วย `flash-base.sh`)

```bash
cd ~/grapheneos/releases/<BUILD>/release-tokay-<BUILD>/tokay-install-<BUILD>/
./flash-base.sh   # ไม่ wipe userdata
```

---

## ภาคผนวก A — Lock Bootloader ด้วย Custom AVB Key

### A.1 Pixel รุ่นไหน Lock ด้วย custom key ได้บ้าง

**รองรับ `avb_custom_key`** (Lock + custom key ได้):

- Pixel 6, 6a, 6 Pro (oriole, bluejay, raven)
- Pixel 7, 7a, 7 Pro (panther, lynx, cheetah)
- Pixel Fold, Tablet (felix, tangorpro)
- Pixel 8, 8a, 8 Pro (shiba, akita, husky)
- Pixel 8a R2 (stallion)
- Pixel 9, 9a (tokay, tegu)
- Pixel 9 Pro/XL/Fold (caiman, komodo, comet)
- Pixel 10, 10a, 10 Pro/XL (blazer, frankel, mustang, rango)

→ Pixel ทุกรุ่นที่ GrapheneOS 2026042100 รองรับ lock ด้วย custom key ได้ทั้งหมด

**ไม่รองรับ**: Pixel 5a และก่อนหน้า (GrapheneOS ก็ไม่ support แล้ว)

### A.2 สถานะ Bootloader / สีหน้าจอ boot

| สถานะ | สี | ข้อความ |
|---|---|---|
| Unlocked | 🟠 ส้ม | "unlocked - cannot be trusted" |
| Locked + stock key | 🟢 เขียว | "Yours not Google's" (GrapheneOS official) |
| Locked + custom AVB key | 🟡 เหลือง | "Custom OS" ← ของคุณ |

> สีเหลือง = ปกติและปลอดภัย ไม่ใช่ระดับความเสี่ยงที่สูงกว่าเขียว เป็นแค่ตัวบอกว่า "นี่คือ OS ที่ verify ผ่านด้วย key ที่ไม่ใช่ Google" ตาม Android Verified Boot 2.0 spec

### A.3 หลัง Lock + Custom Key สิ่งที่ทำงานปกติ

- ✅ Verified Boot ครบสายโซ่ (bootloader → boot → system → vendor)
- ✅ Hardware-backed key attestation (TEE root of trust)
- ✅ StrongBox / Titan M2/M3 keys
- ✅ File-based encryption + biometric unlock
- ✅ Auditor app (local pairing — ใช้กับ phone อีกเครื่อง)
- ✅ Sandboxed Google Play (ติดตั้งจาก App Store ได้ปกติ)
- ✅ Vanadium browser, Seedvault backup, ทุกฟังก์ชันระบบ
- ✅ Banking apps ส่วนใหญ่ที่ทำงานบน GrapheneOS official ได้
- ✅ Rollback protection — เครื่องไม่ยอมรับ image เก่ากว่า

### A.4 สิ่งที่อาจมีปัญหา (เหมือน GrapheneOS official)

- ⚠ **Google Wallet / Pay** — Play Integrity HARDWARE_BACKED test ใช้ key chain ของ Google. VBMETA digest ที่ไม่ตรง stock อาจถูกปฏิเสธ — ปัญหานี้มีอยู่แล้วบน GrapheneOS official ไม่ใช่เพราะ patch ของเรา
- ⚠ **Banking / e-wallet / anti-cheat games บางตัว** ที่เช็ก Play Integrity เข้มงวด
- ⚠ **Auditor remote attestation server (attestation.app)** ไม่รู้จัก VBMETA digest ของคุณ → ใช้ local pairing แทน

### A.5 ขั้นตอน Lock ที่ถูกต้อง (ห้ามทำผิดลำดับ)

> ⚠ ผิดลำดับ = ติด boot loop ต้อง unlock + wipe ใหม่หมด

1. **Flash factory image** ที่ sign ด้วย custom key:
   ```bash
   cd releases/<BUILD>/release-<DEVICE>-<BUILD>/<DEVICE>-install-<BUILD>/
   ./flash-all.sh
   ```

2. **ตรวจว่า bootloader ยัง unlocked อยู่**:
   ```bash
   fastboot flashing get_unlock_ability
   # → ต้องได้ "1"
   ```

3. **Flash AVB custom public key**:
   ```bash
   fastboot flash avb_custom_key ~/grapheneos/keys/<DEVICE>/avb_pkmd.bin
   ```

4. **ตรวจสอบว่า key ถูก flash แล้ว**:
   ```bash
   fastboot oem device-info  # บางรุ่น
   # → ดูบรรทัด "Verity mode" หรือ "AVB"
   ```

5. **Lock bootloader**:
   ```bash
   fastboot flashing lock
   ```
   กด **Volume Up** confirm → factory reset อัตโนมัติ

6. **บูตเข้า OS** หน้าเหลือง "Custom OS" — ตั้งค่าครั้งแรก, ติดตั้ง App Store apps

7. **ปิด OEM unlocking** ใน Settings → System → Developer options → ปิด "OEM unlocking" (ป้องกัน attacker สั่ง unlock)

### A.6 ความเสี่ยงและการกู้คืน

⚠ **ถ้า `keys/<DEVICE>/` หาย:**

- build OTA/factory ใหม่ที่เครื่อง verify ผ่านไม่ได้อีกเลย
- ต้อง:
  1. `fastboot flashing unlock` (wipe userdata)
  2. generate keys ชุดใหม่
  3. flash ใหม่ด้วย key ใหม่
  4. `fastboot flash avb_custom_key` (key ใหม่)
  5. `fastboot flashing lock` (wipe อีกครั้ง)

→ **backup `keys/<DEVICE>/` encrypt ทุกครั้ง เก็บแยก 2 ที่**

⚠ **Build ครั้งต่อไปต้องใช้ key เดิมเสมอ** — ถ้าใช้ key ใหม่ เครื่องที่ lock อยู่จะ verify ไม่ผ่าน → boot loop ต้อง unlock + wipe + flash ใหม่. `script/generate-release.sh` ดึง key จาก `keys/<DEVICE>/` อัตโนมัติ — เก็บ folder นี้ไว้ตลอด

⚠ **ห้าม `fastboot flashing unlock` หลัง lock โดยไม่จำเป็น** — คำสั่ง unlock จะ wipe userdata อัตโนมัติ ทุกข้อมูลหาย

### A.7 ทำไมต้อง Lock (ทำไมไม่ปล่อย Unlocked)

ถ้าไม่ Lock = unlocked bootloader:

- ❌ Verified Boot ทั้งระบบไม่ทำงาน — evil-maid attack เป็นไปได้
- ❌ Hardware attestation ใช้ไม่ได้เต็มที่
- ❌ StrongBox keys ผูกกับ bootloader state — unlock = invalidate
- ❌ Banking / 2FA / Wallet apps ส่วนใหญ่ปฏิเสธทันที
- ❌ เทียบเท่า device ที่ root — ยอม trade ความปลอดภัยเพื่อ debug

→ **Lock เถอะ** ผลข้างเคียงเทียบกับ GrapheneOS official เกือบไม่ต่างกัน แต่ได้ความปลอดภัยกลับมาเต็ม

---

## หมายเหตุสำคัญ

- 🔑 **`keys/<DEVICE>/` คือสมบัติล้ำค่า** — ห้ามหาย ห้ามเผยแพร่ เก็บ backup ที่ปลอดภัย encrypt ด้วย passphrase. ถ้าหายจะ build OTA update ที่เครื่อง verify ผ่านไม่ได้อีกเลย (ต้อง unlock + flash ใหม่ + lock ใหม่ พร้อม wipe)

- 📱 **เครื่องที่ flash custom-signed image แล้ว lock bootloader:**
  - rollback ไป image ที่ sign ด้วย key อื่นไม่ได้ จนกว่าจะ unlock ใหม่
  - การ unlock ทำให้ wipe userdata อัตโนมัติ
  - หน้า boot จะเป็นสีเหลือง (custom OS) แทนสีเขียว (stock)

- 🛍 **App Store ของ GrapheneOS ยังทำงานปกติ** — ติดตั้ง Sandboxed Google Play / Vanadium / Auditor ได้ และอัปเดตเองผ่าน App Store

- ⏱ **การ build แต่ละครั้งใช้เวลา 1–3 ชั่วโมง** ขึ้นกับ CPU/RAM แนะนำ RAM อย่างน้อย 32 GB, ดิสก์ว่าง 400+ GB ใช้ `ccache` เพิ่มความเร็ว build ครั้งถัดไป

- ✍ **Verify ลายเซ็น tag ของ GrapheneOS** ทุกครั้งก่อน sync — ดูคู่มือที่ <https://grapheneos.org/build#extracting-vendor-files-for-pixel-devices>

---

## ไฟล์อื่นที่เกี่ยวข้อง

| ไฟล์ | คำอธิบาย |
|---|---|
| `patch-grapheneos.sh` | script patch ที่ผู้ใช้รัน |
| `NEXT-STEPS.txt` | คำสั่งเฉพาะ device (สร้างโดย script) |
| `keys/<DEVICE>/` | กุญแจที่สร้างใหม่ |
| `*.gosbak` | backup file ที่ patch แก้ ใช้ revert ได้ |

### โครงสร้าง `keys/<DEVICE>/`

| ไฟล์ | หน้าที่ |
|---|---|
| `releasekey.{pk8,x509.pem}` | กุญแจหลัก, ใช้ sign OTA |
| `platform.{pk8,x509.pem}` | สำหรับ system app |
| `shared.{pk8,x509.pem}` | shared user-id |
| `media.{pk8,x509.pem}` | media framework |
| `networkstack.{pk8,x509.pem}` | NetworkStack module |
| `bluetooth.{pk8,x509.pem}` | Bluetooth module |
| `nfc.{pk8,x509.pem}` | NFC module |
| `sdk_sandbox.{pk8,x509.pem}` | SDK sandbox |
| `gmscompat_lib.{pk8,x509.pem}` | GmsCompat library |
| `avb.pem` | AVB private key (RSA-4096) |
| `avb_pkmd.bin` | AVB public key — flash ผ่าน fastboot |
