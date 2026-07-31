---
name: pi-health-monitor
description: "Pi5 health: temp, network, disk, RAM. Alert and recover."
version: 1.1.0
platforms: [linux]
---

# Pi Health Monitor

Runs every 10 minutes via cron. Checks temperature, network connectivity, disk space, RAM, NVMe SMART, file integrity, and critical services. Sends Telegram alerts on state transitions. Queues reports locally when network is down.

## State files

```
/home/pi/.hermes/pi-state.yaml          # Static config (services, thresholds)
/var/tmp/pi-health-state.json           # Runtime state (last check, outage tracking)
/var/tmp/pi-health-pending-reports.txt  # Reports queued when network is down
```

## Procedure

### Step 1 — Read state

Always start by reading the static config:
```
read_file /home/pi/.hermes/pi-state.yaml
```

Then read the runtime state (create with empty defaults if missing):
```bash
cat /var/tmp/pi-health-state.json 2>/dev/null || echo '{"network":"unknown","network_down_since":null,"temp_status":"ok","temp_high_since":null,"last_ok_ts":null}'
```

### Step 2 — Collect current health

Run all checks and capture results:
```bash
# Temperature
TEMP=$(vcgencmd measure_temp 2>/dev/null | grep -oP '[0-9.]+' || echo "N/A")

# Network (fast check)
if ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then NETWORK="up"; else NETWORK="down"; fi

# Disk
DISK_PCT=$(df -h / | awk 'NR==2 {print $5}' | tr -d '%')

# Memory
MEM_FREE_MB=$(free -m | awk 'NR==2 {print $7}')

# Critical services status
for svc in ssh docker containerd cron NetworkManager systemd-timesyncd; do
  systemctl is-active --quiet $svc && echo "$svc: up" || echo "$svc: DOWN"
done

# NVMe SMART (every 30 min only — expensive)
LAST_SMART=$(stat -c %Y /var/tmp/pi-last-smart-check 2>/dev/null || echo 0)
NOW=$(date +%s)
if [ $((NOW - LAST_SMART)) -gt 1800 ]; then
  sudo nvme smart-log /dev/nvme0 2>/dev/null | grep -E "critical_warning|media_errors|available_spare|unsafe_shutdowns|percentage_used|temperature" > /var/tmp/pi-nvme-smart.txt
  touch /var/tmp/pi-last-smart-check
fi

# File integrity (every 30 min — compare sha256 with last backup)
if [ $((NOW - LAST_SMART)) -gt 1800 ]; then
  sha256sum /home/pi/.hermes/config.yaml /home/pi/.hermes/auth.json /home/pi/.hermes/pi-state.yaml > /var/tmp/pi-current-sha256.txt 2>/dev/null
fi
```

### Step 3 — Temperature handling

Thresholds from state file:
- `temp_warn: 75` — log warning, no alert
- `temp_alert: 80` — send Telegram alert
- `temp_critical: 85` — Pi will throttle, send urgent alert

```
If TEMP >= 85:
  → Send URGENT Telegram alert: "🌡 Pi at 85°C — THROTTLING! Stop heavy containers."
  → Suggest: docker stop <heavy containers>, check ventilation
If TEMP >= 80 and was previously < 80:
  → Send Telegram alert: "⚠️ Pi at X°C — check ventilation."
If TEMP >= 75:
  → Log warning, no Telegram (avoid noise)
If TEMP drops from >= 80 to < 75:
  → Send recovery report: "✅ Temperature dropped to X°C."
```

Track temperature state transitions in runtime state file.

### Step 4 — Network handling

```
If NETWORK is "down":
  → Record network_down_since if not already set
  → Try recovery: sudo nmcli device connect wlan0
  → If still down after 3 attempts: log, try again next cycle
  → Do NOT send Telegram (network is down!)
  → Every cycle while down: check pending-reports.txt, append status

If NETWORK transitions from "down" to "up":
  → Calculate outage duration from network_down_since
  → Build recovery report including:
    - Duration of outage
    - Temperature during outage (highest recorded)
    - Any service issues
  → Send recovery report via Telegram
  → Flush pending-reports.txt (send any queued reports)
  → Reset network_down_since to null
```

When network is down, the agent can still do everything locally — just can't send Telegram. Store reports in `/var/tmp/pi-health-pending-reports.txt` for delivery when network returns.

### Step 5 — Disk & memory

```
If DISK_PCT > 90:
  → Send alert: "💾 Disk at X%!"
If DISK_PCT > 95:
  → Send urgent: "🚨 Disk almost full — crash risk."

If MEM_FREE_MB < 200:
  → Send alert: "🧠 Free RAM: X MB — check processes."
If MEM_FREE_MB < 100:
  → Send urgent: "🚨 Critical RAM — OOM killer likely."
```

### Step 6 — NVMe SMART monitoring (every 30 min)

Read the last SMART output:
```bash
cat /var/tmp/pi-nvme-smart.txt 2>/dev/null
```

Check against thresholds from state file:
```
If critical_warning != 0:
  → URGENT: "🚨 NVMe SMART critical warning! Backup immediately."
If available_spare < 10%:
  → Alert: "💾 NVMe spare blocks at X% — drive wearing out."
If media_errors > 0:
  → URGENT: "🚨 NVMe media errors detected — data loss risk."
If unsafe_shutdowns increased since last check:
  → Warning: "⚡ Unsafe shutdowns: X → Y. Power unstable?"
  → Update state file with new count
If percentage_used > 90%:
  → Alert: "⏳ NVMe endurance at X% — plan replacement."
```

### Step 7 — File integrity check (every 30 min)

Compare current sha256 with last backup manifest:
```bash
diff /var/tmp/pi-current-sha256.txt /home/pi/.hermes/backups/critical-files.sha256 2>/dev/null
```

```
If any file hash differs:
  → Alert: "🔐 File modified: <filename>. Possible post-crash corruption."
  → Run backup script to capture new state: bash /home/pi/.hermes/scripts/backup-critical-files.sh
If any file is MISSING:
  → URGENT: "❌ Critical file missing: <filename>. Restoring from backup."
  → Restore: cp /home/pi/.hermes/backups/<file>.bak /home/pi/.hermes/<original_path>
```

### Step 8 — Service restoration

If any critical service is DOWN:
```
→ Try: sudo systemctl restart <service>
→ If still down after restart: send Telegram alert
→ If restored: note in report but don't alert (normal recovery)
```

### Step 9 — Update runtime state

Write updated state to `/var/tmp/pi-health-state.json`:
```json
{
  "network": "up|down",
  "network_down_since": "ISO timestamp or null",
  "network_recovery_attempts": N,
  "temp_status": "ok|warn|alert|critical",
  "temp_high_since": "ISO timestamp or null",
  "temp_peak": 0.0,
  "disk_pct": 0,
  "mem_free_mb": 0,
  "nvme_critical_warning": 0,
  "nvme_available_spare_pct": 0,
  "nvme_media_errors": 0,
  "nvme_unsafe_shutdowns": 0,
  "nvme_percentage_used": 0,
  "files_integrity_ok": true,
  "last_ok_ts": "ISO timestamp",
  "last_check_ts": "ISO timestamp"
}
```

### Step 10 — Run backups (every ~30 min passively)

Every ~30 minutes, also trigger the backup script:
```bash
LAST_BACKUP=$(stat -c %Y /home/pi/.hermes/backups/critical-files.sha256 2>/dev/null || echo 0)
NOW=$(date +%s)
if [ $((NOW - LAST_BACKUP)) -gt 1800 ]; then
  bash /home/pi/.hermes/scripts/backup-critical-files.sh
fi
```

### Step 11 — Telegram reporting rules

- **Only send when there's a state TRANSITION** (ok→problem, problem→ok). Don't spam.
- **During network outage**: queue reports locally, flush when back.
- **Rate limit**: max 1 alert per 15 min per type.
- **Format**: use Telegram Markdown, concise, actionable.

### Escalation ladder

1. **Minor** (temp 75-80, disk 85-90%, unsafe_shutdowns +1) → log only
2. **Warning** (temp 80-85, disk 90-95%, mem < 200MB, file hash changed, spare < 20%) → Telegram alert
3. **Critical** (temp > 85, disk > 95%, mem < 100MB, service down, spare < 10%, media_errors > 0, critical_warning != 0, file MISSING) → urgent Telegram + suggest action
4. **Recovery** (any metric returns to normal) → Telegram recovery report

## Pitfalls
- Don't flood Telegram — state transitions only
- Network recovery: try nmcli first, then restart NetworkManager, then reboot WiFi interface as last resort
- Temperature: the Pi 5 throttles at 85°C — alert before that
- NVMe SMART: only check every 30 min (expensive), track unsafe_shutdowns trend
- File integrity: compare sha256 with backup manifest. If file changed but system is OK → it was a legitimate update. If file is MISSING → restore immediately
- Backups: run every ~30 min automatically. Check /home/pi/.hermes/backups/ for restores
- If state file is missing, use defaults
- The agent has access to shell commands via terminal — use them directly