# Hermes Cron Jobs

## Freeze Heartbeat — every 1 minute

**Schedule**: `every 1m`
**Script**: `pi-freeze-watchdog.sh heartbeat`
**Deliver**: `local` (no delivery, writes to /var/tmp)
**Mode**: `no-agent` (script runs directly, no LLM)

This is the fastest defense against silent hard freezes. Writes a heartbeat timestamp + 15 key metrics every 60 seconds to `/var/tmp/pi-freeze-heartbeat.txt`. On next boot, `pi-reboot-debug` detects stale heartbeat (>120s) and runs full forensics.

```
hermes cron create "every 1m" \
  --name "Pi Freeze Heartbeat" \
  --script /home/pi/.hermes/scripts/pi-freeze-watchdog.sh \
  --deliver local \
  --no-agent
```

---

## Health Monitor — every 10 minutes

**Schedule**: `*/10 * * * *`
**Skill**: `pi-health-monitor`
**Deliver**: `origin` (Telegram DM)

**Prompt**:
```
You are the Pi 5 health monitor. Run the pi-health-monitor skill procedure:

1. Read /home/pi/.hermes/pi-state.yaml and /var/tmp/pi-health-state.json
2. Check ALL 20 metrics: temperature, network, disk, inodes, RAM, swap, load avg, I/O wait, D-state, zombies, process count, file descriptors, GPU memory, PMIC errors, throttling, critical services, NVMe SMART, file integrity, Hermes gateway health
3. Every ~30 min: NVMe SMART + file integrity + run backup-critical-files.sh
4. Compare with previous state — detect TRANSITIONS only (ok->problem, problem->ok)
5. Apply thresholds from pi-state.yaml for each metric
6. Send Telegram alerts on state transitions only. Max 1 alert per 15 min per type.
7. If network down: queue reports to /var/tmp/pi-health-pending-reports.txt
8. Update /var/tmp/pi-health-state.json
```

```
hermes cron create "*/10 * * * *" \
  --name "Pi Health Monitor (10min)" \
  --skill pi-health-monitor \
  --deliver origin
```

---

## Daily Briefing — 8:00 AM Paris time

**Schedule**: `0 8 * * *`
**Deliver**: `origin` (Telegram DM)

**Prompt**:
```
You are an assistant preparing a daily morning briefing. Deliver a concise, structured summary for Telegram:

1. Today's weather in Paris — min/max temp, conditions, clothing recommendation
2. Top headlines — 4-6 important stories, mix France and international
3. Today's note — public holiday, notable event (optional)

Format: concise Markdown (< 1500 chars), neutral but warm tone.
End with "_Bonne journee !_ ☕"
```

```
hermes cron create "0 8 * * *" \
  --name "Briefing matinal 8h" \
  --deliver origin
```

---

## Hermes CLI Commands

```bash
# Create freeze heartbeat
hermes cron create "every 1m" \
  --name "Pi Freeze Heartbeat" \
  --script /home/pi/.hermes/scripts/pi-freeze-watchdog.sh \
  --deliver local \
  --no-agent

# Create health monitor
hermes cron create "*/10 * * * *" \
  --name "Pi Health Monitor (10min)" \
  --skill pi-health-monitor \
  --deliver origin

# Create daily briefing
hermes cron create "0 8 * * *" \
  --name "Briefing matinal 8h" \
  --deliver origin

# List all jobs
hermes cron list

# Run a job manually
hermes cron run <job-id>

# View job details
hermes cron show <job-id>

# Pause / Resume
hermes cron pause <job-id>
hermes cron resume <job-id>

# Remove
hermes cron remove <job-id>
```