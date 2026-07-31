#!/bin/bash
# Backup critical Hermes files + create integrity manifest
# Run: /home/pi/.hermes/scripts/backup-critical-files.sh
# Called by pi-health-monitor every 30 min

set -euo pipefail

BACKUP_DIR="/home/pi/.hermes/backups"
MANIFEST="$BACKUP_DIR/critical-files.sha256"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

# Critical files that must exist and be intact
CRITICAL_FILES=(
    "/home/pi/.hermes/config.yaml"
    "/home/pi/.hermes/auth.json"
    "/home/pi/.hermes/.env"
    "/home/pi/.hermes/pi-state.yaml"
    "/home/pi/.hermes/platforms/pairing/telegram-approved.json"
    "/home/pi/.hermes/skills/smart-home/pi-health-monitor/SKILL.md"
    "/home/pi/.hermes/skills/smart-home/pi-reboot-debug/SKILL.md"
    "/home/pi/.hermes/skills/smart-home/pi-autopilot/SKILL.md"
    "/home/pi/.hermes/scripts/pi-reboot-check.sh"
    "/home/pi/.hermes/scripts/hermes-crash-handler.sh"
    "/etc/systemd/system/hermes-gateway.service"
)

mkdir -p "$BACKUP_DIR"

# 1. Create fresh backups
for f in "${CRITICAL_FILES[@]}"; do
    if [ -f "$f" ]; then
        BASENAME=$(basename "$f")
        cp "$f" "$BACKUP_DIR/${BASENAME}.bak"
    fi
done

# 2. Generate integrity manifest (sha256)
> "$MANIFEST"
for f in "${CRITICAL_FILES[@]}"; do
    if [ -f "$f" ]; then
        sha256sum "$f" >> "$MANIFEST"
    else
        echo "MISSING $f" >> "$MANIFEST"
    fi
done

# 3. Timestamped snapshot (keep last 24, hourly)
SNAPSHOT_DIR="$BACKUP_DIR/snapshots"
mkdir -p "$SNAPSHOT_DIR"
tar -czf "$SNAPSHOT_DIR/hermes-backup-$TIMESTAMP.tar.gz" \
    -C /home/pi/.hermes \
    config.yaml auth.json .env pi-state.yaml \
    2>/dev/null || true

# Cleanup old snapshots (keep last 24)
ls -t "$SNAPSHOT_DIR"/hermes-backup-*.tar.gz 2>/dev/null | tail -n +25 | xargs rm -f 2>/dev/null || true

echo "Backup complete: $(date) — $(ls $SNAPSHOT_DIR/*.tar.gz 2>/dev/null | wc -l) snapshots retained"