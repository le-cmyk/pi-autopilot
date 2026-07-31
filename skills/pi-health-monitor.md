---
name: pi-health-monitor
description: "Pi5 health: temp, network, disk, RAM, swap, I/O, zombies, GPU, load, PMIC, NVMe, files. Alert and recover."
version: 1.2.0
platforms: [linux]
---

# Pi Health Monitor

Runs every 10 minutes via cron. Checks temperature, network connectivity, disk space, RAM, swap, load average, I/O wait, D-state/zombie processes, process count, file descriptors, GPU memory, PMIC firmware errors, NVMe SMART, file integrity, inode usage, and critical services. Sends Telegram alerts on state transitions. Queues reports locally when network is down.

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

# Disk + inode
DISK_PCT=$(df -h / | awk 'NR==2 {print $5}' | tr -d '%')
INODE_PCT=$(df -i / | awk 'NR==2 {print $5}' | tr -d '%')

# Memory + swap
MEM_FREE_MB=$(free -m | awk 'NR==2 {print $7}')
MEM_AVAIL_MB=$(free -m | awk 'NR==2 {print $NF}')
SWAP_USED_MB=$(free -m | awk 'NR==3 {print $3}')
SWAP_TOTAL_MB=$(free -m | awk 'NR==3 {print $2}')

# Load average
LOAD_1M=$(awk '{print $1}' /proc/loadavg)
LOAD_5M=$(awk '{print $2}' /proc/loadavg)

# I/O wait
IOWAIT=$(top -bn1 | awk '/Cpu/ {for(i=1;i<=NF;i++) if($i ~ /wa/) {gsub(/%/,"",$(i+1)); print $(i+1)}}' | head -1)

# D-state processes (uninterruptible sleep — stuck on I/O)
D_STATE=$(ps aux | awk '$8 ~ /D/ {count++} END {print count+0}')

# Zombie processes
ZOMBIES=$(ps aux | awk '$8 ~ /Z/ {count++} END {print count+0}')

# Process count
PROC_COUNT=$(ps aux | wc -l)

# Open file descriptors
FD_COUNT=$(cat /proc/sys/fs/file-nr 2>/dev/null | awk '{print $1}' || echo 0)

# GPU memory
GPU_MEM=$(vcgencmd get_mem gpu 2>/dev/null | grep -oP '[0-9]+' || echo 0)

# PMIC firmware errors (silent freeze cause #1)
PMIC_ERRORS=$(dmesg | grep -c "raspberrypi-firmware.*status 0x80000001" 2>/dev/null || echo 0)

# Throttling flags
THROTTLED=$(vcgencmd get_throttled 2>/dev/null | grep -oP '0x[0-9a-f]+' || echo "0x0")

# Critical services status
for svc in ssh docker containerd cron NetworkManager systemd-timesyncd hermes-gateway; do
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

### Step 5b — Swap monitoring

```
If SWAP_USED_MB > swap_used_alert_mb (1024):
  → Send alert: "🔄 Swap usage: X MB / Y MB — memory pressure building."
  → Show top memory consumers: ps aux --sort=-%mem | head -6
If SWAP_USED_MB > swap_used_critical_mb (1800):
  → Send urgent: "🚨 Swap nearly full — OOM killer imminent!"
  → Suggest: docker stop <heavy containers>, check for memory leaks

If SWAP_USED_MB drops from > 1024 to < 512:
  → Send recovery: "✅ Swap back to normal (X MB)."
```

### Step 5c — Load average & I/O wait

```
If LOAD_1M > load_warn (3.0):
  → Log warning, no alert yet (Pi 5 has 4 cores)
If LOAD_1M > load_alert (4.5):
  → Send alert: "⚡ Load: X.X — processes are waiting for CPU."
  → Show top CPU consumers: ps aux --sort=-%cpu | head -6
If LOAD_1M > load_critical (8.0):
  → Send urgent: "🚨 Load X.X — system severely overloaded!"

If IOWAIT > iowait_warn (10):
  → Log warning: "I/O wait at X% — processes blocked on disk."
If IOWAIT > iowait_alert (25):
  → Send alert: "💽 I/O wait X% — NVMe bottleneck? Check: iostat -x 1 3"
If IOWAIT > iowait_critical (50):
  → Send urgent: "🚨 I/O wait X% — system is I/O-bound, apps frozen!"
```

### Step 5d — D-state & zombie processes

```
If D_STATE > d_state_warn (3):
  → Log warning: "X processes in D state (uninterruptible sleep)."
  → Show which: ps aux | awk '$8 ~ /D/ {print}'
If D_STATE > d_state_alert (10):
  → Send alert: "🧊 X processes stuck in D state — possible I/O hang or NVMe stall."
If D_STATE > d_state_critical (20):
  → Send urgent: "🚨 X D-state processes — system-wide I/O stall! Check NVMe SMART."

If ZOMBIES > zombie_warn (10):
  → Send alert: "👻 X zombie processes — leaking child processes."
If ZOMBIES > zombie_alert (50):
  → Send urgent: "🚨 X zombies — PID space exhaustion risk."
```

### Step 5e — Process count & file descriptors

```
If PROC_COUNT > proc_count_warn (400):
  → Log: "X processes running."
If PROC_COUNT > proc_count_alert (800):
  → Send alert: "📈 X processes — possible fork bomb or container leak."

If FD_COUNT > fd_count_warn (50000):
  → Log: "X open file descriptors."
If FD_COUNT > fd_count_alert (100000):
  → Send alert: "📂 X open FDs — fd leak detected."
```

### Step 5f — GPU memory & PMIC firmware errors

```
If GPU_MEM > gpu_mem_warn_mb (128):
  → Log: "GPU using X MB."
If GPU_MEM > gpu_mem_alert_mb (256):
  → Send alert: "🎮 GPU memory at X MB — display freeze risk."

If PMIC_ERRORS > pmic_warn (10):
  → Send alert: "⚡ X PMIC firmware errors accumulating! Monitor closely."
If PMIC_ERRORS > pmic_alert (100):
  → Send urgent: "🚨 PMIC error storm: X errors! Old EEPROM or hardware issue."
  → Check: sudo rpi-eeprom-update
  → Note: 1-5 per boot is normal Pi 5 behavior with updated EEPROM
```

### Step 5g — Inode usage

```
If INODE_PCT > inode_warn_pct (85):
  → Send alert: "📁 Inodes at X% — running out of inodes (many small files)."
If INODE_PCT > inode_alert_pct (95):
  → Send urgent: "🚨 Inodes at X% — can't create files! Check: du --max-depth=1 / | sort -h"
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

### Step 2.5 — Hermes Gateway health

Check if the Hermes Gateway is alive and systemd-managed:
```bash
# Check systemd service status
HERMES_ACTIVE=$(systemctl is-active hermes-gateway 2>/dev/null || echo "not-found")
echo "hermes-gateway: $HERMES_ACTIVE"

# If running via systemd, check for recent crashes
if [ -f /var/tmp/hermes-crash.log ]; then
  RECENT_CRASHES=$(grep -c "HERMES_GATEWAY_EXIT" /var/tmp/hermes-crash.log 2>/dev/null || echo 0)
  echo "Recent crash events: $RECENT_CRASHES"
fi

# If running outside systemd (legacy), check process
if ! systemctl is-active --quiet hermes-gateway 2>/dev/null; then
  if pgrep -f "hermes_cli.main gateway" >/dev/null 2>&1; then
    echo "hermes: running (bare process — NOT systemd-managed ⚠️)"
  else
    echo "hermes: DOWN"
  fi
fi
```

```
If hermes-gateway service is "failed":
  → Alert: "🔴 Hermes Gateway service FAILED — systemd stopped restarting. Check: journalctl -u hermes-gateway -n 50"
  → Try: sudo systemctl reset-failed hermes-gateway && sudo systemctl restart hermes-gateway

If recent crash count increased since last check:
  → Alert: "⚠️ Hermes crashed X times in last window. Check: tail /var/tmp/hermes-crash.log"

If crash count >= 5 in 10 min window:
  → URGENT: "🚨 Hermes crash loop detected (X crashes in 10 min). Crash handler will AUTO-REBOOT the Pi."
  → Note: the crash handler (hermes-crash-handler.sh) handles the reboot + Telegram alert directly.
  → Health monitor only detects this for reporting purposes — the reboot is already triggered.

If hermes is running bare (not systemd) AND previous state was "systemd":
  → Warning: "⚠️ Hermes running outside systemd — auto-restart not active. Run: sudo systemctl start hermes-gateway"
```

Track in health state:
```json
"hermes_gateway": "running|failed|not-found|bare",
"hermes_crash_count_window": N,
"hermes_last_crash": "ISO timestamp or null"
```

### Step 8 — Service restoration

If any critical service is DOWN (including hermes-gateway):
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
  "inode_pct": 0,
  "mem_free_mb": 0,
  "mem_avail_mb": 0,
  "swap_used_mb": 0,
  "swap_total_mb": 2048,
  "load_1m": 0.0,
  "load_5m": 0.0,
  "iowait_pct": 0.0,
  "d_state_procs": 0,
  "zombies": 0,
  "proc_count": 0,
  "fd_count": 0,
  "gpu_mem_mb": 0,
  "pmic_errors": 0,
  "throttled": "0x0",
  "nvme_critical_warning": 0,
  "nvme_available_spare_pct": 0,
  "nvme_media_errors": 0,
  "nvme_unsafe_shutdowns": 0,
  "nvme_percentage_used": 0,
  "hermes_gateway": "running|failed|not-found|bare",
  "hermes_crash_count_window": N,
  "hermes_last_crash": "ISO timestamp or null",
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

1. **Minor** (temp 75-80, disk 85-90%, swap < 512MB, load < 3.0, iowait < 10, d_state <= 3, zombies < 10, fd < 50k, inode < 85%, unsafe_shutdowns +1) → log only
2. **Warning** (temp 80-85, disk 90-95%, mem < 200MB, swap > 512MB, load > 3.0, iowait > 10, d_state > 3, zombies > 10, proc > 400, gpu > 128MB, pmic > 10, file hash changed, spare < 20%, inode > 85%) → Telegram alert
3. **Critical** (temp > 85, disk > 95%, mem < 100MB, swap > 1GB, load > 4.5, iowait > 25, d_state > 10, zombies > 50, proc > 800, fd > 100k, gpu > 256MB, pmic > 100, inode > 95%, service down, spare < 10%, media_errors > 0, critical_warning != 0, file MISSING) → urgent Telegram + suggest action
4. **Recovery** (any metric returns to normal) → Telegram recovery report

## Pitfalls
- Don't flood Telegram — state transitions only
- Network recovery: try nmcli first, then restart NetworkManager, then reboot WiFi interface as last resort
- Temperature: the Pi 5 throttles at 85°C — alert before that
- **Swap**: rising swap usage is the #1 early warning of OOM. Track it trending upward between checks — even if below threshold, a steady increase is bad
- **I/O wait**: high iowait (>25%) with many D-state processes is the signature of a failing NVMe or PCIe issue. Check SMART immediately
- **D-state processes > 3**: something is stuck in kernel I/O. Not always a freeze, but if it's growing, it will become one
- **Zombies**: a few are normal (kernel cleans them quickly). A rising count means a parent process is broken and not reaping children — can exhaust PID space
- **PMIC errors**: the #1 silent-freeze cause. 1-5 per boot is normal with updated EEPROM. > 10 accumulating = watch closely. > 100 = storm, update EEPROM immediately
- **GPU mem**: Pi 5 GPU memory is dynamic — 256MB+ means something is holding GPU resources (display freeze risk)
- **FD count**: system-wide fd leaks are slow-burn killers. A gradual increase over hours/days points to a leaking service
- **Inodes**: running out of inodes is rare on 469G NVMe, but possible with millions of tiny files (npm/node_modules, Docker overlay2). Monitor the trend
- NVMe SMART: only check every 30 min (expensive), track unsafe_shutdowns trend
- File integrity: compare sha256 with backup manifest. If file changed but system is OK → it was a legitimate update. If file is MISSING → restore immediately
- Backups: run every ~30 min automatically. Check /home/pi/.hermes/backups/ for restores
- If state file is missing, use defaults
- **All state files survive power loss**: /var/tmp is on NVMe ext4 (NOT tmpfs). Heartbeat, health state, crash logs, pending reports — all persist across unplugs