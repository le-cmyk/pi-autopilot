#!/bin/bash
# Pi Freeze Forensics — Collects comprehensive diagnostics after a detected freeze
# Run manually or triggered by pi-reboot-debug when a hard freeze is detected.
#
# Usage: pi-freeze-forensics.sh [output_file]
#   output_file: defaults to /var/tmp/pi-freeze-forensics-<timestamp>.txt

set -euo pipefail

OUTPUT="${1:-/var/tmp/pi-freeze-forensics-$(date +%Y%m%d_%H%M%S).txt}"
TIMESTAMP=$(date -Is)
BOOT_ID=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo "unknown")

{
    echo "═══════════════════════════════════════════════════════════"
    echo "  PI FREEZE FORENSICS REPORT"
    echo "  Generated: $TIMESTAMP"
    echo "  Boot ID: $BOOT_ID"
    echo "═══════════════════════════════════════════════════════════"
    echo ""

    # ── 1. FREEZE WATCHDOG DATA ──────────────────────────────
    echo "─── FREEZE WATCHDOG ───"
    if [ -f /var/tmp/pi-freeze-heartbeat.txt ]; then
        echo "Last heartbeat (before crash):"
        cat /var/tmp/pi-freeze-heartbeat.txt
    else
        echo "No heartbeat data available"
    fi
    echo ""

    if [ -f /var/tmp/pi-freeze-history.log ]; then
        echo "Freeze history (last 20 entries):"
        tail -20 /var/tmp/pi-freeze-history.log
    fi
    echo ""

    # ── 2. PRE-FREEZE SNAPSHOT ───────────────────────────────
    echo "─── PRE-FREEZE SNAPSHOT ───"
    if [ -f /var/tmp/pi-freeze-pre-dump.txt ]; then
        cat /var/tmp/pi-freeze-pre-dump.txt
    else
        echo "No pre-freeze snapshot available"
    fi
    echo ""

    # ── 3. CURRENT BOOT STATE ────────────────────────────────
    echo "─── CURRENT BOOT STATE ───"
    echo "Uptime: $(uptime)"
    echo "Boot time: $(who -b 2>/dev/null | awk '{print $3, $4}' || echo 'unknown')"
    echo ""

    # ── 4. KERNEL LOG (previous boot) ────────────────────────
    echo "─── PREVIOUS BOOT KERNEL LOG (last 80 lines) ───"
    sudo journalctl -b -1 -k --no-pager 2>/dev/null | tail -80 || echo "(journal unavailable)"
    echo ""

    echo "─── PREVIOUS BOOT ERRORS ───"
    sudo journalctl -b -1 -p err --no-pager 2>/dev/null | tail -40 || echo "(journal unavailable)"
    echo ""

    # ── 5. HARDWARE STATE ────────────────────────────────────
    echo "─── HARDWARE ───"
    echo "Temperature: $(vcgencmd measure_temp 2>/dev/null || echo 'N/A')"
    echo "Throttled: $(vcgencmd get_throttled 2>/dev/null || echo 'N/A')"
    echo "Voltage: $(vcgencmd measure_volts core 2>/dev/null || echo 'N/A')"
    echo ""

    echo "─── POWER ───"
    echo "PMIC errors (current boot): $(dmesg | grep -c 'status 0x80000001' || echo 0)"
    echo "Under-voltage: $(dmesg | grep -ci 'under-voltage' || echo 0)"
    echo ""

    echo "─── WiFi ───"
    echo "Power Management: $(iwconfig wlan0 2>/dev/null | grep 'Power Management' | awk '{print $4}' || echo 'N/A')"
    echo "Link Quality: $(iwconfig wlan0 2>/dev/null | grep 'Link Quality' | awk '{print $2}' || echo 'N/A')"
    echo "Firmware: $(dmesg | grep 'brcmfmac.*Firmware:' | tail -1 | sed 's/.*Firmware: //' || echo 'N/A')"
    echo ""

    echo "─── NVMe ───"
    sudo nvme smart-log /dev/nvme0 2>/dev/null | grep -E "unsafe_shutdowns|critical_warning|media_errors|available_spare|percentage_used|temperature|power_cycles|power_on" || echo "NVMe unavailable"
    echo ""
    echo "NVMe ASPM: $(sudo nvme get-feature -f 0x0c /dev/nvme0 2>/dev/null | head -1 || echo 'N/A')"
    echo ""

    # ── 6. MEMORY ────────────────────────────────────────────
    echo "─── MEMORY ───"
    free -h
    echo ""
    echo "OOM kills (previous boot):"
    sudo journalctl -b -1 --no-pager 2>/dev/null | grep -ci 'oom-kill\|Out of memory' || echo "0"
    echo ""

    # ── 7. STORAGE HEALTH ────────────────────────────────────
    echo "─── STORAGE ───"
    df -h /
    echo ""
    echo "Filesystem check status:"
    sudo tune2fs -l /dev/nvme0n1p2 2>/dev/null | grep -E "Filesystem state|Mount count|Maximum mount|Last checked" || echo "N/A"
    echo ""

    # ── 8. CRITICAL PROCESSES ────────────────────────────────
    echo "─── HERMES ───"
    systemctl status hermes-gateway 2>/dev/null | head -5 || echo "Service not found"
    echo ""
    if [ -f /var/tmp/hermes-crash.log ]; then
        echo "Recent crash log:"
        tail -15 /var/tmp/hermes-crash.log | grep -v '^\x00' || echo "(empty or binary)"
    fi
    echo ""

    echo "─── DOCKER ───"
    docker ps -a --format "table {{.Names}}\t{{.Status}}" 2>/dev/null || echo "Docker not available"
    echo ""

    # ── 9. CHRONOLOGY ────────────────────────────────────────
    echo "─── REBOOT HISTORY ───"
    last -x 2>/dev/null | head -20 || echo "N/A"
    echo ""

    # ── 10. SUMMARY ──────────────────────────────────────────
    echo "─── QUICK SUMMARY ───"
    echo "NVMe unsafe_shutdowns: $(sudo nvme smart-log /dev/nvme0 2>/dev/null | grep unsafe_shutdowns | awk '{print $3}' || echo '?')"
    
    FREEZE_COUNT=$(grep -c "HARD FREEZE" /var/tmp/pi-freeze-history.log 2>/dev/null || echo 0)
    echo "Hard freezes detected (total): $FREEZE_COUNT"

    # Classify likely cause
    echo ""
    echo "─── LIKELY CAUSE ANALYSIS ───"
    
    WIFI_POWERSAVE=$(iwconfig wlan0 2>/dev/null | grep "Power Management" | awk '{print $4}')
    if [ "$WIFI_POWERSAVE" = "on" ]; then
        echo "⚠️  WiFi Power Save is ON → PRIMARY SUSPECT"
    fi
    
    PMIC_COUNT=$(dmesg | grep -c 'status 0x80000001' 2>/dev/null || echo 0)
    if [ "$PMIC_COUNT" -gt 10 ]; then
        echo "⚠️  PMIC errors: $PMIC_COUNT → Update bootloader EEPROM"
    fi
    
    NVME_ASPM=$(sudo nvme get-feature -f 0x0c /dev/nvme0 2>/dev/null | grep "Current value" | grep -o "0x[0-9a-f]*")
    if [ "$NVME_ASPM" != "0x00000000" ] && [ -n "$NVME_ASPM" ]; then
        echo "⚠️  NVMe ASPM enabled ($NVME_ASPM) → Suspect PCIe power management"
    fi
    
    FIRMWARE_VER=$(dmesg | grep "brcmfmac.*Firmware:" | tail -1 | grep -oP 'version [0-9.]+' || echo "")
    FIRMWARE_DATE=$(dmesg | grep "brcmfmac.*Firmware:" | tail -1 | grep -oP '[A-Z][a-z]{2} [0-9]{1,2} [0-9]{4}' || echo "")
    if [ -n "$FIRMWARE_DATE" ]; then
        echo "ℹ️  WiFi firmware: $FIRMWARE_DATE $FIRMWARE_VER"
    fi
    
    D_STATE_PROCS=$(grep "^d_state_procs=" /var/tmp/pi-freeze-heartbeat.txt 2>/dev/null | cut -d= -f2 || echo "?")
    if [ "$D_STATE_PROCS" != "0" ] && [ "$D_STATE_PROCS" != "?" ]; then
        echo "⚠️  $D_STATE_PROCS process(es) in D (uninterruptible) state at last heartbeat"
    fi

    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "  END OF REPORT"
    echo "═══════════════════════════════════════════════════════════"

} > "$OUTPUT"

echo "Forensics report saved to: $OUTPUT"
echo "Lines: $(wc -l < "$OUTPUT")"

# Also save a copy to a well-known location for easy access
cp "$OUTPUT" /var/tmp/pi-last-forensics.txt

exit 0