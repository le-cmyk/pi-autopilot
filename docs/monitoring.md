# Monitoring Reference

## Health Checks

Every 10 minutes, the `pi-health-monitor` skill runs these checks:

### Temperature (`vcgencmd measure_temp`)
| Threshold | Action |
|---|---|
| ≥ 75°C | Log warning |
| ≥ 80°C | Telegram alert |
| ≥ 85°C | Urgent alert (Pi throttles) |
| Drops < 75°C | Recovery report |

### Network (`ping -c 1 -W 3 8.8.8.8`)
| State | Action |
|---|---|
| UP → DOWN | Record outage start, attempt recovery |
| DOWN → UP | Recovery report + flush pending reports |
| Recovery ladder | `nmcli connect wlan0` → `restart NetworkManager` → `ip link reset` |

### Disk (`df -h /`)
| Threshold | Action |
|---|---|
| > 85% | Log warning |
| > 90% | Telegram alert |
| > 95% | Urgent alert |

### RAM (`free -m`)
| Threshold | Action |
|---|---|
| < 200 MB | Telegram alert |
| < 100 MB | Urgent alert (OOM imminent) |

### Critical Services
```
ssh docker containerd cron NetworkManager systemd-timesyncd
```
Any DOWN → `systemctl restart <svc>` → alert if still down.

### NVMe SMART (`sudo nvme smart-log /dev/nvme0`) — every 30 min
| Metric | Warning | Critical |
|---|---|---|
| `critical_warning` | — | ≠ 0 |
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

## Manual Checks

```bash
# Full health snapshot
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

## Telegram Alert Examples

```
⚠️ Pi à 82°C — surveille la ventilation.
🌡 Pi à 85°C — THROTTLING ! Éteins les conteneurs lourds.
✅ Température redescendue à 68°C.
🌐 Réseau DOWN depuis 12:35. Tentative de reconnexion...
📡 Réseau rétabli après 2h15 d'outage. Tout est OK.
💾 Disque à 91% — vérifie les logs.
🧠 RAM libre: 145 MB — OOM killer possible.
🚨 NVMe media errors détectées — backup immédiat !
🔐 Fichier config.yaml modifié — possible corruption post-crash.
❌ Fichier critique disparu: auth.json — restauré depuis backup.
🔄 Pi redémarré. Cause: OOM killer. Services restaurés.
```