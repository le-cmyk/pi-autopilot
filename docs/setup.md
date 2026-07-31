# Setup Guide — Pi Autopilot

## Prerequisites

- Raspberry Pi 5 running Debian 13+ or Raspberry Pi OS
- NVMe SSD recommended (SD cards wear out with persistent journal)
- Hermes Agent v0.19+ installed and configured with Telegram
- Official Raspberry Pi 5 power supply (5V/5A)

## Step 1: Base System Hardening

```bash
# Update everything
sudo apt update && sudo apt upgrade -y

# Install monitoring tools
sudo apt install -y nvme-cli smartmontools

# Disable WiFi power saving (critical — prevents freezes)
sudo mkdir -p /etc/NetworkManager/conf.d
cat << 'EOF' | sudo tee /etc/NetworkManager/conf.d/wifi-powersave-off.conf
[connection]
wifi.powersave = 2
EOF

# Enable persistent journal (Raspbian defaults to volatile)
sudo mkdir -p /etc/systemd/journald.conf.d
cat << 'EOF' | sudo tee /etc/systemd/journald.conf.d/override.conf
[Journal]
Storage=persistent
EOF
sudo mkdir -p /var/log/journal
sudo systemctl restart systemd-journald

# Update bootloader EEPROM (fixes PMIC communication errors)
sudo rpi-eeprom-update -a
# Reboot after this: sudo reboot
```

## Step 2: Install Hermes Skills

```bash
# Copy skills to Hermes
mkdir -p ~/.hermes/skills/smart-home
cp skills/pi-reboot-debug.md ~/.hermes/skills/smart-home/pi-reboot-debug/SKILL.md
cp skills/pi-health-monitor.md ~/.hermes/skills/smart-home/pi-health-monitor/SKILL.md
cp skills/pi-auto-reboot.md ~/.hermes/skills/smart-home/pi-auto-reboot/SKILL.md
```

## Step 3: Deploy State File

```bash
# Edit the template with your Pi's specifics (IP, services, thresholds)
cp config/pi-state.yaml ~/.hermes/pi-state.yaml
# Customize:
nano ~/.hermes/pi-state.yaml
```

## Step 4: Deploy Systemd Service

```bash
sudo cp systemd/hermes-reboot-debug.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable hermes-reboot-debug
```

## Step 5: Deploy Scripts

```bash
cp scripts/reboot ~/reboot
cp scripts/backup-critical-files.sh ~/.hermes/scripts/
chmod +x ~/reboot ~/.hermes/scripts/backup-critical-files.sh
```

## Step 6: Create Cron Jobs in Hermes

See `hermes/cron-jobs.md` for the exact prompts. Run these commands:

```bash
# Health monitor — every 10 minutes
hermes cron create "*/10 * * * *" \
  --name "Pi Health Monitor" \
  --skill pi-health-monitor \
  --prompt "$(cat hermes/cron-jobs.md | sed -n '/HEALTH_MONITOR_PROMPT/,/^---/p' | tail -n +2 | head -n -1)"

# Daily briefing — 8:00 AM
hermes cron create "0 8 * * *" \
  --name "Briefing matinal" \
  --prompt "$(cat hermes/cron-jobs.md | sed -n '/BRIEFING_PROMPT/,/^---/p' | tail -n +2 | head -n -1)"
```

## Step 7: Initial Backup

```bash
mkdir -p ~/.hermes/backups/snapshots
bash ~/.hermes/scripts/backup-critical-files.sh
```

## Step 8: Reboot & Verify

```bash
~/reboot "pi-autopilot setup complete"
```

After reboot, check:
```bash
# Journal persistent?
ls /var/log/journal/$(cat /etc/machine-id)/*.journal

# WiFi powersave off?
iwconfig wlan0 | grep "Power Management"  # should say "off"

# Bootloader current?
sudo rpi-eeprom-update  # should say "up to date"

# Systemd service loaded?
systemctl status hermes-reboot-debug

# Health monitor cron running?
hermes cron list
```

## Customizing for Your Pi

Edit `~/.hermes/pi-state.yaml`:
- Change `hostname`, `network.ip`, `network.gateway`, `network.dns`
- Add/remove `critical_services` based on what runs on your Pi
- Adjust `thresholds` if your Pi runs hotter/cooler
- Add `known_issues` specific to your setup

## Uninstalling

```bash
sudo systemctl disable --now hermes-reboot-debug
sudo rm /etc/systemd/system/hermes-reboot-debug.service
hermes cron remove <job-id>  # for each job
rm -rf ~/.hermes/skills/smart-home/pi-*
rm ~/.hermes/scripts/backup-critical-files.sh
rm ~/reboot
```