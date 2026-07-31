#!/bin/bash
# Pi Freeze Watchdog — Detects HARD freezes that prevent kernel logging
# Writes a heartbeat timestamp every 60 seconds (cron runs every 1 min).
# On boot, checks if the heartbeat is stale → hard freeze detected.
#
# Two modes:
#   1) heartbeat  — run every 60s via cron to write timestamp + full snapshot
#   2) check      — run on boot (via hermes-reboot-debug) to detect stale heartbeat
#
# Files (ALL on NVMe, survive power loss):
#   /var/tmp/pi-freeze-heartbeat.txt  — last heartbeat: timestamp + key metrics
#   /var/tmp/pi-freeze-snap-marker.txt — last pre-freeze snapshot time
#   /var/tmp/pi-freeze-pre-dump.txt    — rolling pre-freeze diagnostic snapshot (every 2 min)
#   /var/tmp/pi-freeze-history.log     — freeze detection history

set -euo pipefail

MODE="${1:-heartbeat}"
HEARTBEAT_FILE="/var/tmp/pi-freeze-heartbeat.txt"
HISTORY_FILE="/var/tmp/pi-freeze-history.log"
PRE_DUMP_FILE="/var/tmp/pi-freeze-pre-dump.txt"
STATE_FILE="/var/tmp/pi-health-state.json"
TIMESTAMP=$(date -Is)
EPOCH=$(date +%s)

# ── HEARTBEAT MODE ──────────────────────────────────────────
if [ "$MODE" = "heartbeat" ]; then
    # Collect all metrics in one shot — lightweight, under 50ms
    UPTIME_SEC=$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo 0)
    LOAD_1M=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo 0)
    LOAD_5M=$(awk '{print $2}' /proc/loadavg 2>/dev/null || echo 0)
    TEMP=$(vcgencmd measure_temp 2>/dev/null | grep -oP '[0-9.]+' || echo 0)
    MEM_FREE=$(free -m | awk 'NR==2 {print $7}')
    MEM_AVAIL=$(free -m | awk 'NR==2 {print $NF}')
    SWAP_USED=$(free -m | awk 'NR==3 {print $3}')
    DMESG_TAIL=$(dmesg | tail -1 | cut -c1-120 | tr '\n' ' ')
    D_STATE=$(ps aux 2>/dev/null | awk '$8 ~ /D/ {count++} END {print count+0}')
    ZOMBIES=$(ps aux 2>/dev/null | awk '$8 ~ /Z/ {count++} END {print count+0}')
    PROC_COUNT=$(ps aux 2>/dev/null | wc -l)
    FD_COUNT=$(cat /proc/sys/fs/file-nr 2>/dev/null | awk '{print $1}' || echo 0)
    PMIC_ERRORS=$(dmesg 2>/dev/null | grep -c "raspberrypi-firmware.*status 0x80000001" || echo 0)
    THROTTLED=$(vcgencmd get_throttled 2>/dev/null | grep -oP '0x[0-9a-f]+' || echo "0x0")

    # Write heartbeat
    {
        echo "heartbeat=$EPOCH"
        echo "timestamp=$TIMESTAMP"
        echo "uptime=$UPTIME_SEC"
        echo "load_1m=$LOAD_1M"
        echo "load_5m=$LOAD_5M"
        echo "temp=$TEMP"
        echo "mem_free=$MEM_FREE"
        echo "mem_avail=$MEM_AVAIL"
        echo "swap_used=$SWAP_USED"
        echo "d_state_procs=$D_STATE"
        echo "zombies=$ZOMBIES"
        echo "proc_count=$PROC_COUNT"
        echo "fd_count=$FD_COUNT"
        echo "pmic_errors=$PMIC_ERRORS"
        echo "throttled=$THROTTLED"
        echo "dmesg_tail=$DMESG_TAIL"
    } > "$HEARTBEAT_FILE"

    # Rolling pre-freeze snapshot — every 2 minutes, heavier but still fast
    SNAP_MARKER="/var/tmp/pi-freeze-snap-marker.txt"
    LAST_SNAP=$(cat "$SNAP_MARKER" 2>/dev/null || echo 0)
    if [ $((EPOCH - LAST_SNAP)) -ge 120 ]; then
        echo "$EPOCH" > "$SNAP_MARKER"
        {
            echo "=== PRE-FREEZE SNAPSHOT @ $TIMESTAMP ==="
            echo ""
            echo "--- UPTIME ---"
            uptime
            echo ""
            echo "--- DMESG TAIL (last 40 lines) ---"
            dmesg | tail -40
            echo ""
            echo "--- PROCESSES IN D STATE (uninterruptible sleep) ---"
            ps aux | awk 'NR==1 || $8 ~ /D/ {print}'
            echo ""
            echo "--- ZOMBIE PROCESSES ---"
            ps aux | awk 'NR==1 || $8 ~ /Z/ {print}'
            echo ""
            echo "--- TOP (by CPU) ---"
            ps aux --sort=-%cpu | head -8
            echo ""
            echo "--- TOP (by RSS memory) ---"
            ps aux --sort=-%mem | head -8
            echo ""
            echo "--- MEMORY ---"
            free -h
            echo ""
            echo "--- I/O WAIT ---"
            top -bn1 | head -5
            echo ""
            echo "--- NETWORK ---"
            ip -4 addr show wlan0 2>/dev/null | grep inet || echo "wlan0: no IP"
            echo ""
            echo "--- NVMe I/O stats ---"
            cat /sys/block/nvme0n1/stat 2>/dev/null || echo "nvme stat unavailable"
            echo ""
            echo "--- GPU MEMORY ---"
            vcgencmd get_mem gpu 2>/dev/null || echo "gpu mem unavailable"
            echo ""
            echo "--- PMIC FIRMWARE ERROR COUNT ---"
            dmesg 2>/dev/null | grep -c "raspberrypi-firmware.*status 0x80000001" || echo 0
            echo ""
            echo "--- OPEN FILE DESCRIPTORS ---"
            cat /proc/sys/fs/file-nr 2>/dev/null || echo "unavailable"
            echo ""
            echo "--- INODE USAGE ---"
            df -i / 2>/dev/null || echo "unavailable"
            echo ""
            echo "--- KERNEL OOM HISTORY ---"
            dmesg | grep -i "oom\|killed process" | tail -10
            echo ""
            echo "--- THROTTLING ---"
            vcgencmd get_throttled 2>/dev/null || echo "unavailable"
        } > "$PRE_DUMP_FILE"
    fi

    # Update health state with key metrics
    if [ -f "$STATE_FILE" ]; then
        python3 -c "
import json
try:
    with open('$STATE_FILE') as f:
        state = json.load(f)
    state['freeze_heartbeat_ts'] = $EPOCH
    state['freeze_heartbeat_uptime'] = $UPTIME_SEC
    state['swap_used_mb'] = $SWAP_USED
    state['d_state_procs'] = $D_STATE
    state['zombies'] = $ZOMBIES
    state['proc_count'] = $PROC_COUNT
    state['fd_count'] = $FD_COUNT
    state['pmic_errors'] = $PMIC_ERRORS
    state['throttled'] = '$THROTTLED'
    state['load_1m'] = $LOAD_1M
    with open('$STATE_FILE', 'w') as f:
        json.dump(state, f)
except: pass
" 2>/dev/null || true
    fi

    exit 0
fi

# ── CHECK MODE (run on boot) ──────────────────────────────
if [ "$MODE" = "check" ]; then
    mkdir -p "$(dirname "$HISTORY_FILE")"

    if [ ! -f "$HEARTBEAT_FILE" ]; then
        echo "[$TIMESTAMP] No heartbeat file found — first boot or watchdog never ran" >> "$HISTORY_FILE"
        echo "FREEZE_CHECK: no_heartbeat_file"
        exit 0
    fi

    # Parse all heartbeat fields
    parse_field() {
        grep "^${1}=" "$HEARTBEAT_FILE" 2>/dev/null | cut -d= -f2- || echo "?"
    }
    LAST_HEARTBEAT=$(parse_field "heartbeat")
    LAST_UPTIME=$(parse_field "uptime")
    LAST_TEMP=$(parse_field "temp")
    LAST_MEM=$(parse_field "mem_free")
    LAST_SWAP=$(parse_field "swap_used")
    LAST_DSTATE=$(parse_field "d_state_procs")
    LAST_ZOMBIES=$(parse_field "zombies")
    LAST_PROCS=$(parse_field "proc_count")
    LAST_FD=$(parse_field "fd_count")
    LAST_PMIC=$(parse_field "pmic_errors")
    LAST_THROTTLED=$(parse_field "throttled")
    LAST_LOAD=$(parse_field "load_1m")
    LAST_DMESG=$(parse_field "dmesg_tail")

    if [ -z "$LAST_HEARTBEAT" ] || [ "$LAST_HEARTBEAT" = "0" ]; then
        echo "[$TIMESTAMP] Invalid heartbeat data" >> "$HISTORY_FILE"
        echo "FREEZE_CHECK: invalid_data"
        exit 0
    fi

    CURRENT_UPTIME=$(awk '{print int($1)}' /proc/uptime)
    AGE=$((EPOCH - LAST_HEARTBEAT))

    # Check if it was a planned reboot
    PLANNED=false
    if [ -f "$STATE_FILE" ]; then
        PLANNED=$(python3 -c "import json; d=json.load(open('$STATE_FILE')); print(d.get('planned_reboot', False))" 2>/dev/null || echo "False")
    fi

    if [ "$PLANNED" = "True" ]; then
        echo "[$TIMESTAMP] Planned reboot — heartbeat $AGE seconds old (uptime: $CURRENT_UPTIME s) — no freeze" >> "$HISTORY_FILE"
        echo "FREEZE_CHECK: planned_reboot,heartbeat_age=$AGE"
        exit 0
    fi

    # Heartbeat older than 2 minutes = likely hard freeze (cron runs every 1 min)
    if [ "$AGE" -gt 120 ]; then
        echo "[$TIMESTAMP] 🔴 HARD FREEZE DETECTED: heartbeat $AGE seconds stale" >> "$HISTORY_FILE"
        echo "  --- Pre-freeze state from heartbeat ---" >> "$HISTORY_FILE"
        echo "  uptime=${LAST_UPTIME}s  temp=${LAST_TEMP}°C  mem_free=${LAST_MEM}MB  swap_used=${LAST_SWAP}MB" >> "$HISTORY_FILE"
        echo "  load_1m=$LAST_LOAD  d_state=$LAST_DSTATE  zombies=$LAST_ZOMBIES  procs=$LAST_PROCS" >> "$HISTORY_FILE"
        echo "  fd_count=$LAST_FD  pmic_errors=$LAST_PMIC  throttled=$LAST_THROTTLED" >> "$HISTORY_FILE"
        echo "  last_dmesg: $LAST_DMESG" >> "$HISTORY_FILE"
        echo "  current_uptime: ${CURRENT_UPTIME}s" >> "$HISTORY_FILE"

        if [ -f "$PRE_DUMP_FILE" ]; then
            echo "  pre-freeze snapshot: $PRE_DUMP_FILE ($(wc -l < "$PRE_DUMP_FILE") lines)" >> "$HISTORY_FILE"
        fi

        # Build a structured summary line for the reboot-debug agent to parse
        echo "FREEZE_CHECK: hard_freeze,heartbeat_age=$AGE,last_uptime=$LAST_UPTIME,d_state=$LAST_DSTATE,temp=$LAST_TEMP,swap=$LAST_SWAP,zombies=$LAST_ZOMBIES,load=$LAST_LOAD,pmic=$LAST_PMIC,throttled=$LAST_THROTTLED"
    elif [ "$AGE" -gt 90 ]; then
        echo "[$TIMESTAMP] ⚠️ Possible freeze: heartbeat $AGE seconds old (borderline)" >> "$HISTORY_FILE"
        echo "FREEZE_CHECK: possible_freeze,heartbeat_age=$AGE"
    else
        echo "[$TIMESTAMP] Normal: heartbeat $AGE seconds old (within expected range)" >> "$HISTORY_FILE"
        echo "FREEZE_CHECK: normal,heartbeat_age=$AGE"
    fi
fi