# Troubleshooting — Known Issues & Fixes

## Freezing / No Response

### Symptom: Pi freezes randomly, requires power cycle

**Root causes found on this Pi 5:**

1. **WiFi Power Saving (MOST LIKELY)**
   - Driver: `brcmfmac BCM4345/6` with `Power Management: on`
   - The Broadcom chipset in power-save mode hangs the SDIO bus → full system freeze
   - **Fix**: `wifi.powersave = 2` in NetworkManager (`/etc/NetworkManager/conf.d/wifi-powersave-off.conf`)
   - Applied persistently, verified with `iwconfig wlan0 | grep "Power Management"` → should show `off`

2. **Old Bootloader EEPROM (RESOLVED)**
   - Bootloader from May 2025 generated 1261 PMIC errors per minute
   - Updated to May 2026 via `sudo rpi-eeprom-update -a` + reboot
   - Verify: `sudo rpi-eeprom-update` → "up to date"

3. **WiFi Firmware (TO WATCH)**
   - Current: `version 7.45.265 (Aug 29 2023)` — 3 years old
   - Try updating: `sudo apt update && sudo apt upgrade` for newer `brcmfmac` firmware

### Debugging a freeze (with persistent journal)

```bash
# Previous boot logs
sudo journalctl -b -1 --no-pager | tail -100

# Previous boot errors only
sudo journalctl -p err -b -1 --no-pager

# Kernel messages around crash time
sudo journalctl -b -1 -k --no-pager | tail -50
```

## I/O Errors on Hermes Config Files

### Symptom: `OSError: [Errno 5] Input/output error` on `telegram-approved.json`

**Cause**: Unsafe shutdown (power loss) leaving filesystem in inconsistent state. NVMe is healthy (SMART PASSED, 0 media errors). 44/66 shutdowns were unsafe.

**Prevention**:
- Use `~/reboot` script for clean reboots (syncs filesystems, flags as planned)
- Automatic backups in `~/.hermes/backups/`
- Health monitor verifies SHA256 integrity every 30 min

**Recovery**:
```bash
# Restore from backup
cp ~/.hermes/backups/auth.json.bak ~/.hermes/auth.json
cp ~/.hermes/backups/config.yaml.bak ~/.hermes/config.yaml
# Restart Hermes
sudo systemctl restart hermes-gateway  # or however gateway is managed
```

## NVMe SMART Warnings

```bash
# Full SMART report
sudo nvme smart-log /dev/nvme0
sudo smartctl -a /dev/nvme0

# Key metrics to watch
# - available_spare: should be 100%, alert if <10%
# - media_errors: must be 0
# - unsafe_shutdowns: track trend
# - percentage_used: alert if >90%
```

## Journal Not Persisting

Raspberry Pi OS overrides journal storage to volatile:
```
/usr/lib/systemd/journald.conf.d/40-rpi-volatile-storage.conf
→ Storage=volatile
```

Our override in `/etc/systemd/journald.conf.d/override.conf`:
```
→ Storage=persistent
```

Verify: `ls /var/log/journal/$(cat /etc/machine-id)/*.journal`

## General Health Check

```bash
# All-in-one
vcgencmd get_throttled && vcgencmd measure_temp && free -h && df -h /
sudo nvme smart-log /dev/nvme0 | grep -E "critical_warning|media_errors|available_spare"
cat /var/tmp/pi-health-state.json | python3 -m json.tool
```