#!/bin/bash
# Hermes Gateway Crash Handler
# Called by systemd ExecStopPost= when Hermes gateway exits
# Logs crash details, updates health state, queues recovery if needed

set -euo pipefail

CRASH_LOG="/var/tmp/hermes-crash.log"
CRASH_COUNT_FILE="/var/tmp/hermes-crash-count.txt"
HEALTH_STATE="/var/tmp/pi-health-state.json"
PENDING_REPORTS="/var/tmp/pi-health-pending-reports.txt"
CRASH_THRESHOLD=5          # Reboot + alert after this many crashes in WINDOW
CRASH_WINDOW_SECONDS=600   # 10 minute window

TIMESTAMP=$(date -Is)

# Read exit code from systemd (set in ExecStopPost via $EXIT_CODE)
# Exit codes:
#   0       = normal exit (service stopped)
#   143     = SIGTERM (killed by systemd stop or --replace takeover)
#   1       = application error
#   137     = SIGKILL
#   unknown = couldn't determine
EXIT_CODE="${EXIT_CODE:-unknown}"

# Skip counting for normal exits (0 = clean stop, 143 = SIGTERM from --replace or systemd stop)
if [ "$EXIT_CODE" = "0" ]; then
    echo "[$TIMESTAMP] Hermes gateway stopped normally (exit=0) — not a crash" >> "$CRASH_LOG"
    exit 0
fi
if [ "$EXIT_CODE" = "143" ]; then
    echo "[$TIMESTAMP] Hermes gateway killed by SIGTERM (exit=143) — likely --replace takeover or service stop" >> "$CRASH_LOG"
    exit 0
fi

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

# Crash loop detected → REBOOT the Pi
if [ "$COUNT" -ge "$CRASH_THRESHOLD" ]; then
    REBOOT_MSG="🚨 *CRITICAL: Hermes crash loop detected — rebooting Pi*
• $COUNT crashes in $(($WINDOW_AGE / 60)) min
• Last exit code: $EXIT_CODE
• Time: $TIMESTAMP
• Rebooting now to recover system stability..."

    echo "$REBOOT_MSG" >> "$PENDING_REPORTS"
    echo "[$TIMESTAMP] CRITICAL: $COUNT crashes in window — triggering safe reboot" >> "$CRASH_LOG"

    # Try to send Telegram alert before rebooting
    if command -v hermes &>/dev/null && ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
        hermes send --to telegram "$REBOOT_MSG" 2>/dev/null || true
    fi

    # Use safe reboot script or fallback to direct reboot
    if [ -f /home/pi/reboot ]; then
        /home/pi/reboot "hermes crash loop: $COUNT crashes in $(($WINDOW_AGE / 60)) min"
    else
        sync
        sudo reboot
    fi
fi

# If systemd restarts Hermes (which it will in 5s), the health monitor
# will pick up the pending reports when Hermes is back online
echo "[$TIMESTAMP] Crash handler complete — systemd will restart Hermes" >> "$CRASH_LOG"