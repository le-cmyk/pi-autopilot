#!/bin/bash
# Pi Freeze Watchdog — Detects HARD freezes that prevent kernel logging
# Writes a heartbeat timestamp every 30 seconds.
# On boot, checks if the heartbeat is stale → hard freeze detected.
#
# Two modes:
#   1) heartbeat  — run every 30s via cron to write timestamp
#   2) check      — run on boot (via hermes-reboot-debug) to detect stale heartbeat
#
# Files:
#   /var/tmp/pi-freeze-heartbeat.txt  — last heartbeat timestamp
#   /var/tmp/pi-freeze-last-check.txt  — when freeze watchdog last ran
#   /var/tmp/pi-freeze-history.log     — freeze detection history
#   /var/tmp/pi-freeze-pre-dump.txt    — pre-freeze diagnostic snapshot

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
    # Write current timestamp + system snapshot
    {
        echo "heartbeat=$EPOCH"
        echo "timestamp=$TIMESTAMP"
        echo "uptime=$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo 0)"
        echo "load=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo 0)"
        echo "temp=$(vcgencmd measure_temp 2>/dev/null | grep -oP '[0-9.]+' || echo 0)"
        
        # Brief diagnostic snapshot — lightweight
        echo "dmesg_tail=$(dmesg | tail -1 | cut -c1-120)"
        echo "mem_free=$(free -m | awk 'NR==2 {print $7}')"
        
        # Check if any process is in D (uninterruptible sleep) state
        D_COUNT=$(ps aux 2>/dev/null | awk '$8 ~ /D/ {count++} END {print count+0}')
        echo "d_state_procs=$D_COUNT"
    } > "$HEARTBEAT_FILE"
    
    # Also save a rolling pre-freeze snapshot every 2 minutes (every 4th heartbeat)
    SNAP_MARKER="/var/tmp/pi-freeze-snap-marker.txt"
    LAST_SNAP=$(cat "$SNAP_MARKER" 2>/dev/null || echo 0)
    if [ $((EPOCH - LAST_SNAP)) -ge 120 ]; then
        echo "$EPOCH" > "$SNAP_MARKER"
        {
            echo "=== PRE-FREEZE SNAPSHOT @ $TIMESTAMP ==="
            echo "--- UPTIME ---"
            uptime
            echo "--- DMESG TAIL (last 30 lines) ---"
            dmesg | tail -30
            echo "--- PROCESSES IN D STATE ---"
            ps aux | awk '$8 ~ /D/ {print}'
            echo "--- TOP (by CPU) ---"
            ps aux --sort=-%cpu | head -8
            echo "--- MEMORY ---"
            free -h
            echo "--- NETWORK ---"
            ip -4 addr show wlan0 2>/dev/null | grep inet || echo "wlan0: no IP"
            echo "--- NVMe (if available) ---"
            cat /sys/block/nvme0n1/stat 2>/dev/null || echo "nvme stat unavailable"
        } > "$PRE_DUMP_FILE"
    fi

    # Update health state
    if [ -f "$STATE_FILE" ]; then
        python3 -c "
import json
try:
    with open('$STATE_FILE') as f:
        state = json.load(f)
    state['freeze_heartbeat_ts'] = $EPOCH
    state['freeze_heartbeat_uptime'] = $(awk '{print int($1)}' /proc/uptime)
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

    # Read last heartbeat
    LAST_HEARTBEAT=$(grep "^heartbeat=" "$HEARTBEAT_FILE" 2>/dev/null | cut -d= -f2 || echo 0)
    LAST_UPTIME=$(grep "^uptime=" "$HEARTBEAT_FILE" 2>/dev/null | cut -d= -f2 || echo 0)

    if [ -z "$LAST_HEARTBEAT" ] || [ "$LAST_HEARTBEAT" = "0" ]; then
        echo "[$TIMESTAMP] Invalid heartbeat data" >> "$HISTORY_FILE"
        echo "FREEZE_CHECK: invalid_data"
        exit 0
    fi

    # The Pi just booted — current uptime is roughly how long since boot
    CURRENT_UPTIME=$(awk '{print int($1)}' /proc/uptime)

    # Calculate how stale the heartbeat is
    # If the Pi froze, the heartbeat timestamp would be old
    # But we also need to account for normal shutdowns
    AGE=$((EPOCH - LAST_HEARTBEAT))

    # Read the pre-reboot health state to check if it was a planned reboot
    PLANNED=false
    if [ -f "$STATE_FILE" ]; then
        PLANNED=$(python3 -c "import json; d=json.load(open('$STATE_FILE')); print(d.get('planned_reboot', False))" 2>/dev/null || echo "False")
    fi

    # Determine freeze likelihood
    if [ "$PLANNED" = "True" ]; then
        echo "[$TIMESTAMP] Planned reboot — heartbeat $AGE seconds old (uptime: $CURRENT_UPTIME s) — no freeze" >> "$HISTORY_FILE"
        echo "FREEZE_CHECK: planned_reboot,heartbeat_age=$AGE"
        exit 0
    fi

    # Heartbeat older than 2 minutes = likely hard freeze
    # (cron runs every 1 min, so 2 min without heartbeat = 2 missed cron runs)
    if [ "$AGE" -gt 120 ]; then
        # Classify severity
        D_STATE=$(grep "^d_state_procs=" "$HEARTBEAT_FILE" 2>/dev/null | cut -d= -f2 || echo "?")
        LAST_UPTIME_CAPTURED=$(grep "^uptime=" "$HEARTBEAT_FILE" 2>/dev/null | cut -d= -f2 || echo 0)
        LAST_TEMP=$(grep "^temp=" "$HEARTBEAT_FILE" 2>/dev/null | cut -d= -f2 || echo "?")
        LAST_MEM=$(grep "^mem_free=" "$HEARTBEAT_FILE" 2>/dev/null | cut -d= -f2 || echo "?")
        LAST_DMESG=$(grep "^dmesg_tail=" "$HEARTBEAT_FILE" 2>/dev/null | cut -d= -f2- || echo "?")

        echo "[$TIMESTAMP] 🔴 HARD FREEZE DETECTED: heartbeat $AGE seconds stale" >> "$HISTORY_FILE"
        echo "  Last heartbeat: uptime=${LAST_UPTIME_CAPTURED}s, temp=${LAST_TEMP}°C, mem_free=${LAST_MEM}MB, d_state=${D_STATE}" >> "$HISTORY_FILE"
        echo "  Last dmesg: $LAST_DMESG" >> "$HISTORY_FILE"
        echo "  Current uptime: ${CURRENT_UPTIME}s" >> "$HISTORY_FILE"
        
        # Save pre-freeze dump if available
        if [ -f "$PRE_DUMP_FILE" ]; then
            echo "  Pre-freeze snapshot available: $PRE_DUMP_FILE ($(wc -l < "$PRE_DUMP_FILE") lines)" >> "$HISTORY_FILE"
        fi

        echo "FREEZE_CHECK: hard_freeze,heartbeat_age=$AGE,last_uptime=$LAST_UPTIME_CAPTURED,d_state=$D_STATE,temp=$LAST_TEMP"
    elif [ "$AGE" -gt 90 ]; then
        echo "[$TIMESTAMP] ⚠️ Possible freeze: heartbeat $AGE seconds old (borderline)" >> "$HISTORY_FILE"
        echo "FREEZE_CHECK: possible_freeze,heartbeat_age=$AGE"
    else
        echo "[$TIMESTAMP] Normal: heartbeat $AGE seconds old (within expected range)" >> "$HISTORY_FILE"
        echo "FREEZE_CHECK: normal,heartbeat_age=$AGE"
    fi
fi