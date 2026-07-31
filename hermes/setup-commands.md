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
```

## Cron Jobs

```bash
# Health monitor — every 10 minutes
hermes cron create "*/10 * * * *" \
  --name "Pi Health Monitor (10min)" \
  --skills pi-health-monitor \
  --deliver origin \
  --prompt "Tu es le moniteur de santé du Raspberry Pi 5. Exécute la procédure complète du skill pi-health-monitor. Lis d'abord /home/pi/.hermes/pi-state.yaml, puis vérifie température, réseau, disque, RAM, services, NVMe SMART, intégrité fichiers. Mets à jour /var/tmp/pi-health-state.json. Alerte Telegram uniquement sur TRANSITION d'état. Si réseau down, cache les rapports."

# Daily briefing — 8:00 AM
hermes cron create "0 8 * * *" \
  --name "Briefing matinal 8h" \
  --deliver origin \
  --attach-to-session \
  --prompt "Prépare un briefing matinal concis : météo Paris, 4-6 titres d'actualité France+monde, info du jour si pertinent. Format Markdown <1500 chars. Termine par 'Bonne journée ! ☕'"

# Verify
hermes cron list
```

## Scripts Setup

```bash
# Safe reboot script
cp scripts/reboot ~/reboot
chmod +x ~/reboot

# Backup script
mkdir -p ~/.hermes/scripts ~/.hermes/backups/snapshots
cp scripts/backup-critical-files.sh ~/.hermes/scripts/
chmod +x ~/.hermes/scripts/backup-critical-files.sh

# Run first backup
bash ~/.hermes/scripts/backup-critical-files.sh
```