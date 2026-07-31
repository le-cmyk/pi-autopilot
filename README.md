# 🛡️ Pi Autopilot — Raspberry Pi 5 Self-Healing System

**Production-grade autonomous monitoring, crash recovery, and self-healing for Raspberry Pi 5, powered by [Hermes Agent](https://github.com/NousResearch/hermes-agent).**

[![Raspberry Pi 5](https://img.shields.io/badge/Pi-5%20Model%20B-red)](https://www.raspberrypi.com/products/raspberry-pi-5/)
[![Hermes Agent](https://img.shields.io/badge/Hermes-v0.19.0-blue)](https://github.com/NousResearch/hermes-agent)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

## What It Does

Your Pi runs itself. This system handles:

| Capability | How |
|---|---|
| 🔄 **Auto-reboot on freeze** | Hardware watchdog (systemd) + kernel panic handler |
| ❄️ **Hard freeze detection** | Filesystem heartbeat (every 1 min) captures 16 pre-freeze metrics. Stale heartbeat on boot = hard freeze detected |
| 🔍 **Crash forensics** | Post-reboot agent diagnoses cause, restores services, includes pre-freeze snapshot |
| 🩺 **Full-stack monitoring** | 20 metrics every 10 min: temp, network, disk, inodes, RAM, swap, load, I/O wait, D-state, zombies, procs, FDs, GPU mem, PMIC errors, throttling, services, NVMe SMART, file integrity, gateway health |
| 💾 **Data survivability** | All state/heartbeat/crash logs on NVMe ext4 — survive power loss. Persistent journal (20+ boots preserved) |
| 🌐 **Network outage recovery** | Auto-reconnect ladder, cached reports, flush on restore |
| 📲 **Telegram alerts** | State transitions only — no spam. 20 alert types |
| 📦 **Config backups** | Hourly snapshots + SHA256 integrity manifest |
| ☕ **Daily briefing** | Weather + news every morning at 8am |
| 🧠 **Hermes self-healing** | Auto-restart gateway on crash via systemd. Crash loop detection with rate-limited reboots |

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    PI AUTOPILOT                          │
│                                                         │
│  🔄 POST-REBOOT DEBUG (systemd, every boot)              │
│  ├── Diagnose crash cause (OOM/thermal/panic/freeze)     │
│  ├── Check freeze heartbeat staleness                    │
│  ├── Run forensics if hard freeze detected               │
│  ├── Restore critical services                           │
│  └── Telegram report (or cache if offline)               │
│                                                         │
│  ❄️ FREEZE WATCHDOG (cron, every 1 min, no-agent)        │
│  ├── Heartbeat: 16 metrics to /var/tmp (NVMe)            │
│  ├── Pre-freeze snapshot every 2 min (full diagnostics)  │
│  ├── D-state, zombies, swap, load, PMIC, throttled       │
│  ├── On boot: stale heartbeat > 120s = hard freeze       │
│  └── Forensics report → /var/tmp/pi-last-forensics.txt   │
│                                                         │
│  🩺 HEALTH MONITOR (cron, every 10 min)                  │
│  ├── 20 metrics with individual thresholds               │
│  ├── Temperature (75→80→85°C escalation)                 │
│  ├── Swap (512→1024→1800 MB — OOM early warning)         │
│  ├── Load avg (3.0→4.5→8.0 — CPU pressure)               │
│  ├── I/O wait (10→25→50% — NVMe stall detection)         │
│  ├── D-state procs (3→10→20 — I/O hang signature)        │
│  ├── Zombies (10→50 — PID exhaustion)                    │
│  ├── FDs (50k→100k — fd leak)                            │
│  ├── GPU mem (128→256 MB — display freeze)               │
│  ├── PMIC errors (10→100 — silent freeze cause #1)       │
│  ├── Network (down→reconnect→up→report)                  │
│  ├── Disk / Inodes / RAM thresholds                      │
│  ├── NVMe SMART (spare, media_errors, unsafe_shutdowns)  │
│  ├── File integrity (SHA256 vs backup manifest)          │
│  ├── Hermes Gateway (crash detection, restart count)     │
│  ├── Auto-backup (hourly snapshots)                      │
│  ├── Reports pending + flush on network restore          │
│                                                         │
│  🧠 HERMES SELF-HEALING (systemd)                        │
│  ├── hermes-gateway.service (Restart=always, 5s delay)   │
│  ├── Crash handler logs death, tracks count              │
│  ├── Crash loop detection (>5 in 10 min = REBOOT Pi)    │
│  ├── Reboot rate limit: 3 per 30 min                     │
│  └── Sends Telegram alert before rebooting               │
│                                                         │
│  ⚡ HARDWARE WATCHDOG (systemd, 60s timeout)              │
│  └── Kernel panic → reboot in 10s                        │
└─────────────────────────────────────────────────────────┘
```

## Quick Start

### Prerequisites
- Raspberry Pi 5 running Debian 13 (Trixie) or Raspberry Pi OS
- [Hermes Agent v0.19+](https://hermes-agent.nousresearch.com)
- Telegram bot configured in Hermes gateway

### One-Command Install
```bash
curl -sSL https://raw.githubusercontent.com/le-cmyk/pi-autopilot/main/scripts/install.sh | bash
```

### Manual Install
```bash
git clone https://github.com/le-cmyk/pi-autopilot.git
cd pi-autopilot
sudo bash scripts/install.sh
```

## Files

```
pi-autopilot/
├── README.md
├── docs/
│   ├── architecture.md        # Full system design
│   ├── setup.md               # Step-by-step setup
│   ├── monitoring.md          # All 20 metrics + thresholds + alerts
│   └── troubleshooting.md     # Known issues & solutions
├── scripts/
│   ├── install.sh              # One-shot installer
│   ├── reboot                  # Safe reboot with pre-flight checks
│   ├── pi-freeze-watchdog.sh   # Freeze heartbeat + detection (16 metrics/min)
│   ├── pi-freeze-forensics.sh  # Comprehensive freeze diagnostics
│   ├── pi-health-snapshot.sh   # On-demand full health dump (20 sections)
│   ├── pi-reboot-check.sh      # Post-reboot diagnostics runner
│   ├── hermes-crash-handler.sh # Crash detection + logging + reboot escalation
│   └── backup-critical-files.sh
├── skills/                     # Hermes Agent skills
│   ├── pi-reboot-debug.md
│   ├── pi-health-monitor.md
│   ├── pi-auto-reboot.md
│   └── pi-autopilot.md         # Umbrella skill
├── config/
│   ├── pi-state.yaml           # Master config (all thresholds, services)
│   ├── journald/override.conf  # Persistent journal
│   └── networkmanager/wifi-powersave-off.conf
├── systemd/
│   ├── hermes-gateway.service      # Hermes gateway with Restart=always
│   └── hermes-reboot-debug.service
└── hermes/
    ├── cron-jobs.md            # Cron job definitions (3 jobs)
    └── setup-commands.md       # Hermes CLI setup commands
```

## Key Design Decisions

### 20 metrics, not 6
The health monitor now tracks swap, load average, I/O wait, D-state processes, zombies, process count, file descriptors, GPU memory, PMIC firmware errors, and inode usage — in addition to temperature, network, disk, RAM, NVMe SMART, file integrity, and services. Rising swap usage is the #1 OOM early warning; high I/O wait with D-state processes is the signature of a failing NVMe; PMIC errors are the #1 silent-freeze cause.

### Freeze heartbeat captures everything
The freeze watchdog writes 16 metrics every 60 seconds — uptime, load, temp, RAM, swap, D-state, zombies, procs, FDs, PMIC errors, throttled flags, and the last kernel message. Every 2 minutes it dumps a full diagnostic snapshot. All on NVMe ext4 — nothing is lost on power cut.

### All data survives power loss
`/var/tmp` is on the NVMe ext4 partition (NOT tmpfs). Freeze heartbeat, health state, crash logs, pending reports — everything survives unplugs. Filesystem has `errors=remount-ro`, `commit=5`, `fsck.mode=force`, `fsck.repair=yes`, and `tune2fs -c 5`.

### Why systemd manages Hermes (not bare process)
When Hermes gateway runs as a bare `hermes gateway run` process and crashes, it stays dead until someone notices. systemd's `Restart=always` restarts it within 5 seconds. The crash handler logs every death and tracks crash counts. **If Hermes crashes 5+ times in 10 minutes, the crash handler auto-reboots the Pi** (rate-limited to 3 reboots per 30 min).

### Why WiFi Power Save is OFF
Broadcom BCM4345/6 power saving causes SDIO bus hangs on Pi 5, leading to full system freezes. Disabled permanently.

### Why cgroup memory is disabled
Pi 5 with kernel 6.x has known instability with the cgroup memory controller. `cgroup_disable=memory` is intentional.

### Why journal is persistent
Raspberry Pi OS defaults to volatile journal. We override because crash forensics require surviving logs. On NVMe SSD, write overhead is negligible.

### Why NVMe ASPM is DISABLED
Pi 5 PCIe controller doesn't reliably handle NVMe power state transitions. `pcie_aspm=off nvme_core.default_ps_max_latency_us=0` in kernel cmdline prevents PCIe bus hangs.

### Why PMIC errors are tracked
Old bootloader EEPROM causes PMIC communication error storms (1261 errors/6min) → silent freezes. 1-5 per boot is normal with updated EEPROM; >10 accumulating = alert; >100 = storm, update immediately.

## License

MIT — use it, fork it, improve it.