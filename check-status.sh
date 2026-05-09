#!/usr/bin/env bash
# =====================================================================
# check-status.sh — สำหรับเช็กว่า build ที่กำลังทำอยู่ถึงไหนแล้ว
# (รันบนเครื่องเดียวกับที่รัน one-all-stop-build...sh)
#
# Usage:  ./check-status.sh
# =====================================================================

set -o pipefail

c_grn=$'\e[1;32m'; c_ylw=$'\e[1;33m'; c_blu=$'\e[1;34m'; c_cyn=$'\e[1;36m'; c_red=$'\e[1;31m'; c_off=$'\e[0m'

LOG=$(ls -t "$HOME"/gos-build*.log 2>/dev/null | head -1)
BUILD_ROOT="${BUILD_ROOT:-$HOME/grapheneos}"

[[ -f "$LOG" ]] || { echo "ไม่พบ log file ที่ ~/gos-build*.log — build อาจยังไม่เริ่ม"; exit 1; }

echo "${c_cyn}=== GrapheneOS Build Status ===${c_off}"
echo "Log file : $LOG  ($(stat -c%y "$LOG" | cut -d. -f1))"
echo

# tmux session
if tmux has-session -t gos 2>/dev/null; then
    echo "${c_grn}● tmux session 'gos' กำลัง active${c_off}  (เข้าดูได้: tmux attach -t gos)"
else
    if grep -q '^EXIT=0' "$LOG" 2>/dev/null; then
        echo "${c_grn}● Build เสร็จเรียบร้อย${c_off}"
    elif grep -q '^EXIT=' "$LOG" 2>/dev/null; then
        echo "${c_red}● Build จบด้วย error ($(grep '^EXIT=' "$LOG" | tail -1))${c_off}"
    else
        echo "${c_ylw}● tmux session ไม่ทำงาน และ log ไม่มี EXIT — อาจหยุดผิดปกติ${c_off}"
    fi
fi
echo

# step ปัจจุบัน
LAST_STEP=$(grep -E '==== STEP [0-9]/8' "$LOG" | sed 's/\x1b\[[0-9;]*m//g' | tail -1)
echo "ขั้นตอนล่าสุด: ${c_blu}${LAST_STEP:-(ยังไม่ขึ้น STEP)}${c_off}"
echo

# disk
echo "${c_cyn}--- Disk usage ---${c_off}"
df -h / | tail -1 | awk '{printf "  Disk root: %s used / %s total (เหลือ %s, %s ใช้)\n", $3, $2, $4, $5}'
[[ -d "$BUILD_ROOT" ]] && du -sh "$BUILD_ROOT" 2>/dev/null | awk '{printf "  Source tree (%s): %s\n", $2, $1}'
[[ -d "$HOME/adevtool-downloads" ]] && du -sh "$HOME/adevtool-downloads" 2>/dev/null | awk '{printf "  adevtool dl  : %s\n", $1}'
[[ -d "$BUILD_ROOT/out" ]]      && du -sh "$BUILD_ROOT/out"      2>/dev/null | awk '{printf "  out/ (build) : %s\n", $1}'
[[ -d "$BUILD_ROOT/releases" ]] && du -sh "$BUILD_ROOT/releases" 2>/dev/null | awk '{printf "  releases/    : %s\n", $1}'
echo

# RAM
echo "${c_cyn}--- Memory ---${c_off}"
free -h | awk 'NR<=2{print "  "$0}'
echo

# load + active processes
echo "${c_cyn}--- Active build processes ---${c_off}"
ps -eo pid,pcpu,pmem,etime,comm --sort=-pcpu | grep -E "soong|java|javac|cc1|clang|m\b|python3|repo|git|yarnpkg|node|m_vanilla" | head -8 | awk '{printf "  %-7s cpu=%-5s mem=%-5s etime=%-9s %s\n", $1, $2, $3, $4, $5}'
echo

# release artifacts
echo "${c_cyn}--- Flashable artifacts (ถ้ามี) ---${c_off}"
if compgen -G "$BUILD_ROOT/releases/*/release-*-*/*-factory-*.zip" >/dev/null; then
    ls -lh "$BUILD_ROOT"/releases/*/release-*-*/*-factory-*.zip 2>/dev/null | awk '{print "  ✓ "$NF" ("$5")"}'
    ls -lh "$BUILD_ROOT"/releases/*/release-*-*/*-ota_update-*.zip 2>/dev/null | awk '{print "  ✓ "$NF" ("$5")"}'
else
    echo "  (ยังไม่มี — รอ build เสร็จ)"
fi
echo
echo "ดู log แบบ realtime: ${c_ylw}tail -F $LOG${c_off}"
echo "เข้า tmux session : ${c_ylw}tmux attach -t gos${c_off}  (ออกด้วย Ctrl+b แล้ว d)"
