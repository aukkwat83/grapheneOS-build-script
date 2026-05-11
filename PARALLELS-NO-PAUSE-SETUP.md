# Parallels Desktop - ปิด Auto-Pause Configuration

**วันที่**: 2026-05-11  
**สถานะ**: ✅ ตั้งค่าเสร็จสิ้น - VM จะไม่ pause อัตโนมัติ

---

## ปัญหา: Parallels ชอบ Pause VM เอง

Parallels มี feature auto-pause หลายแบบที่จะ pause VM เมื่อ:
- Mac idle นาน
- VM idle (ไม่มี user interaction)
- Switch ไป Mac desktop
- Mac เข้า sleep mode

สำหรับ **long-running build** (3-8 ชั่วโมง) ต้องปิดทั้งหมด!

---

## ✅ การตั้งค่าที่ทำแล้ว (Command Line)

### 1. ปิด Auto-Pause ของ VM

```bash
# ตรวจสอบ VM ที่มี
prlctl list -a

# ปิด pause-idle
prlctl set guixsystem --pause-idle off

# ปิด adaptive hypervisor
prlctl set guixsystem --adaptive-hypervisor off

# ตั้ง resource unlimited
prlctl set guixsystem --resource-quota unlimited
```

**ผลลัพธ์**:
```
State: running
Pause idle: off
Adaptive hypervisor: off
Resource quota: unlimited
```

### 2. ป้องกัน Mac Sleep (caffeinate)

```bash
# รัน caffeinate background
caffeinate -di &

# บันทึก PID (ไว้ stop ภายหลัง)
echo $! > /tmp/caffeinate-gos-build.pid

# ตรวจสอบ
pgrep -fl caffeinate
```

**หยุด caffeinate** (เมื่อ build เสร็จ):
```bash
kill $(cat /tmp/caffeinate-gos-build.pid)
```

---

## 🎯 การตั้งค่าผ่าน GUI (ทางเลือก)

### Parallels Desktop Settings

1. **VM-specific Settings**:
   - คลิกขวาที่ VM → **Configure...**
   - แท็บ **Options** → **Optimization**
   - Resource usage: **Faster virtual machine**
   - ❌ ยกเลิกติ๊ก **"Pause when idle"**
   - ❌ ยกเลิกติ๊ก **"Adaptive Hypervisor"**

2. **Global Preferences**:
   - **Parallels Desktop** → **Preferences...**
   - แท็บ **Shortcuts**
   - ❌ ยกเลิกติ๊ก **"Pause virtual machine when switching to Mac"**

### macOS Energy Settings

**System Settings** → **Lock Screen** (หรือ Energy Saver):
- Turn display off after: **Never** (หรือ 1+ ชม.)
- ❌ ยกเลิกติ๊ก **"Put hard disks to sleep when possible"**
- ❌ ยกเลิกติ๊ก **"Prevent automatic sleeping on power adapter when display is off"**

---

## 🔍 ตรวจสอบสถานะ

### VM Configuration
```bash
prlctl list -i guixsystem | grep -i "state\|pause\|adaptive\|quota"
```

**ต้องเห็น**:
- ✅ `Pause idle: off`
- ✅ `Adaptive hypervisor: off`
- ✅ `Resource quota: unlimited`
- ✅ `State: running`

### Caffeinate Status
```bash
# ตรวจสอบว่ารันอยู่
pgrep -fl caffeinate

# ดู uptime (Mac ไม่ควร sleep)
uptime

# ดู system log (ไม่ควรมี sleep events)
pmset -g log | grep -i sleep | tail
```

---

## 📊 สรุป Performance Impact

| Setting | Before | After | Impact |
|---------|--------|-------|--------|
| VM Pause | Auto (idle > 5m) | Never | ✅ Build ไม่ขัดจังหวะ |
| CPU Priority | Adaptive | High | ✅ Performance สม่ำเสมอ |
| Resource Limit | Auto | Unlimited | ✅ ใช้ทรัพยากรเต็มที่ |
| Mac Sleep | Auto (20m) | Never | ✅ VM รันต่อเนื่อง |

---

## 🚨 Troubleshooting

### ถ้า VM ยัง pause อยู่:

1. **ตรวจสอบ VM config ใหม่**:
   ```bash
   prlctl list -i guixsystem | grep -i pause
   ```

2. **Restart VM** (ไม่จำเป็นส่วนใหญ่):
   ```bash
   prlctl restart guixsystem
   ```

3. **ตรวจสอบ Mac sleep**:
   ```bash
   pmset -g assertions | grep -i "PreventUserIdleSystemSleep\|NoIdleSleepAssertion"
   # ต้องมี caffeinate listed
   ```

4. **Force resume VM** (ถ้า pause แล้ว):
   ```bash
   prlctl resume guixsystem
   ```

### Monitor VM state real-time:
```bash
# ดู state ทุก 10 วินาที
watch -n 10 'prlctl list guixsystem'
```

---

## 📝 Script เริ่ม Build (All-in-One)

```bash
#!/bin/bash
# start-gos-build-no-pause.sh

echo "=== Starting GrapheneOS Build (No-Pause Mode) ==="

# 1. ตั้งค่า Parallels VM
prlctl set guixsystem --pause-idle off
prlctl set guixsystem --adaptive-hypervisor off
prlctl set guixsystem --resource-quota unlimited

# 2. ป้องกัน Mac sleep
caffeinate -di &
echo $! > /tmp/caffeinate-gos.pid
echo "✓ Caffeinate started (PID: $(cat /tmp/caffeinate-gos.pid))"

# 3. ตรวจสอบ VM
echo "✓ VM Config:"
prlctl list -i guixsystem | grep -i "pause\|adaptive\|quota"

# 4. SSH เข้า VM และ start build
ssh guix@10.211.55.27 'nohup ~/one-all-stop-build-grapheneos-on-guixsystem-150withgpg.sh husky > ~/build.log 2>&1 &'

echo
echo "✓ Build started!"
echo "  - VM จะไม่ pause"
echo "  - Mac จะไม่ sleep"
echo "  - Monitor: ssh guix@10.211.55.27 'tail -f ~/build.log'"
echo
echo "Stop caffeinate เมื่อเสร็จ: kill \$(cat /tmp/caffeinate-gos.pid)"
```

---

## ✅ สรุปสุดท้าย

**Parallels VM**:
- ✅ Pause idle: **OFF**
- ✅ Adaptive hypervisor: **OFF**
- ✅ Resource quota: **UNLIMITED**

**macOS Host**:
- ✅ Caffeinate: **RUNNING** (PID: 18147)
- ✅ Auto-sleep: **PREVENTED**

**ผลลัพธ์**: VM + Mac จะไม่ sleep/pause ระหว่าง build GrapheneOS (3-8 ชั่วโมง) ✨
