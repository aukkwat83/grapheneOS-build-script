#!/usr/bin/env bash
# =====================================================================
# wait-and-continue-guix-test.sh
#
# รอ Guix VM กลับมา online แล้วทดสอบต่ออัตโนมัติ
# =====================================================================

set -o errexit -o nounset -o pipefail

GUIX_IP="10.211.55.27"
GUIX_USER="guix"
MAX_WAIT=600  # 10 minutes
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "[$(date)] รอ Guix VM กลับมา online (max ${MAX_WAIT}s)..."

# Wait for VM
elapsed=0
while [ $elapsed -lt $MAX_WAIT ]; do
    if ping -c 1 -W 2 "$GUIX_IP" >/dev/null 2>&1; then
        echo "[$(date)] ✓ VM online! (รอ ${elapsed}s)"
        break
    fi
    sleep 5
    elapsed=$((elapsed + 5))
    echo -n "."
done

if [ $elapsed -ge $MAX_WAIT ]; then
    echo
    echo "[$(date)] ✗ VM ยังไม่กลับมาภายใน ${MAX_WAIT}s"
    echo "กรุณา start VM ด้วยตัวเอง แล้วรัน script นี้อีกครั้ง"
    exit 1
fi

echo

# Wait for SSH
echo "[$(date)] รอ SSH service..."
sleep 10
for i in {1..10}; do
    if ssh -o ConnectTimeout=5 "$GUIX_USER@$GUIX_IP" 'echo online' >/dev/null 2>&1; then
        echo "[$(date)] ✓ SSH ready!"
        break
    fi
    sleep 3
done

# Check status
echo
echo "[$(date)] ตรวจสอบสถานะ VM..."
ssh "$GUIX_USER@$GUIX_IP" 'uptime'
ssh "$GUIX_USER@$GUIX_IP" 'df -h | grep -E "(Filesystem|/home)"'

# Check repo sync status
echo
echo "[$(date)] ตรวจสอบ repo sync..."
if ssh "$GUIX_USER@$GUIX_IP" '[ -f ~/grapheneos/.gos-synced-tag ]'; then
    TAG=$(ssh "$GUIX_USER@$GUIX_IP" 'cat ~/grapheneos/.gos-synced-tag')
    SIZE=$(ssh "$GUIX_USER@$GUIX_IP" 'du -sh ~/grapheneos 2>/dev/null | cut -f1')
    echo "✓ Source tree sync เสร็จแล้ว (tag: $TAG, size: $SIZE)"
    SKIP_SYNC=1
else
    echo "✗ Source tree ยังไม่ sync เสร็จ — จะ sync ต่อในขั้นตอนถัดไป"
    SKIP_SYNC=0
fi

# Check previous logs
echo
echo "[$(date)] ตรวจสอบ log ครั้งก่อน..."
ssh "$GUIX_USER@$GUIX_IP" 'tail -30 ~/gos-build-*.log 2>/dev/null | tail -20' || echo "(ยังไม่มี log)"

# Continue test
echo
echo "========================================"
read -p "ต้องการทดสอบต่อหรือไม่? [y/N] " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "ยกเลิก — สามารถรันทดสอบด้วยตัวเองได้:"
    echo "  scp $SCRIPT_DIR/one-all-stop-build-grapheneos-on-guixsystem-150withgpg.sh $GUIX_USER@$GUIX_IP:~/"
    echo "  ssh $GUIX_USER@$GUIX_IP 'ASSUME_YES=1 SKIP_SYNC=$SKIP_SYNC SKIP_GPG=1 ~/one-all-stop-build-grapheneos-on-guixsystem-150withgpg.sh husky'"
    exit 0
fi

echo
echo "[$(date)] Copy script ไปเครื่อง Guix..."
scp "$SCRIPT_DIR/one-all-stop-build-grapheneos-on-guixsystem-150withgpg.sh" \
    "$SCRIPT_DIR/patch-grapheneos.sh" \
    "$GUIX_USER@$GUIX_IP:~/"

echo
echo "[$(date)] เริ่มทดสอบ (SKIP_SYNC=$SKIP_SYNC)..."
ssh "$GUIX_USER@$GUIX_IP" "ASSUME_YES=1 SKIP_SYNC=$SKIP_SYNC SKIP_GPG=1 ~/one-all-stop-build-grapheneos-on-guixsystem-150withgpg.sh husky" | tee "/tmp/guix-test-$(date +%Y%m%d-%H%M%S).log"

echo
echo "[$(date)] เสร็จสิ้น!"
