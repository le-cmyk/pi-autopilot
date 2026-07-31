---
name: pi-auto-reboot
description: "Pi5 watchdog + kernel panic = auto-reboot on freeze."
version: 1.1.0
platforms: [linux]
---

# Pi Auto-Reboot Setup

Configure a Raspberry Pi (tested on Pi 5, Debian Trixie) to automatically reboot on freeze, kernel panic, or hang — using the hardware watchdog and kernel settings. Includes PMIC firmware bug diagnosis (major Pi 5 freeze cause).

## Quick Start

```bash
# 1. Check if systemd already holds the watchdog (common on Pi 5)
systemctl show -p RuntimeWatchdogUSec -p RebootWatchdogUSec

# 2. Enable kernel panic auto-reboot (10s delay)
sudo sysctl -w kernel.panic=10
echo "kernel.panic = 10" | sudo tee /etc/sysctl.d/99-reboot-on-panic.conf
```

If systemd already shows `RuntimeWatchdogUSec=1min` or similar, you're done. systemd pings the hardware watchdog; if it hangs, the Pi reboots automatically. **Do NOT install the separate watchdog daemon** — it will fail with `Device or resource busy (errno 16)`.

## Full Procedure

### Step 1 — Identify the watchdog

```bash
ls /dev/watchdog*
cat /sys/class/watchdog/watchdog0/identity
cat /sys/class/watchdog/watchdog0/timeout
```

Pi 5 uses `bcm2835_wdt` (built into the kernel, not a loadable module).

### Step 2 — systemd watchdog (preferred)

Check current state:
```bash
systemctl show -p RuntimeWatchdogUSec -p RebootWatchdogUSec -p RuntimeWatchdogPreUSec
```

**If `RuntimeWatchdogUSec` is set (e.g., `1min`):** systemd already handles it. Nothing to install.

**If `RuntimeWatchdogUSec=off`:** install the watchdog daemon:
```bash
sudo apt-get install -y watchdog
# Configure /etc/watchdog.conf with: device=/dev/watchdog, timeout=15, interval=10
sudo systemctl enable --now watchdog
```

### Step 3 — Kernel panic auto-reboot

```bash
sudo sysctl -w kernel.panic=10
echo "kernel.panic = 10" | sudo tee /etc/sysctl.d/99-reboot-on-panic.conf
```

### Step 4 — Enable persistent journal (CRITICAL for debugging)

Without this, all crash logs are lost on reboot. Always enable it:
```bash
sudo mkdir -p /var/log/journal
sudo sed -i 's/#Storage=auto/Storage=persistent/' /etc/systemd/journald.conf
sudo systemctl restart systemd-journald
```

Verify after next reboot: `sudo journalctl -b -1 -p err`

### Step 5 — Check for PMIC firmware bugs (Pi 5 — MAJOR freeze cause)

Old bootloader EEPROM versions cause PMIC communication errors that lead to silent freezes with no log trace. See `references/pi5-pmic-firmware-bug.md` for full details.

```bash
sudo rpi-eeprom-update          # Check version
dmesg | grep -c "raspberrypi-firmware.*status 0x80000001"  # Count PMIC errors
sudo rpi-eeprom-update -a       # Update if old
```

**Known bad:** May 2025 (1261 PMIC errors in 6 min). **Fixed:** May 2026+.

### Step 6 — Verify

```bash
sysctl kernel.panic
systemctl show -p RuntimeWatchdogUSec
cat /sys/class/watchdog/watchdog0/state
sudo rpi-eeprom-update
dmesg | grep -c "raspberrypi-firmware.*status 0x80000001"
```

## Final stack (typical Pi 5)

| Layer | Mechanism | Trigger | Reboot after |
|---|---|---|---|
| Hardware watchdog | systemd RuntimeWatchdogSec | systemd hangs | ~60s |
| Kernel panic | kernel.panic=10 | kernel oops/panic | 10s |
| Shutdown stall | systemd RebootWatchdogSec | shutdown hangs | ~120s |

## Pitfalls

- **Don't install `watchdog` daemon if systemd has the device.** Check `RuntimeWatchdogUSec` first. The daemon will fail with `errno 16` and is redundant.
- **Watchdog daemon interval must be shorter than timeout.** Typical: interval=10, timeout=15.
- **`vcgencmd get_throttled`** tells you if the Pi is throttling due to heat or power — check this when reboots are frequent.
- **Pi 5 needs 5V/5A.** Many power supplies only deliver 3A, causing under-voltage reboots under load.
- **Old bootloader EEPROM is the #1 silent-freeze cause on Pi 5.** The PMIC firmware bug (observed: 1261 errors/6min on May 2025 firmware) causes hangs, I/O errors, and filesystem corruption — all without any kernel panic or OOM trace. Always run `sudo rpi-eeprom-update -a`. See `references/pi5-pmic-firmware-bug.md`.
- **Persistent journal is mandatory for debugging.** Without `Storage=persistent`, all crash evidence vanishes on reboot. Always enable it (Step 4).

## Support Files

- **`templates/pi-state.yaml`** — starter state file. Lists critical services, thresholds, known issues. Copy to `~/.hermes/pi-state.yaml` and customize.
- **`references/post-reboot-hermes-pattern.md`** — systemd service + script pattern for running Hermes diagnostics on every boot and sending a Telegram recap.
- **`references/pi5-pmic-firmware-bug.md`** — Pi 5 PMIC firmware bug: diagnosis, impact, fix. Old bootloader EEPROM causes random silent freezes.