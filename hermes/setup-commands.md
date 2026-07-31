# Hermes Setup Commands

One-time setup commands to configure Hermes Agent for Pi Autopilot.

## Skills Installation

```bash
# Create the skills directory
mkdir -p ~/.hermes/skills/smart-home

# Copy skills from this repo
cp skills/pi-reboot-debug.md ~/.hermes/skills/smart-home/pi-reboot-debug/SKILL.md
cp skills/pi-health-monitor.md ~/.hermes/skills/smart-home/pi-health-monitor/SKILL.md
cp skills/pi-auto-reboot.md ~/.hermes/skills/smart-home/pi-auto-reboot/SKILL.md
cp skills/pi-autopilot.md ~/.hermes/skills/smart-home/pi-autopilot/SKILL.md
```

## Cron Jobs

```bash
# --- FREEZE HEARTBEAT: every 1 minute, no LLM ---
hermes cron create "every 1m" \
  --name "Pi Freeze Heartbeat" \
  --script /home/pi/.hermes/scripts/pi-freeze-watchdog.sh \
  --deliver local \
  --no-agent

# --- HEALTH MONITOR: every 10 minutes ---
hermes cron create "*/10 * * * *" \
  --name "Pi Health Monitor (10min)" \
  --skills pi-health-monitor \
  --deliver origin \
  --prompt "You are the Pi 5 health monitor. Run the full pi-health-monitor skill: read pi-state.yaml + health-state.json, check ALL 20 metrics (temp, network, disk, inodes, RAM, swap, load, iowait, D-state, zombies, procs, FD, GPU mem, PMIC, throttled, services, NVMe SMART, file integrity, gateway health), compare with previous state, alert on transitions only, queue if network down, update state JSON."

# --- DAILY BRIEFING: 8:00 AM Paris ---
hermes cron create "0 8 * * *" \
  --name "Briefing matinal 8h" \
  --deliver origin \
  --attach-to-session \
  --prompt "Prepare a concise morning briefing: Paris weather, 4-6 headlines France+world, notable info. Markdown <1500 chars. End with 'Bonne journee ! ☕'"

# Verify
hermes cron list
```

## Scripts Setup

```bash
# Copy all scripts
cp scripts/pi-freeze-watchdog.sh ~/.hermes/scripts/
cp scripts/pi-freeze-forensics.sh ~/.hermes/scripts/
cp scripts/pi-reboot-check.sh ~/.hermes/scripts/
cp scripts/backup-critical-files.sh ~/.hermes/scripts/
cp scripts/hermes-crash-handler.sh ~/.hermes/scripts/
cp scripts/pi-health-snapshot.sh ~/.hermes/scripts/
chmod +x ~/.hermes/scripts/*.sh

# Safe reboot script
cp scripts/reboot ~/reboot
chmod +x ~/reboot

# Backup directory
mkdir -p ~/.hermes/backups/snapshots

# Run first backup
bash ~/.hermes/scripts/backup-critical-files.sh
```

## Config Files

```bash
# Pi state (master config)
cp config/pi-state.yaml ~/.hermes/pi-state.yaml

# WiFi powersave off
sudo mkdir -p /etc/NetworkManager/conf.d
sudo cp config/networkmanager/wifi-powersave-off.conf /etc/NetworkManager/conf.d/

# Journal persistence
sudo mkdir -p /etc/systemd/journald.conf.d
sudo cp config/journald/override.conf /etc/systemd/journald.conf.d/
sudo mkdir -p /var/log/journal
sudo systemctl restart systemd-journald

# Kernel cmdline (NVMe ASPM off + fsck force — requires reboot)
# Verify: cat /boot/firmware/cmdline.txt includes:
#   pcie_aspm=off nvme_core.default_ps_max_latency_us=0 fsck.mode=force fsck.repair=yes
# If not, merge config/cmdline.txt changes and reboot.
```

## Systemd Services

```bash
# Hermes Gateway auto-restart
sudo cp systemd/hermes-gateway.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now hermes-gateway

# Post-reboot diagnostics
sudo cp systemd/hermes-reboot-debug.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable hermes-reboot-debug
```

## Verification

```bash
# Check all cron jobs
hermes cron list

# Verify freeze watchdog is writing heartbeats
cat /var/tmp/pi-freeze-heartbeat.txt
# Should have heartbeat=<epoch> with 15+ fields

# Run full health snapshot
bash ~/.hermes/scripts/pi-health-snapshot.sh

# Check watchdog is active
cat /sys/class/watchdog/watchdog0/state  # must say "active"

# Check kernel panic auto-reboot
sysctl kernel.panic  # must be 10

# Check journal persistence
sudo journalctl --list-boots | wc -l  # should show multiple boots

# Check services
systemctl status hermes-gateway hermes-reboot-debug

# Check NVMe SMART
sudo nvme smart-log /dev/nvme0 | grep -E "critical_warning|available_spare|media_errors|unsafe_shutdowns"

# Check bootloader
sudo rpi-eeprom-update  # must be "up to date"
```