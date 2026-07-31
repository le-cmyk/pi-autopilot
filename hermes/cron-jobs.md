# Hermes Cron Jobs

## Health Monitor — every 10 minutes

**Schedule**: `*/10 * * * *`
**Skill**: `pi-health-monitor`
**Deliver**: `origin` (Telegram DM)

**Prompt**:
```
Tu es le moniteur de santé du Raspberry Pi 5. Exécute la procédure du skill pi-health-monitor :

1. Lis /home/pi/.hermes/pi-state.yaml
2. Lis ou crée /var/tmp/pi-health-state.json
3. Vérifie : température (vcgencmd), réseau (ping 8.8.8.8), disque (df -h /), RAM (free -m), services critiques (systemctl)
4. Toutes les ~30 min : vérifie NVMe SMART (sudo nvme smart-log) — critical_warning, media_errors, available_spare, unsafe_shutdowns
5. Toutes les ~30 min : vérifie l'intégrité des fichiers critiques (sha256sum vs backup manifest) + lance backup-critical-files.sh
6. Compare avec l'état précédent pour détecter les TRANSITIONS (ok→problème, problème→ok)
7. Si température >= 80°C : alerte Telegram. Si >= 85°C : alerte urgente.
8. Si réseau passe de UP à DOWN : note l'heure, tente recovery. Si passe de DOWN à UP : rapport de récupération + flush pending reports.
9. Si disque > 90% ou RAM < 200MB : alerte.
10. Si NVMe media_errors > 0, spare < 10%, ou critical_warning != 0 : alerte urgente.
11. Si fichier critique modifié ou disparu : alerte + restaure depuis backup si nécessaire.
12. Mets à jour /var/tmp/pi-health-state.json.
13. Règle d'or : NE PAS spammer. Envoyer SEULEMENT sur transition d'état. Max 1 alerte par 15 min par type.
14. Si réseau down : stocke rapports dans /var/tmp/pi-health-pending-reports.txt.
```

---

## Daily Briefing — 8:00 AM Paris time

**Schedule**: `0 8 * * *`
**Deliver**: `origin` (Telegram DM)

**Prompt**:
```
Tu es un assistant qui prépare un briefing matinal quotidien. Tu dois livrer un résumé concis, structuré et agréable à lire, envoyé sur Telegram.

1. Météo du jour à Paris — température min/max, conditions, conseil vestimentaire
2. Titres du jour — 4 à 6 titres importants, mix France et international
3. À savoir aujourd'hui — jour férié, événement notable (optionnel)

Format : Markdown concis (< 1500 caractères), ton neutre mais chaleureux.
Termine par "_Bonne journée !_ ☕"
```

---

## Hermes CLI Commands

```bash
# Create health monitor
hermes cron create "*/10 * * * *" \
  --name "Pi Health Monitor" \
  --skill pi-health-monitor \
  --deliver origin

# Create daily briefing
hermes cron create "0 8 * * *" \
  --name "Briefing matinal 8h" \
  --deliver origin

# List all jobs
hermes cron list

# Run a job manually
hermes cron run <job-id>

# View job details
hermes cron show <job-id>

# Pause / Resume
hermes cron pause <job-id>
hermes cron resume <job-id>

# Remove
hermes cron remove <job-id>
```