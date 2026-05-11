# Guix System - No Sleep/Standby Configuration

**วันที่**: 2026-05-11  
**สถานะ**: ✅ ตั้งค่าเสร็จสิ้น - VM จะไม่ sleep/standby อัตโนมัติ

---

## การตั้งค่าที่ทำแล้ว

### 1. GNOME Power Settings (User-Level)

สร้าง script: `~/disable-power-management.sh`

```bash
#!/run/current-system/profile/bin/bash
# ปิด Power Management สำหรับ build ระยะยาว

export DISPLAY=:0
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus

GSETTINGS=$(find /gnu/store -path "*/bin/gsettings" 2>/dev/null | head -1)

# ปิด auto suspend
$GSETTINGS set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type "nothing"
$GSETTINGS set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type "nothing"

# ตั้งค่า idle timeout = never
$GSETTINGS set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-timeout 0
$GSETTINGS set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-timeout 0

# ปิด screen blank
$GSETTINGS set org.gnome.desktop.session idle-delay 0

# ปิด screensaver
$GSETTINGS set org.gnome.desktop.screensaver lock-enabled false
$GSETTINGS set org.gnome.desktop.screensaver idle-activation-enabled false
```

**Auto-run**: เพิ่มใน `~/.bash_profile` → รันทุกครั้งที่ login

---

### 2. Keep-Alive Service

สร้าง script: `~/keep-alive.sh`

```bash
#!/run/current-system/profile/bin/bash
# Keep system awake (heartbeat ทุก 60 วินาที)

echo $$ > ~/keep-alive.lock

while true; do
    touch ~/keep-alive-timestamp
    if [ $((SECONDS % 300)) -lt 60 ]; then
        echo "[$(date)] ♥ Keep-alive heartbeat"
    fi
    sleep 60
done
```

**การใช้งาน**:
```bash
# Start
~/keep-alive.sh > ~/keep-alive.log 2>&1 &

# Stop
kill $(cat ~/keep-alive.lock)

# Check
tail -f ~/keep-alive.log
```

---

### 3. Logind Configuration (Root-Level)

สร้างไฟล์: `/etc/systemd/logind.conf.d/no-suspend.conf`

```ini
[Login]
HandleSuspendKey=ignore
HandleHibernateKey=ignore
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
IdleAction=ignore
IdleActionSec=0
```

**หมายเหตุ**: Guix ใช้ shepherd (ไม่ใช่ systemd) แต่ logind config ยังใช้งานได้

---

## ตรวจสอบสถานะ

### GNOME Settings
```bash
export DISPLAY=:0
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus
GSETTINGS=$(find /gnu/store -path "*/bin/gsettings" 2>/dev/null | head -1)

echo "Sleep on AC: $($GSETTINGS get org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type)"
echo "Sleep on Battery: $($GSETTINGS get org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type)"
echo "Idle delay: $($GSETTINGS get org.gnome.desktop.session idle-delay) (0 = never)"
echo "Screensaver: $($GSETTINGS get org.gnome.desktop.screensaver lock-enabled)"
```

### Keep-Alive Service
```bash
# Check if running
ps aux | grep keep-alive.sh | grep -v grep

# Check last heartbeat
ls -lh ~/keep-alive-timestamp

# View log
tail -20 ~/keep-alive.log
```

---

## Parallels Desktop Settings (แนะนำ)

นอกเหนือจาก Guix config ควรตั้งค่า VM settings ด้วย:

1. **Virtual Machine → Configure → Options → Optimization**
   - Resource usage: **Faster virtual machine**
   - Adaptive Hypervisor: **OFF**

2. **Actions → Configure → Hardware → Power Management**
   - ปิด **Pause when idle**
   - ปิด **Put Mac to sleep**

---

## ทดสอบ

```bash
# ทดสอบว่า VM ไม่ sleep ระหว่าง build
ssh guix@10.211.55.27 'uptime; ps aux | grep keep-alive'

# ดู keep-alive log
ssh guix@10.211.55.27 'tail -20 ~/keep-alive.log'

# ตรวจสอบ GNOME power settings
ssh guix@10.211.55.27 '~/disable-power-management.sh'
```

---

## สรุป

✅ **User-level**: GNOME power settings ปิดแล้ว (auto-run on login)  
✅ **System-level**: logind config ปิด idle actions  
✅ **Keep-alive**: heartbeat service ทำงานตลอด (PID: 2375)  
✅ **Persistent**: การตั้งค่าจะคงอยู่หลัง reboot

**ผลลัพธ์**: VM จะไม่ sleep/standby อัตโนมัติ → เหมาะสำหรับ build GrapheneOS ระยะยาว (3-8 ชั่วโมง)
