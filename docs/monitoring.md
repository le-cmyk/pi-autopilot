# Monitoring Reference

## Health Checks

Every 10 minutes, the `pi-health-monitor` skill runs all checks below. Every 1 minute, the freeze watchdog writes a heartbeat with a subset of key metrics. All state files are on NVMe ext4 (/var/tmp) — they survive power loss.

### Temperature (`vcgencmd measure_temp`)
| Threshold | Action |
|---|---|
| >= 75 C | Log warning |
| >= 80 C | Telegram alert |
| >= 85 C | Urgent alert (Pi throttles) |
| Drops < 75 C | Recovery report |

### Network (`ping -c 1 -W 3 8.8.8.8`)
| State | Action |
|---|---|
| UP -> DOWN | Record outage start, attempt recovery |
| DOWN -> UP | Recovery report + flush pending reports |
| Recovery ladder | `nmcli connect wlan0` -> `restart NetworkManager` -> `ip link reset` |

### Disk (`df -h /`)
| Threshold | Action |
|---|---|
| > 85% | Log warning |
| > 90% | Telegram alert |
| > 95% | Urgent alert |

### Inodes (`df -i /`)
| Threshold | Action |
|---|---|
| > 85% | Telegram alert (many small files) |
| > 95% | Urgent (can't create files) |

### RAM (`free -m`)
| Threshold | Action |
|---|---|
| < 200 MB available | Telegram alert |
| < 100 MB available | Urgent alert (OOM imminent) |

### Swap (`free -m`)
| Threshold | Action |
|---|---|
| > 512 MB used | Telegram alert (memory pressure building) |
| > 1024 MB used | Warning (heavy swap) |
| > 1800 MB used | Urgent (OOM killer imminent, 2GB swap nearly full) |
| Drops < 512 MB | Recovery report |

### Load Average (`/proc/loadavg` — 1-min, relative to 4 cores)
| Threshold | Action |
|---|---|
| > 3.0 | Log warning (75% of cores) |
| > 4.5 | Telegram alert (processes waiting for CPU) |
| > 8.0 | Urgent (2x cores — system overloaded) |

### I/O Wait (`top -bn1` — %wa)
| Threshold | Action |
|---|---|
| > 10% | Log warning (processes blocked on disk) |
| > 25% | Telegram alert (severe I/O bottleneck — check NVMe) |
| > 50% | Urgent (system is I/O-bound, apps frozen) |

### D-State Processes (uninterruptible sleep — `ps aux | awk '$8 ~ /D/'`)
| Threshold | Action |
|---|---|
| > 3 | Log warning (show which processes) |
| > 10 | Telegram alert (I/O hang or NVMe stall) |
| > 20 | Urgent (system-wide I/O stall) |

### Zombie Processes (`ps aux | awk '$8 ~ /Z/'`)
| Threshold | Action |
|---|---|
| > 10 | Telegram alert (leaking child processes) |
| > 50 | Urgent (PID space exhaustion risk) |

### Process Count (`ps aux | wc -l`)
| Threshold | Action |
|---|---|
| > 400 | Log warning |
| > 800 | Telegram alert (possible fork bomb or container leak) |

### File Descriptors (`/proc/sys/fs/file-nr`)
| Threshold | Action |
|---|---|
| > 50,000 | Log warning |
| > 100,000 | Telegram alert (fd leak detected) |

### GPU Memory (`vcgencmd get_mem gpu`)
| Threshold | Action |
|---|---|
| > 128 MB | Log warning |
| > 256 MB | Telegram alert (display freeze risk) |

### PMIC Firmware Errors (`dmesg | grep -c "status 0x80000001"`)
| Threshold | Action |
|---|---|
| 1-5 per boot | Normal Pi 5 behavior with updated EEPROM — no alert |
| > 10 accumulating | Telegram alert (monitor closely) |
| > 100 | Urgent (PMIC error storm — update EEPROM immediately) |

### Critical Services
```
ssh docker containerd cron NetworkManager systemd-timesyncd hermes-gateway
```
Any DOWN -> `systemctl restart <svc>` -> alert if still down.

### NVMe SMART (`sudo nvme smart-log /dev/nvme0`) — every 30 min
| Metric | Warning | Critical |
|---|---|---|
| `critical_warning` | — | != 0 |
| `available_spare` | < 20% | < 10% |
| `media_errors` | — | > 0 |
| `unsafe_shutdowns` | +1 increase | — |
| `percentage_used` | > 80% | > 90% |

### File Integrity — every 30 min
| Check | Action |
|---|---|
| SHA256 matches backup | OK |
| SHA256 differs | Alert (possible corruption) |
| File MISSING | Urgent + restore from `.bak` |
| After any change | Run `backup-critical-files.sh` |

## Freeze Watchdog — every 1 minute

The freeze watchdog (`pi-freeze-watchdog.sh heartbeat`) writes a timestamp + key metrics every 60 seconds to `/var/tmp/pi-freeze-heartbeat.txt`. On boot, `pi-reboot-debug` checks if the heartbeat is > 120 seconds stale — if so, a HARD FREEZE was detected (the Pi froze without any kernel log).

### Heartbeat metrics captured
- uptime, load_1m, load_5m, temperature
- mem_free, mem_avail, swap_used
- d_state_procs, zombies, proc_count, fd_count
- pmic_errors, throttled flags
- dmesg tail (last kernel message before freeze)

### Pre-freeze snapshot — every 2 minutes
Full diagnostic dump saved to `/var/tmp/pi-freeze-pre-dump.txt`:
- dmesg tail (40 lines), D-state processes, zombie processes
- Top CPU and memory consumers
- Memory (free -h), I/O wait (top), network status, NVMe I/O stats
- GPU memory, PMIC error count, open file descriptors, inode usage
- Kernel OOM history, throttling flags

### Detection on boot
```
# Check if last boot ended in hard freeze
bash /home/pi/.hermes/scripts/pi-freeze-watchdog.sh check

# Full forensic report
bash /home/pi/.hermes/scripts/pi-freeze-forensics.sh
```

## Manual Checks

```bash
# Full comprehensive health snapshot (20 sections)
bash /home/pi/.hermes/scripts/pi-health-snapshot.sh

# Quick state read
cat /var/tmp/pi-health-state.json | python3 -m json.tool

# Temperature
vcgencmd measure_temp

# Throttling history
vcgencmd get_throttled
# 0x0 = never throttled
# 0x50000 = under-voltage occurred
# 0x50005 = throttled + under-voltage

# NVMe health
sudo nvme smart-log /dev/nvme0

# Freeze watchdog status
cat /var/tmp/pi-freeze-heartbeat.txt

# Freeze detection history
tail -20 /var/tmp/pi-freeze-history.log

# Pending reports (queued during network outage)
cat /var/tmp/pi-health-pending-reports.txt

# Backups
ls -la ~/.hermes/backups/
cat ~/.hermes/backups/critical-files.sha256

# Systemd service
systemctl status hermes-reboot-debug
journalctl -u hermes-reboot-debug --no-pager -n 30

# Cron jobs
hermes cron list
```

## Data Survivability

ALL monitoring data survives power loss (unplug):

| What | Where | Survives? |
|------|-------|-----------|
| System journal (20+ boots) | `/var/log/journal` (NVMe ext4) | Yes — `Storage=persistent` |
| Freeze heartbeat | `/var/tmp/pi-freeze-heartbeat.txt` (NVMe) | Yes |
| Pre-freeze snapshot | `/var/tmp/pi-freeze-pre-dump.txt` (NVMe) | Yes |
| Freeze history | `/var/tmp/pi-freeze-history.log` (NVMe) | Yes |
| Health state JSON | `/var/tmp/pi-health-state.json` (NVMe) | Yes |
| Crash log | `/var/tmp/hermes-crash.log` (NVMe) | Yes |
| Pending reports | `/var/tmp/pi-health-pending-reports.txt` (NVMe) | Yes |

Filesystem protection: `errors=remount-ro`, `commit=5`, `fsck.mode=force`, `fsck.repair=yes`, `tune2fs -c 5`.

## Telegram Alert Examples

```
🌡 Pi at 85 C — THROTTLING! Stop heavy containers.
⚠️ Pi at 82 C — check ventilation.
✅ Temperature dropped to 68 C.
🌐 Network DOWN since 12:35. Attempting recovery...
📡 Network restored after 2h15 outage.
💾 Disk at 91% — check logs.
📁 Inodes at 88% — many small files accumulating.
🧠 Free RAM: 145 MB — OOM killer possible.
🔄 Swap: 1200 MB used / 2048 MB — memory pressure.
⚡ Load 5.2 (4 cores) — processes waiting for CPU.
💽 I/O wait 30% — NVMe bottleneck.
🧊 12 processes stuck in D state — I/O hang.
👻 15 zombie processes — leaking children.
📈 850 processes — possible fork bomb.
📂 120K open FDs — fd leak detected.
🎮 GPU memory at 300 MB — display freeze risk.
⚡ 25 PMIC firmware errors accumulating.
🚨 NVMe media errors detected — backup immediately!
🔐 File config.yaml modified — possible post-crash corruption.
❌ Critical file missing: auth.json — restored from backup.
🔄 Pi rebooted. Cause: OOM killer. Services restored.
🔴 HARD FREEZE detected — heartbeat 340s stale. Pre-freeze snapshot available.
🛑 Hermes crash loop — reboot rate limit reached (3 reboots in 30 min).
```