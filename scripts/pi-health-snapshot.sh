#!/bin/bash
# Pi Health Snapshot — collects ALL metrics in one shot, for debugging
# Usage: bash pi-health-snapshot.sh
# Run manually after a freeze/crash to see what's happening right now

set -euo pipefail

TIMESTAMP=$(date -Is)
SEPARATOR="──────────────────────────────────────────────────────────"

echo "══════════════════════════════════════════════════════════════"
echo "  PI HEALTH SNAPSHOT — $TIMESTAMP"
echo "══════════════════════════════════════════════════════════════"
echo ""

# ── 1. UPTIME & LOAD ──────────────────────────────────────
echo "$SEPARATOR"
echo "1. UPTIME & LOAD"
echo "$SEPARATOR"
echo "Uptime: $(uptime)"
echo ""
echo "Boot time: $(who -b 2>/dev/null | awk '{print $3, $4}' || echo 'unknown')"
echo "Boot ID: $(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo 'unknown')"

# ── 2. TEMPERATURE & THROTTLING ───────────────────────────
echo ""
echo "$SEPARATOR"
echo "2. TEMPERATURE & THROTTLING"
echo "$SEPARATOR"
vcgencmd measure_temp 2>/dev/null || echo "temp: unavailable"
echo "Throttled: $(vcgencmd get_throttled 2>/dev/null || echo 'unavailable')"
echo "GPU mem: $(vcgencmd get_mem gpu 2>/dev/null || echo 'unavailable')"
echo "EEPROM: $(sudo rpi-eeprom-update 2>/dev/null | head -1 || echo 'unavailable')"

# ── 3. MEMORY & SWAP ──────────────────────────────────────
echo ""
echo "$SEPARATOR"
echo "3. MEMORY & SWAP"
echo "$SEPARATOR"
free -h

# ── 4. DISK & INODES ──────────────────────────────────────
echo ""
echo "$SEPARATOR"
echo "4. DISK & INODES"
echo "$SEPARATOR"
df -h /
echo ""
df -i /

# ── 5. CPU & I/O WAIT ─────────────────────────────────────
echo ""
echo "$SEPARATOR"
echo "5. CPU & I/O WAIT"
echo "$SEPARATOR"
top -bn1 | head -5

# ── 6. D-STATE & ZOMBIE PROCESSES ─────────────────────────
echo ""
echo "$SEPARATOR"
echo "6. D-STATE PROCESSES (uninterruptible sleep — I/O stuck)"
echo "$SEPARATOR"
D_COUNT=$(ps aux | awk '$8 ~ /D/ {count++} END {print count+0}')
echo "D-state count: $D_COUNT"
if [ "$D_COUNT" -gt 0 ]; then
    ps aux | awk 'NR==1 || $8 ~ /D/ {print}'
else
    echo "(none — clean)"
fi

echo ""
echo "$SEPARATOR"
echo "7. ZOMBIE PROCESSES"
echo "$SEPARATOR"
Z_COUNT=$(ps aux | awk '$8 ~ /Z/ {count++} END {print count+0}')
echo "Zombie count: $Z_COUNT"
if [ "$Z_COUNT" -gt 0 ]; then
    ps aux | awk 'NR==1 || $8 ~ /Z/ {print}'
else
    echo "(none — clean)"
fi

# ── 8. PROCESS COUNT & TOP CONSUMERS ──────────────────────
echo ""
echo "$SEPARATOR"
echo "8. PROCESS COUNT & TOP CPU CONSUMERS"
echo "$SEPARATOR"
echo "Total processes: $(ps aux | wc -l)"
echo ""
ps aux --sort=-%cpu | head -6

echo ""
echo "$SEPARATOR"
echo "9. TOP MEMORY CONSUMERS"
echo "$SEPARATOR"
ps aux --sort=-%mem | head -6

# ── 10. FILE DESCRIPTORS ──────────────────────────────────
echo ""
echo "$SEPARATOR"
echo "10. FILE DESCRIPTORS (system-wide)"
echo "$SEPARATOR"
cat /proc/sys/fs/file-nr 2>/dev/null || echo "unavailable"

# ── 11. NETWORK ───────────────────────────────────────────
echo ""
echo "$SEPARATOR"
echo "11. NETWORK"
echo "$SEPARATOR"
echo "Connectivity: $(ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1 && echo 'UP' || echo 'DOWN')"
echo ""
ip -4 addr show wlan0 2>/dev/null | grep inet || echo "wlan0: no IP"
echo ""
iwconfig wlan0 2>/dev/null | grep -E "ESSID|Frequency|Power Management|Link Quality|Signal" || echo "wlan0: unavailable"

# ── 12. NVMe SMART ────────────────────────────────────────
echo ""
echo "$SEPARATOR"
echo "12. NVMe SMART"
echo "$SEPARATOR"
sudo nvme smart-log /dev/nvme0 2>/dev/null | grep -E "critical_warning|temperature|available_spare|percentage_used|media_errors|unsafe_shutdowns" || echo "SMART unavailable"

# ── 13. NVMe I/O STATS ────────────────────────────────────
echo ""
echo "$SEPARATOR"
echo "13. NVMe I/O STATS"
echo "$SEPARATOR"
cat /sys/block/nvme0n1/stat 2>/dev/null || echo "unavailable"
echo "(reads_completed reads_merged sectors_read ms_reading writes_completed writes_merged sectors_written ms_writing ios_in_progress ms_ioing ms_weighted_ioing)"

# ── 14. PMIC FIRMWARE ERRORS ──────────────────────────────
echo ""
echo "$SEPARATOR"
echo "14. PMIC FIRMWARE ERRORS (silent freeze cause #1)"
echo "$SEPARATOR"
PMIC=$(dmesg 2>/dev/null | grep -c "raspberrypi-firmware.*status 0x80000001" || echo 0)
echo "PMIC error count: $PMIC"
if [ "$PMIC" -gt 0 ]; then
    echo "LAST 5 ERRORS:"
    dmesg | grep "raspberrypi-firmware.*status 0x80000001" | tail -5
fi

# ── 15. SERVICES ──────────────────────────────────────────
echo ""
echo "$SEPARATOR"
echo "15. CRITICAL SERVICES"
echo "$SEPARATOR"
for svc in ssh docker containerd cron NetworkManager systemd-timesyncd hermes-gateway; do
    STATUS=$(systemctl is-active $svc 2>/dev/null || echo "not-found")
    if [ "$STATUS" = "active" ]; then
        echo "✅ $svc: $STATUS"
    else
        echo "❌ $svc: $STATUS"
    fi
done

# ── 16. RECENT KERNEL ERRORS ──────────────────────────────
echo ""
echo "$SEPARATOR"
echo "16. RECENT KERNEL ERRORS (this boot)"
echo "$SEPARATOR"
ERRORS=$(dmesg --level=err,warn 2>/dev/null | tail -15)
if [ -n "$ERRORS" ]; then
    echo "$ERRORS"
else
    echo "(none — clean)"
fi

# ── 17. PREVIOUS BOOT ERRORS ──────────────────────────────
echo ""
echo "$SEPARATOR"
echo "17. PREVIOUS BOOT ERRORS (journal)"
echo "$SEPARATOR"
sudo journalctl -p err -b -1 --no-pager --lines=10 2>/dev/null || echo "unavailable"

# ── 18. FREEZE WATCHDOG STATUS ────────────────────────────
echo ""
echo "$SEPARATOR"
echo "18. FREEZE WATCHDOG STATUS"
echo "$SEPARATOR"
if [ -f /var/tmp/pi-freeze-heartbeat.txt ]; then
    echo "Last heartbeat:"
    cat /var/tmp/pi-freeze-heartbeat.txt
    AGE=$(($(date +%s) - $(grep "^heartbeat=" /var/tmp/pi-freeze-heartbeat.txt | cut -d= -f2)))
    echo "Heartbeat age: ${AGE}s"
else
    echo "No heartbeat file — watchdog not running?"
fi

# ── 19. FREEZE HISTORY ────────────────────────────────────
echo ""
echo "$SEPARATOR"
echo "19. FREEZE DETECTION HISTORY"
echo "$SEPARATOR"
if [ -f /var/tmp/pi-freeze-history.log ]; then
    tail -10 /var/tmp/pi-freeze-history.log
else
    echo "No freeze history"
fi

# ── 20. WATCHDOG & REBOOT CONFIG ──────────────────────────
echo ""
echo "$SEPARATOR"
echo "20. WATCHDOG & REBOOT CONFIG"
echo "$SEPARATOR"
echo "Hardware watchdog: $(cat /sys/class/watchdog/watchdog0/identity 2>/dev/null || echo 'none')"
echo "Watchdog state: $(cat /sys/class/watchdog/watchdog0/state 2>/dev/null || echo 'unknown')"
echo "systemd RuntimeWatchdog: $(systemctl show -p RuntimeWatchdogUSec 2>/dev/null | cut -d= -f2)"
echo "systemd RebootWatchdog: $(systemctl show -p RebootWatchdogUSec 2>/dev/null | cut -d= -f2)"
echo "Kernel panic timeout: $(sysctl -n kernel.panic 2>/dev/null || echo 'unknown')"

echo ""
echo "══════════════════════════════════════════════════════════════"
echo "  SNAPSHOT COMPLETE — $(date -Is)"
echo "══════════════════════════════════════════════════════════════"