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
FALLBACK_DIR="/var/tmp"  # NVMe-backed, survives power loss

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

# ─── FREEZE DETECTION CHECK ────────────────────────────────────
FREEZE_WATCHDOG="/home/pi/.hermes/scripts/pi-freeze-watchdog.sh"
if [ -x "$FREEZE_WATCHDOG" ]; then
    log "Running freeze watchdog check..."
    FREEZE_RESULT=$(bash "$FREEZE_WATCHDOG" check 2>&1) || true
    log "Freeze check: $FREEZE_RESULT"

    # If hard freeze detected, run full forensics
    if echo "$FREEZE_RESULT" | grep -q "hard_freeze"; then
        log "HARD FREEZE DETECTED — running forensics..."
        FORENSICS_SCRIPT="/home/pi/.hermes/scripts/pi-freeze-forensics.sh"
        if [ -x "$FORENSICS_SCRIPT" ]; then
            bash "$FORENSICS_SCRIPT" 2>&1 | systemd-cat -t "$LOG_TAG" -p info || true
            log "Forensics saved to /var/tmp/pi-last-forensics.txt"
        fi
    fi
else
    log "Freeze watchdog not found — skipping freeze check"
fi

# Verify state file exists
if [ ! -f "$STATE_FILE" ]; then
    log "WARNING: State file not found at $STATE_FILE"
fi

# ─── HERMES AGENT DIAGNOSTICS ─────────────────────────────────
# Use -q (--query) for the prompt and --quiet to suppress UI/banner
log "Launching Hermes agent for diagnostics..."
DIAG_OUTPUT=""
EXIT_CODE=0

if [ -x "$HERMES" ]; then
    DIAG_OUTPUT=$(
        "$HERMES" chat \
            --query "The Pi just rebooted. Run the full pi-reboot-debug skill procedure:
                1. Read /home/pi/.hermes/pi-state.yaml and /var/tmp/pi-health-state.json
                2. Determine reboot cause (check previous logs + health context)
                3. Verify and restore critical services
                4. If network is DOWN: cache report to /var/tmp/pi-health-pending-reports.txt
                5. If network is UP: send report to Telegram AND flush any pending reports" \
            --skills pi-reboot-debug \
            --quiet \
            2>&1
    ) || EXIT_CODE=$?
else
    log "Hermes binary not found at $HERMES"
    EXIT_CODE=127
fi

# Log the output
if [ -n "$DIAG_OUTPUT" ]; then
    echo "$DIAG_OUTPUT" | systemd-cat -t "$LOG_TAG" -p info
fi

# Fallback: if hermes failed, write a report to /var/tmp (NVMe, survives power loss)
if [ "$EXIT_CODE" -ne 0 ]; then
    FALLBACK="$FALLBACK_DIR/reboot-fallback-$(date +%Y%m%d-%H%M%S).txt"
    {
        echo "🔄 Pi rebooted — Hermes diagnostic agent failed (exit $EXIT_CODE)"
        echo "Time: $(date -Is)"
        echo "Uptime: $(uptime)"
        echo "Network: $($NETWORK_UP && echo 'UP' || echo 'DOWN')"
        echo ""
        echo "Check logs: journalctl -u hermes-reboot-debug --no-pager -n 100"
        echo "Manual diag: hermes chat -q --skills pi-reboot-debug 'Run pi diagnostics'"
        echo ""
        echo "Freeze check result: ${FREEZE_RESULT:-not run}"
        echo "Pending reports: ${PENDING_COUNT:-0}"
    } > "$FALLBACK"
    log "Fallback report written to $FALLBACK"
fi

log "=== Post-reboot diagnostics complete (exit=$EXIT_CODE) ==="