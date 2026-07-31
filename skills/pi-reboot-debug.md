---
name: pi-reboot-debug
description: "Pi5 reboot: find crash cause, restore services, report."
version: 1.0.0
platforms: [linux]
---

# Pi Reboot Debug

This skill runs automatically after every reboot via `hermes-reboot-debug.service`. It diagnoses why the Pi rebooted, restores critical services, and sends a recap to the user on Telegram.

## When to use
Triggered automatically by systemd on boot. Can also be invoked manually with `hermes chat -q --skills pi-reboot-debug "Run pi reboot diagnostics"`.

## Procedure

### Phase 1 — Understand the reboot reason

Read the state file first:
```
read_file /home/pi/.hermes/pi-state.yaml
```

Then read the pre-reboot health state (tells you what was happening before the crash):
```bash
cat /var/tmp/pi-health-state.json 2>/dev/null || echo '{"note": "no pre-reboot state available"}'
```

**Check if this was a PLANNED reboot:**
If `planned_reboot` is `true` in the health state JSON:
  → This was intentional (e.g. `~/reboot` script was used)
  → Skip crash investigation, just verify everything is running
  → Send a short "reboot OK" report, not a crash report
  → Reset `planned_reboot` to `false` after reporting

Then determine if this was a crash or a clean shutdown:
```bash
# Check how long the Pi was down
uptime

# Check previous boot logs for errors
sudo journalctl -p err -b -1 --no-pager --lines=50

# Check kernel messages for OOM kills, panics, thermal events
dmesg | grep -iE "oom|panic|thermal|under-voltage|killed|error" | tail -20

# Check if throttling occurred before reboot
vcgencmd get_throttled 2>/dev/null
```

Classify the reboot reason — cross-reference with pre-reboot health state:
- OOM killer → memory pressure (check pre-reboot mem_free_mb)
- thermal → overheating (check pre-reboot temp_peak)
- under-voltage → power supply issue
- kernel panic → driver/kernel bug
- Network watchdog reboot → network was down for extended period
- No clear cause → unknown (mention this)

### Phase 2 — Fix & restore

Check each critical service from the state file and restart any that are down:
```bash
# Check all critical services
for svc in ssh docker containerd cron NetworkManager systemd-timesyncd; do
  systemctl is-active $svc || sudo systemctl restart $svc
done
```

Check disk:
```bash
df -h /
```

Check temperature and memory:
```bash
vcgencmd measure_temp 2>/dev/null
free -h | grep Mem
```

If Docker is critical, check containers:
```bash
docker ps -a --format "table {{.Names}}\t{{.Status}}" 2>/dev/null
```

Update the state file if anything changed (new services, new issues, etc.) using `write_file`.

### Phase 3 — Report to Telegram (or cache if offline)

Build a clean Markdown report. Format:

```
🔄 *Pi vient de redémarrer*

*Cause probable :* [OOM killer / surchauffe / sous-voltage / kernel panic / inconnu]
*Durée du uptime avant crash :* [X minutes/heures]
*Contexte pré-crash :* [temp: X°C, RAM: X MB free, réseau: up/down]
*Température actuelle :* [X°C]
*Réseau actuel :* [up/down]

✅ *Services critiques :* [tous OK / X service(s) restauré(s)]
[si un service a été redémarré, le lister]

📊 *État rapide :*
• RAM : [X]G used / [Y]G total
• Disque : [X]% utilisé
• Docker : [N] containers actifs

[Si problème persistant → suggestion d'action]

_Reboot debug • [timestamp]_
```

**Offline handling:**
```bash
# Try to send via Telegram
if hermes send --to telegram "$REPORT" 2>/dev/null; then
  echo "Report sent to Telegram"
else
  # Network is down — queue for later delivery
  echo "$REPORT" >> /var/tmp/pi-health-pending-reports.txt
  echo "Report queued — will be sent when network returns"
  # Also write to /tmp for manual inspection
  echo "$REPORT" > /tmp/reboot-report.txt
fi
```

The pi-health-monitor cron job will detect when network returns and flush pending reports automatically.

## Pitfalls
- Wait for network-online before running — the service handles this
- If network is down, ALWAYS cache the report to `/var/tmp/pi-health-pending-reports.txt` — it will be sent when the pi-health-monitor detects network recovery
- Don't spend more than 2 minutes on diagnostics — keep the report short
- If vcgencmd is unavailable, skip temperature checks gracefully
- Read pre-reboot health state from `/var/tmp/pi-health-state.json` — this tells you if the crash was preceded by high temp, low memory, or network issues
- Coordinate with pi-health-monitor: it handles ongoing monitoring, you handle the post-reboot one-time diagnosis