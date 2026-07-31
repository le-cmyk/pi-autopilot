#!/bin/bash
# Hermes Gateway Crash Handler
# Called by systemd ExecStopPost= when Hermes gateway exits
# Logs crash details, updates health state, queues recovery if needed

set -euo pipefail

CRASH_LOG="/var/tmp/hermes-crash.log"
CRASH_COUNT_FILE="/var/tmp/hermes-crash-count.txt"
HEALTH_STATE="/var/tmp/pi-health-state.json"
PENDING_REPORTS="/var/tmp/pi-health-pending-reports.txt"
CRASH_THRESHOLD=5          # Alert after this many crashes in WINDOW
CRASH_WINDOW_SECONDS=600   # 10 minute window
REBOOT_THRESHOLD=10        # Auto-reboot if this many crashes in WINDOW

TIMESTAMP=$(date -Is)

# Read exit code from the log (written by ExecStopPost)
EXIT_CODE=$(tail -1 "$CRASH_LOG" 2>/dev/null | grep -oP 'code=\K[0-9]+' || echo "unknown")

# Increment crash counter
mkdir -p "$(dirname "$CRASH_COUNT_FILE")"
if [ -f "$CRASH_COUNT_FILE" ]; then
    # Parse: count last_reset_timestamp
    read -r COUNT LAST_RESET < "$CRASH_COUNT_FILE" 2>/dev/null || { COUNT=0; LAST_RESET=0; }
else
    COUNT=0
    LAST_RESET=$(date +%s)
fi

NOW=$(date +%s)
WINDOW_AGE=$((NOW - LAST_RESET))

# Reset counter if window expired
if [ "$WINDOW_AGE" -gt "$CRASH_WINDOW_SECONDS" ]; then
    COUNT=0
    LAST_RESET=$NOW
fi

COUNT=$((COUNT + 1))
echo "$COUNT $LAST_RESET" > "$CRASH_COUNT_FILE"

echo "[$TIMESTAMP] Hermes gateway crashed (exit=$EXIT_CODE) — crash #$COUNT in window" >> "$CRASH_LOG"

# Update health state JSON
if [ -f "$HEALTH_STATE" ]; then
    python3 -c "
import json, sys
try:
    with open('$HEALTH_STATE') as f:
        state = json.load(f)
except Exception:
    state = {}
state['hermes_gateway'] = 'down'
state['hermes_last_crash'] = '$TIMESTAMP'
state['hermes_crash_count_window'] = $COUNT
state['hermes_last_exit_code'] = '$EXIT_CODE'
with open('$HEALTH_STATE', 'w') as f:
    json.dump(state, f, indent=2)
" 2>/dev/null || true
fi

# Queue crash report for next Hermes agent run
CRASH_REPORT="⚠️ *Hermes Gateway crashed*
• Exit code: $EXIT_CODE
• Crash #$COUNT in last $(($WINDOW_AGE / 60)) min
• Time: $TIMESTAMP
• Systemd will auto-restart in 5 seconds"

echo "$CRASH_REPORT" >> "$PENDING_REPORTS"

# Critical: too many crashes → queue reboot suggestion
if [ "$COUNT" -ge "$REBOOT_THRESHOLD" ]; then
    echo "🚨 *CRITICAL:* Hermes crashed $COUNT times in $(($WINDOW_AGE / 60)) min. Possible system instability — consider reboot." >> "$PENDING_REPORTS"
    echo "[$TIMESTAMP] CRITICAL: $COUNT crashes in window — reboot threshold reached" >> "$CRASH_LOG"
elif [ "$COUNT" -ge "$CRASH_THRESHOLD" ]; then
    echo "⚠️ Hermes crashed $COUNT times in $(($WINDOW_AGE / 60)) min — if it continues, a reboot may be needed." >> "$PENDING_REPORTS"
fi

# If systemd restarts Hermes (which it will in 5s), the health monitor
# will pick up the pending reports when Hermes is back online
echo "[$TIMESTAMP] Crash handler complete — systemd will restart Hermes" >> "$CRASH_LOG"