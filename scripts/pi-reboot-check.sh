#!/bin/bash
# Pi Reboot Debug — runs on every boot via systemd
# Invokes Hermes Agent to diagnose crash cause, restore services, report to Telegram
#
# Handles offline mode: agent caches reports to /var/tmp/pi-health-pending-reports.txt
# if network is down. pi-health-monitor will flush them when network returns.
#
# Log: journalctl -u hermes-reboot-debug

set -euo pipefail

LOG_TAG="hermes-reboot-debug"
HERMES="/home/pi/.local/bin/hermes"
STATE_FILE="/home/pi/.hermes/pi-state.yaml"
PENDING_REPORTS="/var/tmp/pi-health-pending-reports.txt"
MAX_WAIT=30  # max seconds to wait for network (agent handles offline gracefully)

log() {
    echo "[$(date '+%H:%M:%S')] $*" | systemd-cat -t "$LOG_TAG" -p info
}

log "=== Starting post-reboot diagnostics ==="

# Quick network check — don't wait forever, agent will handle offline
log "Checking network..."
NETWORK_UP=false
for i in $(seq 1 $MAX_WAIT); do
    if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
        log "Network is up after ${i}s"
        NETWORK_UP=true
        break
    fi
    if [ $i -eq $MAX_WAIT ]; then
        log "Network not available after ${MAX_WAIT}s — agent will cache reports locally"
    fi
    sleep 1
done

# Check if there are pending reports from before the crash
if [ -f "$PENDING_REPORTS" ] && [ -s "$PENDING_REPORTS" ]; then
    PENDING_COUNT=$(wc -l < "$PENDING_REPORTS")
    log "Found $PENDING_COUNT pending report(s) from before crash"
fi

# Verify state file exists
if [ ! -f "$STATE_FILE" ]; then
    log "WARNING: State file not found at $STATE_FILE"
fi

# Run Hermes agent with the pi-reboot-debug skill
# --oneshot (-z): print only the final response, no UI
# -Q: quiet mode (no spinner, no tool previews)
log "Launching Hermes agent for diagnostics..."
DIAG_OUTPUT=$(
    $HERMES -z "The Pi just rebooted. Run the full pi-reboot-debug skill procedure:
        1. Read /home/pi/.hermes/pi-state.yaml and /var/tmp/pi-health-state.json
        2. Determine reboot cause (check previous logs + health context)
        3. Verify and restore critical services
        4. If network is DOWN: cache report to /var/tmp/pi-health-pending-reports.txt
        5. If network is UP: send report to Telegram AND flush any pending reports" \
        --skills pi-reboot-debug \
        -Q \
        2>&1
) || {
    EXIT_CODE=$?
    log "Hermes agent exited with code $EXIT_CODE"
}

# Log the output
echo "$DIAG_OUTPUT" | systemd-cat -t "$LOG_TAG" -p info

# Fallback: if hermes failed, write a minimal report to /tmp
if [ -n "${EXIT_CODE:-}" ] && [ "${EXIT_CODE:-0}" -ne 0 ]; then
    FALLBACK="/tmp/reboot-fallback-$(date +%Y%m%d-%H%M%S).txt"
    {
        echo "🔄 Pi rebooted — Hermes diagnostic agent failed (exit $EXIT_CODE)"
        echo "Check logs: journalctl -u hermes-reboot-debug"
        echo "Manual diag: hermes chat -q --skills pi-reboot-debug 'Run pi diagnostics'"
    } > "$FALLBACK"
    log "Fallback report written to $FALLBACK"
fi

log "=== Post-reboot diagnostics complete ==="