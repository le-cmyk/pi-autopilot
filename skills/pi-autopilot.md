---
name: pi-autopilot
description: "Pi5 self-healing: 20-metric monitor, freeze watchdog, crash forensics, auto-recover."
version: 1.2.0
platforms: [linux]
---

# Pi Autopilot — Raspberry Pi 5 Self-Healing System

Umbrella skill covering the full Pi 5 autonomous operations stack. Orchestrates three specialist skills and provides cross-cutting knowledge.

## Related Skills

- **pi-health-monitor** — 20-metric health checks every 10 min
- **pi-reboot-debug** — Post-reboot crash forensics + freeze detection + cold reboot verification
- **pi-auto-reboot** — Hardware watchdog + kernel panic + PMIC firmware + shutdown hardening

## State Files

```
/home/pi/.hermes/pi-state.yaml          # Master config (thresholds, services, known issues)
/var/tmp/pi-health-state.json           # Runtime state (metrics, outage tracking)
/var/tmp/pi-health-pending-reports.txt  # Queued reports for offline delivery
/var/tmp/pi-nvme-smart.txt              # Last NVMe SMART snapshot
/var/tmp/pi-current-sha256.txt          # Current file hashes for integrity check
/var/tmp/hermes-crash.log               # Hermes gateway crash log (exit events)
/var/tmp/hermes-crash-count.txt         # Crash counter in sliding window
/home/pi/.hermes/backups/               # Hourly snapshots + SHA256 manifest
```

## Pi 5 Known Crash Causes — Ranked by Likelihood

### #1 WiFi Power Save (MOST COMMON)
**Symptom**: Pi freezes completely, no response, requires power cycle.
**Root cause**: Broadcom `brcmfmac` driver power saving (`Power Management: on`) hangs the SDIO bus. The WiFi chipset (BCM4345/6) in power-save mode blocks the bus, cascading into a full system freeze.
**Fix**: Disable permanently:
```bash
# Immediate
sudo iwconfig wlan0 power off

# Persistent (survives reboot)
echo -e "[connection]\nwifi.powersave = 2" | sudo tee /etc/NetworkManager/conf.d/wifi-powersave-off.conf
```
**Verify**: `iwconfig wlan0 | grep "Power Management"` → must say `off`.

### #2 brcmfmac SDIO Firmware (HARD FREEZE WITHOUT LOGS)
**Symptom**: Pi freezes completely — black screen, no SSH, no kernel panic trace, no logs. The previous boot journal ends abruptly with no error. Requires hard power cycle.
**Root cause**: Broadcom BCM4345/6 on-chip WiFi firmware (Aug 29 2023) has known SDIO bus hang bugs. The firmware is burned into ROM — it cannot be updated beyond what Broadcom shipped on the chip. The SDIO bus hangs prevent the kernel from writing any crash evidence.
**Fix**: 
1. Ensure Linux driver-side firmware is latest: `sudo apt install firmware-brcm80211` (currently 2026-05-19)
2. WiFi power save MUST be OFF (see #1)
3. If freezes persist: switch to 2.4GHz band, or disable onboard WiFi entirely and use external USB adapter
4. NVMe ASPM MUST be OFF (see #4)

### #3 Old Bootloader EEPROM
**Symptom**: Random freezes, PMIC communication errors in dmesg.
**Root cause**: Bootloader from May 2025 generates ~200 PMIC errors/minute (`raspberrypi-firmware: Request 0x00030093 returned status 0x80000001`).
**Fix**: Update EEPROM:
```bash
sudo rpi-eeprom-update -a
sudo reboot  # EEPROM applies during reboot (green screen ~30s)
```
**Verify**: `sudo rpi-eeprom-update` → "up to date". `dmesg | grep -c "status 0x80000001"` → near 0.

### #5 Cgroup Memory Controller
**Symptom**: Docker warnings "No memory limit support", but this is INTENTIONAL.
**Root cause**: Pi 5 with kernel 6.x has instability with cgroup memory controller. `cgroup_disable=memory` in kernel cmdline is a deliberate fix.
**Action**: DO NOT re-enable. Docker works without it (loses `--memory` limits).

### #7 Filesystem corruption from hard power cycles
**Symptom**: Hermes fails to start with `OSError [Errno 5] Input/output error` on config/pairing files. Pi may have been unplugged or power-cycled.
**Root cause**: Hard power cycles (unplugging) corrupt the EXT4 filesystem. The journal recovers on next boot (`orphan cleanup on readonly fs` in dmesg), but individual files may be lost or corrupted.
**Diagnosis**:
```bash
# Check for I/O errors in journal
sudo journalctl -b -1 -p err --no-pager | grep -i "i/o error\|input/output"

# Check if critical files are readable
for f in config.yaml auth.json .env pi-state.yaml; do
  cat /home/pi/.hermes/$f > /dev/null 2>&1 && echo "✅ $f" || echo "❌ $f CORRUPTED"
done

# Check NVMe unsafe_shutdowns trend
sudo nvme smart-log /dev/nvme0 | grep unsafe_shutdowns
```
**Fix**: Restore corrupted files from backup:
```bash
cp ~/.hermes/backups/<file>.bak ~/.hermes/<path>
# telegram-approved.json auto-regenerates if missing — no restore needed
```
**Prevention**: Never unplug the Pi. If frozen, try SSH first. The hardware watchdog auto-reboots after 60s of freeze. Use `~/reboot` for clean reboots.

### #6 Stale gateway on boot (port conflict → crash loop)
**Symptom**: After reboot, systemd hermes-gateway fails immediately: `Gateway already running (PID XXXX)`. Each failure increments crash counter → 5 crashes triggers another reboot → same problem repeats.
**Root cause**: A stale Hermes process from before reboot is still bound to the port when the systemd service starts. Hermes refuses to start if the port is occupied.
**Fix**: Use `--replace` flag in ExecStart so the new process kills the stale one:
```
ExecStart=/home/pi/.local/bin/hermes gateway run --replace
```
### #4 NVMe Power Management (ASPM) — NOW DISABLED
**Symptom**: Pi randomly freezes with no log trace. Hard power cycle required.
**Root cause**: NVMe ASPM can cause the drive to enter low-power states the Pi 5 PCIe controller doesn't handle — the PCIe bus hangs, freezing the entire system.
**Fix**: DISABLED via kernel cmdline: `pcie_aspm=off nvme_core.default_ps_max_latency_us=0` in `/boot/firmware/cmdline.txt`. Requires reboot to take effect.
**Verify**: `sudo nvme get-feature -f 0x0c /dev/nvme0 | grep "Current value"` → should show `0x00000001` even with cmdline (the feature is always 1; `pcie_aspm=off` prevents the kernel from using it). Check cmdline: `cat /boot/firmware/cmdline.txt` → must include `pcie_aspm=off`.

### #6 Stale gateway on boot (port conflict → crash loop)

## Post-Reboot Diagnostics — Extended Checklist

When diagnosing a crash, check these in order:

1. **Was it planned?** Read `/var/tmp/pi-health-state.json` → `planned_reboot: true` means intentional.
2. **WiFi power save still off?** `iwconfig wlan0 | grep "Power Management"` — if ON, this is the cause.
3. **Bootloader current?** `sudo rpi-eeprom-update` — if outdated, update immediately.
4. **Persistent journal working?** `ls /var/log/journal/$(cat /etc/machine-id)/*.journal` — if missing, fix Raspbian override.
5. **Previous boot logs?** `sudo journalctl -p err -b -1 --no-pager --lines=50`
6. **Throttling history?** `vcgencmd get_throttled` — 0x0=clean, 0x50000=under-voltage, 0x50005=thermal.
7. **NVMe SMART after crash?** `sudo nvme smart-log /dev/nvme0` — check `unsafe_shutdowns` trend.

## Journal Persistence — The Raspbian Trap

Raspberry Pi OS ships with `/usr/lib/systemd/journald.conf.d/40-rpi-volatile-storage.conf` which forces `Storage=volatile`. This silently discards all crash logs. Fix:

```bash
sudo mkdir -p /etc/systemd/journald.conf.d
echo -e "[Journal]\nStorage=persistent" | sudo tee /etc/systemd/journald.conf.d/override.conf
sudo mkdir -p /var/log/journal
sudo systemctl restart systemd-journald
```

## Hermes Gateway Self-Healing

The Hermes gateway (`hermes gateway run`) is managed by systemd via `hermes-gateway.service`. When the gateway process dies — from OOM, config corruption, unhandled exception, or any other cause — systemd restarts it within **5 seconds**. This prevents the *"Sorry, I encountered an unexpected error"* dead state where the user's agent stops responding until manually restarted.

### Architecture

```
┌──────────────────────────────────────────────────┐
│  systemd (hermes-gateway.service)                │
│  ├── Restart=always (5s delay)                   │
│  ├── ExecStart = hermes gateway run --replace    │
│  ├── StartLimitBurst=10 (prevents crash floods)   │
│  ├── ExecStopPost → hermes-crash-handler.sh      │
│  └── All output → journald (journalctl -u)        │
├──────────────────────────────────────────────────┤
│  pi-health-monitor (cron, every 10 min)           │
│  ├── Checks hermes-gateway.service status         │
│  ├── Detects crash count transitions              │
│  ├── Alerts if service is "failed" (not running) │
│  └── Warns if Hermes runs bare (unmanaged)        │
├──────────────────────────────────────────────────┤
│  crash-handler.sh (every exit)                    │
│  ├── Skips clean exits (0) and SIGTERM (143)      │
│  ├── Tracks crash count in 10-min sliding window  │
│  ├── Crash >= 5 → Telegram alert + auto-reboot    │
└──────────────────────────────────────────────────┘
```

### Files

| File | Purpose |
|------|---------|
| `/etc/systemd/system/hermes-gateway.service` | Systemd unit with Restart=always |
| `/home/pi/.hermes/scripts/hermes-crash-handler.sh` | Called by ExecStopPost on every exit |
| `/var/tmp/hermes-crash.log` | Crash event log (timestamp + exit code) |
| `/var/tmp/hermes-crash-count.txt` | Crash counter + window timestamp |

### Crash loop escalation

| Crashes in 10 min | Action |
|---|---|
| 1-4 | systemd restarts silently in 5s |
| 5+ | Crash handler: send Telegram alert → safe reboot via `~/reboot` |

The crash handler (`hermes-crash-handler.sh`) handles the escalation directly. It tries to send a Telegram alert before rebooting. If network is down, the alert is queued to `/var/tmp/pi-health-pending-reports.txt` and flushed after reboot.
**Important**: Exit codes 0 (clean stop) and 143 (SIGTERM from `--replace` takeover or systemd stop) are filtered out — they do NOT count as crashes.

### Reboot rate limiting

To prevent infinite reboot loops from a persistent crash cause (e.g., corrupted file that survives reboot), the crash handler limits reboots to **3 per 30-minute window**. If a 4th reboot would be triggered:

- The reboot is **skipped** — alert-only, no reboot
- A Telegram alert is sent: "🛑 Hermes crash loop — reboot rate limit reached"
- The message includes: crash count, reboot count, time window, and "Manual intervention required"
- The rate limit window resets after 30 minutes of stability

This means if the Pi has a persistent unfixable problem (like a corrupted file that keeps crashing Hermes), it won't enter an infinite reboot loop. It reboots 3 times, then stops and waits for manual intervention.

### Cron job model preference

**Always use free models for recurring cron jobs** to avoid burning paid API credits. The Pi has two cron jobs, both pinned to `nvidia/nemotron-3-ultra-550b-a55b:free` via OpenRouter:

```
hermes cron edit <job_id> --model "nvidia/nemotron-3-ultra-550b-a55b:free" --provider openrouter
```

Verify with: `python3 -c "import json; [print(f'{j[\"name\"]}: {j.get(\"model\",\"default\")}') for j in json.load(open('/home/pi/.hermes/cron/jobs.json'))['jobs']]"`

### Migration from bare process

If Hermes was originally started as `hermes gateway run` (bare foreground process), switch to systemd:

```bash
# Enable the service (one-time)
sudo systemctl enable hermes-gateway

# Stop the bare process and start via systemd
sudo systemctl start hermes-gateway

# Verify
systemctl status hermes-gateway
tail /var/tmp/hermes-crash.log
```

The health monitor detects if Hermes is running bare (not systemd-managed) and warns about it.

## Safe Reboot Script

Use `~/reboot` for clean reboots (avoids unsafe shutdowns, flags as planned):
```bash
~/reboot                    # simple
~/reboot "kernel update"    # with reason logged
```

The script stops Docker containers, writes a final freeze heartbeat, backs up critical files, syncs filesystems, marks the reboot as planned (so pi-reboot-debug doesn't send a crash alert), and triggers a cold reboot.

## Shutdown Hardening

Pi 5 firmware defaults to `reboot=w` (warm reboot), which skips PCIe controller reset. This leaves the NVMe in an inconsistent state — causing "orphan cleanup on readonly fs" on every boot. The fix:

```bash
# Add reboot=cold at the END of /boot/firmware/cmdline.txt (last occurrence wins)
echo " reboot=cold" | sudo tee -a /boot/firmware/cmdline.txt
```

Systemd shutdown hardening (`/etc/systemd/system.conf.d/50-shutdown.conf`):
```ini
[Manager]
DefaultTimeoutStopSec=10s   # services get 10s, then SIGKILL
RebootWatchdogSec=3min       # force reboot if shutdown hangs >3min
DefaultDeviceTimeoutSec=15s  # don't wait forever for devices
```

Docker faster shutdown (`/etc/docker/daemon.json`):
```json
{"shutdown-timeout": 15}
```

Combined: cold reboot + aggressive timeouts + Docker fast stop = clean unmount every time.

## Pitfalls

- **WiFi power save is the #1 Pi 5 freeze cause.** Always check it first when debugging crashes.
- **Raspbian journald is volatile by default.** Always override before relying on crash logs.
- **`cgroup_disable=memory` is intentional.** Don't "fix" it.
- **Bootloader updates need a reboot with green screen.** Don't interrupt this.
- **Hermes reboot commands are hardline blocked.** Use `~/reboot` script or manual `sudo reboot`.
- **The three pi-* skills are user-owned.** Run `hermes curator adopt pi-health-monitor pi-reboot-debug pi-auto-reboot` to enable auto-patching.
- **State file is the source of truth.** Both pi-health-monitor and pi-reboot-debug read it at startup.
- **The Pi 5 official PSU (5V/5A) is mandatory.** Third-party supplies cause under-voltage freezes.
- **Hermes crash handler runs on EVERY exit**, including clean shutdowns. Exit code 0 (clean stop) and 143 (SIGTERM from `--replace` or systemd stop) are filtered out and do NOT count as crashes.
- **The `--replace` flag is required in ExecStart.** Without it, a stale Hermes process on the port blocks startup → fake crash loop → unnecessary reboot.
- **Reboot rate limit: max 3 reboots per 30 min.** Beyond that, the crash handler stops rebooting and sends an alert-only. Prevents infinite reboot loops from unfixable problems.
- **Hard power cycles (unplugging) corrupt files.** If Hermes shows I/O errors on startup, check for filesystem corruption. Restore from `~/.hermes/backups/`. Never unplug — use `~/reboot` or wait for the watchdog.
- **Cron jobs should use free models.** Pin to `nvidia/nemotron-3-ultra-550b-a55b:free` on OpenRouter to avoid paid API costs.
- **`ps --sort=-%rss` fails on Debian procps.** Use `--sort=-%mem` instead. `--sort=-%cpu` works fine. All monitoring scripts use `%mem` to avoid this.
- **Companion scripts**: `pi-health-snapshot.sh` (on-demand 20-section health dump), `pi-freeze-forensics.sh` (post-freeze analysis), `pi-freeze-watchdog.sh` (heartbeat + detection).

## Support Files

- **`references/monitoring-architecture.md`** — Full 20-metric monitoring stack: freeze watchdog, health monitor, hardware safety net, data survivability, companion scripts. Read this for the complete picture of what's being tracked and how.
- **`references/hermes-crash-loop-forensics.md`** — Hermes Gateway crash loop investigation and rate-limit design details.