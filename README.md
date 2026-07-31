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
| 🩺 **Continuous monitoring** | Temperature, network, disk, RAM, NVMe SMART, Hermes Gateway — every 10 min |
| ❄️ **Freeze detection** | Filesystem heartbeat (every 1 min) detects silent hard freezes. Pre-freeze snapshots capture dmesg/process/memory state. Forensics report on next boot. |
| 🌐 **Network outage recovery** | Auto-reconnect, cached reports, flush on restore |
| 📲 **Telegram alerts** | State transitions only — no spam |
| 📦 **Config backups** | Automatic hourly snapshots + SHA256 integrity |
| ☕ **Daily briefing** | Weather + news every morning at 8am |
| 🧠 **Hermes self-healing** | Auto-restart gateway on crash via systemd. Crash detection + reporting. |

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
│  ❄️ FREEZE DETECTION (cron, every 1 min)                   │
│  ├── Filesystem heartbeat → /var/tmp/pi-freeze-heartbeat   │
│  ├── Pre-freeze snapshot every 2 min (dmesg, ps, mem)      │
│  ├── D-state process tracking (uninterruptible sleep)       │
│  ├── On boot: check heartbeat staleness → hard freeze?     │
│  ├── Auto-run forensics if freeze detected                 │
│  └── Forensics report → /var/tmp/pi-last-forensics.txt     │
│                                                         │
│  🩺 HEALTH MONITOR (cron, every 10 min)                  │
│  ├── Temperature (75→80→85°C escalation)                 │
│  ├── Network (down→reconnect→up→report)                  │
│  ├── Disk / RAM thresholds                               │
│  ├── NVMe SMART (spare, media_errors, unsafe_shutdowns)  │
│  ├── File integrity (SHA256 vs backup manifest)          │
│  ├── **Hermes Gateway** (crash detection, restart count)  │
│  ├── Auto-backup (hourly snapshots)                      │
│  ├── Reports pending + flush on network restore          │
│                                                         │
│  🧠 HERMES SELF-HEALING (systemd)                        │
│  ├── hermes-gateway.service (Restart=always, 5s delay)   │
│  ├── Crash handler logs death, tracks count              │
│  ├── Crash loop detection (>5 in 10 min = REBOOT Pi)    │
│  ├── Sends Telegram alert before rebooting               │
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
│   ├── pi-freeze-watchdog.sh    # Freeze heartbeat + detection\n│   ├── pi-freeze-forensics.sh   # Comprehensive freeze diagnostics\n│   ├── pi-reboot-check.sh     # Post-reboot diagnostics runner
│   ├── hermes-crash-handler.sh # Crash detection + logging
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
│   ├── hermes-gateway.service     # Hermes gateway with Restart=always
│   └── hermes-reboot-debug.service
└── hermes/
    ├── cron-jobs.md           # Cron job definitions
    └── setup-commands.md      # Hermes CLI setup commands
```

## Key Design Decisions

### Why systemd manages Hermes (not bare process)
When Hermes gateway runs as a bare `hermes gateway run` process and crashes, it stays dead until someone notices. systemd's `Restart=always` restarts it within 5 seconds. The crash handler logs every death to `/var/tmp/hermes-crash.log` and tracks crash counts in a 10-minute sliding window. **If Hermes crashes 5+ times in 10 minutes, the crash handler automatically reboots the Pi** and sends a Telegram alert before the reboot. This prevents infinite crash loops from silently degrading the system.

### Why WiFi Power Save is OFF
The Broadcom BCM4345/6 driver's power saving mode causes SDIO bus hangs on Pi 5, leading to full system freezes. Disabled permanently via NetworkManager config.

### Why cgroup memory is disabled
Pi 5 with kernel 6.x has known instability with the cgroup memory controller. `cgroup_disable=memory` is intentional — Docker works fine without it (loses `--memory` limits but gains stability).

### Why journal is persistent
Raspberry Pi OS defaults to volatile journal (`Storage=volatile`) to reduce flash wear. We override this because crash forensics require surviving logs. On NVMe SSD (~500 TBW), the write overhead is negligible.

### Why NVMe SMART monitoring
The PNY CS1030 NVMe is healthy (100% spare, 4% used), but `unsafe_shutdowns` (59/86 = 68.6%) indicates frequent hard freezes requiring power cycles. We track `available_spare` and `media_errors` to catch degradation before data loss.

### Why NVMe ASPM is DISABLED
Pi 5 PCIe controller doesn't reliably handle NVMe Autonomous Power State Transitions (ASPM). Added `pcie_aspm=off nvme_core.default_ps_max_latency_us=0` to kernel cmdline to prevent PCIe bus hangs that cause silent freezes.

### Why brcmfmac firmware matters
The Broadcom BCM4345/6 on-chip WiFi firmware (Aug 2023) can't be fully updated — it's burned into ROM. The Linux `firmware-brcm80211` package (updated to 2026-05-19) provides the latest driver-side firmware. Combined with power_save=off and ASPM disable, this covers all known Pi 5 freeze vectors.

### Freeze Detection Design
Hard freezes (no kernel panic, no logs, no SSH) are the hardest to diagnose. The freeze watchdog writes a timestamp to `/var/tmp/pi-freeze-heartbeat.txt` every minute. On boot, `pi-reboot-check.sh` checks if the heartbeat is stale (>120s). If a hard freeze is detected, `pi-freeze-forensics.sh` collects a comprehensive report including the pre-freeze snapshot (dmesg tail, D-state processes, memory/network state captured every 2 min before the freeze).

## License

MIT — use it, fork it, improve it.