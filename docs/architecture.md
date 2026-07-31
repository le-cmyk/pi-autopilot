# Architecture — Pi Autopilot

## System Overview

Pi Autopilot is a layered self-healing system for Raspberry Pi 5 built on top of Hermes Agent. Each layer operates independently and can fail without taking down the others.

```
LAYER 0: HARDWARE
  └── BCM2835 Watchdog Timer (60s timeout)
      └── Systemd RuntimeWatchdogSec=1min
      └── Kernel panic → reboot (kernel.panic=10)

LAYER 1: BOOT-TIME RECOVERY
  └── hermes-reboot-debug.service (systemd oneshot)
      └── Triggers on every boot, after network-online.target
      └── Skill: pi-reboot-debug
          ├── Reads pre-crash health state
          ├── Diagnoses cause (OOM/thermal/undervoltage/panic)
          ├── Restores critical services
          └── Reports to Telegram (or caches if offline)

LAYER 2: RUNTIME MONITORING
  └── Cron job every 10 min
      └── Skill: pi-health-monitor
          ├── Temperature (vcgencmd measure_temp)
          ├── Network (ping 8.8.8.8 + nmcli recovery)
          ├── Disk space (df -h /)
          ├── RAM (free -m)
          ├── Critical services (systemctl is-active)
          ├── NVMe SMART (nvme smart-log, every 30 min)
          ├── File integrity (SHA256 vs backup manifest)
          └── Auto-backup (hourly snapshots)

LAYER 3: SCHEDULED TASKS
  └── Daily briefing (8:00 AM Paris)
      └── Weather + news headlines → Telegram
```

## State Management

### Static State (`pi-state.yaml`)
Immutable configuration: thresholds, critical services, known issues, recovery procedures. Read by both skills at startup.

### Runtime State (`/var/tmp/pi-health-state.json`)
Ephemeral state updated every 10 min: current metrics, outage tracking, temperature trends, NVMe counters. Survives service restarts but not reboots.

### Pending Reports (`/var/tmp/pi-health-pending-reports.txt`)
Queue for Telegram messages when network is down. Flushed automatically when connectivity returns.

### Backups (`~/.hermes/backups/`)
- `*.bak` — latest copy of each critical file
- `critical-files.sha256` — integrity manifest
- `snapshots/hermes-backup-*.tar.gz` — hourly tarballs (24 retained)

## Alert Escalation

```
Minor (log only)          Warning (Telegram)       Critical (Urgent)
─────────────────        ─────────────────        ─────────────────
Temp 75-80°C              Temp 80-85°C              Temp >85°C
Disk 85-90%               Disk 90-95%               Disk >95%
Unsafe shutdowns +1       Mem <200 MB               Mem <100 MB
                          File hash changed          Service down
                          NVMe spare <20%            NVMe media_errors >0
                                                     File MISSING
                                                     NVMe critical_warning
```

## Network Outage Handling

```
NETWORK DOWN detected
  → Record outage start time
  → Recovery ladder:
      1. nmcli device connect wlan0
      2. systemctl restart NetworkManager
      3. ip link set wlan0 down/up
  → Queue all reports to pending-reports.txt
  → Continue local monitoring

NETWORK UP detected (after outage)
  → Calculate outage duration
  → Build recovery report (duration + state during outage)
  → Flush ALL pending reports
  → Reset outage tracking
```

## File Integrity

Every 30 minutes:
1. Compute SHA256 of critical files
2. Compare with backup manifest
3. If mismatch → alert (possible post-crash corruption)
4. If file MISSING → urgent alert + restore from `.bak`
5. Run backup to capture current state

## Design Principles

1. **No single point of failure** — each layer works independently
2. **Graceful degradation** — network down? Cache locally. Hermes down? Systemd watchdog still works.
3. **Minimal noise** — alerts only on state TRANSITIONS, not every check
4. **Self-documenting** — state file is the source of truth for what's running
5. **Replayable** — all config is in version control, can reproduce on any Pi 5