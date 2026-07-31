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
| 🔍 **Crash forensics** | Post-reboot agent diagnoses cause, restores services |
| 🩺 **Continuous monitoring** | Temperature, network, disk, RAM, NVMe SMART — every 10 min |
| 🌐 **Network outage recovery** | Auto-reconnect, cached reports, flush on restore |
| 📲 **Telegram alerts** | State transitions only — no spam |
| 📦 **Config backups** | Automatic hourly snapshots + SHA256 integrity |
| ☕ **Daily briefing** | Weather + news every morning at 8am |

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    PI AUTOPILOT                          │
│                                                         │
│  🔄 POST-REBOOT DEBUG (systemd, every boot)              │
│  ├── Diagnose crash cause (OOM/thermal/panic)            │
│  ├── Restore critical services                           │
│  └── Telegram report (or cache if offline)               │
│                                                         │
│  🩺 HEALTH MONITOR (cron, every 10 min)                  │
│  ├── Temperature (75→80→85°C escalation)                 │
│  ├── Network (down→reconnect→up→report)                  │
│  ├── Disk / RAM thresholds                               │
│  ├── NVMe SMART (spare, media_errors, unsafe_shutdowns)  │
│  ├── File integrity (SHA256 vs backup manifest)          │
│  └── Auto-backup (hourly snapshots)                      │
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
│   ├── monitoring.md          # Health checks reference
│   └── troubleshooting.md     # Known issues & solutions
├── scripts/
│   ├── install.sh             # One-shot installer
│   ├── reboot                 # Safe reboot with pre-flight checks
│   └── backup-critical-files.sh
├── skills/                    # Hermes Agent skills
│   ├── pi-reboot-debug.md
│   ├── pi-health-monitor.md
│   └── pi-auto-reboot.md
├── config/
│   ├── pi-state.yaml          # System state template
│   ├── journald/override.conf # Persistent journal
│   └── networkmanager/wifi-powersave-off.conf
├── systemd/
│   └── hermes-reboot-debug.service
└── hermes/
    ├── cron-jobs.md           # Cron job definitions
    └── setup-commands.md      # Hermes CLI setup commands
```

## Key Design Decisions

### Why WiFi Power Save is OFF
The Broadcom BCM4345/6 driver's power saving mode causes SDIO bus hangs on Pi 5, leading to full system freezes. Disabled permanently via NetworkManager config.

### Why cgroup memory is disabled
Pi 5 with kernel 6.x has known instability with the cgroup memory controller. `cgroup_disable=memory` is intentional — Docker works fine without it (loses `--memory` limits but gains stability).

### Why journal is persistent
Raspberry Pi OS defaults to volatile journal (`Storage=volatile`) to reduce flash wear. We override this because crash forensics require surviving logs. On NVMe SSD (~500 TBW), the write overhead is negligible.

### Why NVMe SMART monitoring
The PNY CS1030 NVMe is healthy but we track `unsafe_shutdowns` (44/66 = 67%) and `available_spare` to catch degradation before it causes data loss.

## License

MIT — use it, fork it, improve it.