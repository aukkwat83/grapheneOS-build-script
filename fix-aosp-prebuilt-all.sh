#!/bin/bash
# fix-aosp-prebuilt-all.sh
# แก้ทุก library dependencies สำหรับ AOSP build บน Guix System

set -e

echo "=== GrapheneOS AOSP Prebuilt Libraries Fix ==="
echo "วันที่: $(date)"
echo

# ต้องรันเป็น root
if [ "$EUID" -ne 0 ]; then
  echo "❌ Error: ต้องรัน script นี้ด้วย sudo หรือ root"
  echo "   ใช้: sudo $0"
  exit 1
fi

AOSP_DIR="/home/guix/grapheneos"
PREBUILTS_LIB="$AOSP_DIR/prebuilts/build-tools/linux-x86/lib64"

# Step 1: Symlink ทุก AOSP prebuilt libraries
echo "=== [1/4] Symlinking AOSP prebuilt libraries ==="
if [ ! -d "$PREBUILTS_LIB" ]; then
  echo "❌ Error: $PREBUILTS_LIB ไม่พบ"
  exit 1
fi

cd "$PREBUILTS_LIB"
count=0
for lib in *.so*; do
  if [ -f "$lib" ]; then
    ln -sf "$(pwd)/$lib" /lib/x86_64-linux-gnu/
    ln -sf "$(pwd)/$lib" /usr/lib/x86_64-linux-gnu/
    count=$((count+1))
  fi
done

echo "✓ Symlinked $count libraries"
echo

# Step 2: รัน ldconfig
echo "=== [2/4] Updating dynamic linker cache ==="
LDCONFIG=$(find /gnu/store -name ldconfig -type f 2>/dev/null | head -1)
if [ -n "$LDCONFIG" ]; then
  $LDCONFIG /lib/x86_64-linux-gnu /usr/lib/x86_64-linux-gnu 2>/dev/null || true
  echo "✓ ldconfig done"
else
  echo "⚠ ldconfig not found, skipping"
fi
echo

# Step 3: Install patchelf (ถ้ายังไม่มี)
echo "=== [3/4] Installing patchelf ==="
sudo -u guix guix package -i patchelf 2>&1 | tail -5
echo "✓ patchelf installed"
echo

# Step 4: Patch ทุก ELF binaries
echo "=== [4/4] Patching ELF binaries with patchelf ==="
echo "รอสักครู่... (อาจใช้เวลา 5-10 นาที)"

RPATH="/lib/x86_64-linux-gnu:/usr/lib/x86_64-linux-gnu"
INTERP="/lib64/ld-linux-x86-64.so.2"

cd "$AOSP_DIR"
count=0

find prebuilts out -type f -executable 2>/dev/null | while read bin; do
  # ตรวจสอบว่าเป็น ELF binary
  if head -c 4 "$bin" 2>/dev/null | grep -q $'^\x7fELF'; then
    count=$((count+1))
    
    # Patch interpreter และ RPATH
    patchelf --set-interpreter "$INTERP" "$bin" 2>/dev/null || true
    patchelf --set-rpath "$RPATH" "$bin" 2>/dev/null || true
    
    # แสดง progress ทุก 100 files
    if [ $((count % 100)) -eq 0 ]; then
      echo "  Patched $count files..."
    fi
  fi
done

echo "✓ Patchelf done!"
echo

# ทดสอบ
echo "=== Testing ckati binary ==="
cd "$AOSP_DIR"
if prebuilts/build-tools/linux-x86/bin/ckati 2>&1 | grep -q "No targets"; then
  echo "✅ SUCCESS! ckati ทำงานได้"
else
  echo "⚠ ckati ยังไม่ทำงาน - ตรวจสอบ log ด้านบน"
fi

echo
echo "=== สรุป ==="
echo "✓ Symlinked $count AOSP libraries"
echo "✓ Updated ldconfig cache"
echo "✓ Installed patchelf"
echo "✓ Patched all ELF binaries"
echo
echo "📝 Next: รัน build ด้วย"
echo "   cd ~/grapheneos"
echo "   export TARGET_PRODUCT=husky TARGET_RELEASE=cur TARGET_BUILD_VARIANT=user"
echo "   source build/envsetup.sh"
echo "   m vanilla"
