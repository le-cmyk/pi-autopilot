#!/bin/bash
# Pi Autopilot — One-Shot Installer
# Installs all components: systemd service, scripts, skills, configs, cron jobs
# Run: curl -sSL <raw-url> | bash   OR   sudo bash install.sh
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*"; exit 1; }

echo ""
echo "🛡️  Pi Autopilot Installer"
echo "=========================="
echo ""

# --- Check we're on a Pi 5 ---
if ! grep -q "Raspberry Pi 5" /proc/device-tree/model 2>/dev/null; then
    warn "Not running on Raspberry Pi 5. Some features may not work."
fi

# --- Install system packages ---
log "Installing system packages..."
sudo apt-get update -qq
sudo apt-get install -y -qq nvme-cli smartmontools 2>/dev/null || warn "nvme-cli install failed (non-critical)"

# --- WiFi Power Save OFF (prevents Pi 5 freezes) ---
log "Disabling WiFi power saving..."
sudo mkdir -p /etc/NetworkManager/conf.d
cat << 'EOF' | sudo tee /etc/NetworkManager/conf.d/wifi-powersave-off.conf > /dev/null
[connection]
wifi.powersave = 2
EOF

# --- Persistent Journal ---
log "Enabling persistent journal..."
sudo mkdir -p /etc/systemd/journald.conf.d
cat << 'EOF' | sudo tee /etc/systemd/journald.conf.d/override.conf > /dev/null
[Journal]
Storage=persistent
EOF
sudo mkdir -p /var/log/journal
sudo systemctl restart systemd-journald 2>/dev/null || true

# --- Deploy scripts ---
log "Deploying scripts..."
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p ~/.hermes/scripts ~/.hermes/backups/snapshots

cp "$REPO_DIR/scripts/reboot" ~/reboot 2>/dev/null || warn "reboot script not found"
cp "$REPO_DIR/scripts/backup-critical-files.sh" ~/.hermes/scripts/ 2>/dev/null || warn "backup script not found"
cp "$REPO_DIR/scripts/pi-reboot-check.sh" ~/.hermes/scripts/ 2>/dev/null || warn "pi-reboot-check not found"
chmod +x ~/reboot ~/.hermes/scripts/*.sh 2>/dev/null || true

# --- Deploy skills ---
log "Deploying Hermes skills..."
SKILLS_DIR=~/.hermes/skills/smart-home
mkdir -p "$SKILLS_DIR"

for skill in pi-reboot-debug pi-health-monitor pi-auto-reboot; do
    if [ -f "$REPO_DIR/skills/${skill}.md" ]; then
        mkdir -p "$SKILLS_DIR/$skill"
        cp "$REPO_DIR/skills/${skill}.md" "$SKILLS_DIR/$skill/SKILL.md"
        log "  $skill"
    else
        warn "  $skill (not found — skipping)"
    fi
done

# --- Deploy state file (if not already present) ---
if [ ! -f ~/.hermes/pi-state.yaml ]; then
    if [ -f "$REPO_DIR/config/pi-state.yaml" ]; then
        cp "$REPO_DIR/config/pi-state.yaml" ~/.hermes/pi-state.yaml
        log "State file deployed (edit ~/.hermes/pi-state.yaml to customize)"
    fi
else
    log "State file already exists (preserved)"
fi

# --- Deploy systemd service ---
log "Deploying systemd service..."
if [ -f "$REPO_DIR/systemd/hermes-reboot-debug.service" ]; then
    sudo cp "$REPO_DIR/systemd/hermes-reboot-debug.service" /etc/systemd/system/
    sudo systemctl daemon-reload
    sudo systemctl enable hermes-reboot-debug 2>/dev/null || warn "Could not enable service"
    log "  hermes-reboot-debug.service enabled"
fi

# --- Initial backup ---
log "Running initial backup..."
bash ~/.hermes/scripts/backup-critical-files.sh 2>/dev/null || warn "Backup script failed"

# --- Apply WiFi powersave immediately ---
sudo iwconfig wlan0 power off 2>/dev/null || true

echo ""
echo "=========================="
log "Installation complete!"
echo ""
echo "Next steps:"
echo "  1. Edit ~/.hermes/pi-state.yaml with your Pi's specifics"
echo "  2. Create cron jobs (see hermes/setup-commands.md)"
echo "  3. Reboot: ~/reboot 'pi-autopilot setup'"
echo ""
echo "Verify after reboot:"
echo "  - iwconfig wlan0 | grep 'Power Management'  # should say 'off'"
echo "  - systemctl status hermes-reboot-debug       # should be enabled"
echo "  - ls /var/log/journal/\$(cat /etc/machine-id)/*.journal  # persistent journal"
echo "  - hermes cron list                            # cron jobs running"
echo ""