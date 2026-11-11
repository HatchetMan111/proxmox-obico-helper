# 🧠 Proxmox Helper Script — Obico Server (Local Install)

Interaktiver Installer, der einen vollwertigen **Obico-Server** („The Spaghetti Detective") als LXC-Container auf deinem **Proxmox VE Host** aufsetzt — inklusive Docker CE, automatischer Django-Site-Konfiguration und fertigem Web-Login. Alles lokal in deinem Netzwerk, ohne SSL oder Domain.

[![Proxmox](https://img.shields.io/badge/Proxmox-VE%207%2F8-orange?logo=proxmox)](https://www.proxmox.com)
[![Ubuntu](https://img.shields.io/badge/Ubuntu-22.04%20LTS-blue?logo=ubuntu)](https://ubuntu.com)
[![Docker](https://img.shields.io/badge/Docker-CE%20%2B%20Compose-2496ED?logo=docker&logoColor=white)](https://www.docker.com)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

---

## 🚀 Ein-Klick-Installation

Als **root auf dem Proxmox-Host** ausführen (nicht in einem Container):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/HatchetMan111/proxmox-obico-helper/main/obico-proxmox-helper.sh)
```

## 🧩 Was das Script macht

1. **Interaktive Abfrage** mit validierten Defaults: Container-ID (freie ID wird vorgeschlagen), Hostname, CPU, RAM, Disk, Storage, Bridge, Root-Passwort (leere Eingabe → automatisch generiertes Passwort)
2. **Template dynamisch ermitteln:** `pveam update` + automatisch die aktuell verfügbare Ubuntu-22.04-Vorlage wählen — kein hartcodierter Dateiname mehr (Fix für den Fehler `template: no such template`)
3. **LXC-Container erstellen:** unprivilegiert, mit `nesting=1,keyctl=1` (Pflicht für Docker-in-LXC)
4. **Docker CE + Compose-Plugin** aus dem offiziellen Docker-APT-Repo installieren
5. **Obico Server klonen** und konfigurieren: generierter `DJANGO_SECRET_KEY`, `CSRF_TRUSTED_ORIGINS` (JSON-Format, wie Obico es erwartet) auf die Container-IP, Sign-up aktiviert
6. **Alle Services bauen & starten:** `web`, `ml_api`, `tasks`, `redis` — Datenbank ist **SQLite**, kein Postgres nötig. Migrationen und `collectstatic` laufen automatisch beim Web-Start
7. **Warten auf den Health-Endpoint** (`/hc/`) und die **Django-Site automatisch auf `http://<Container-IP>:3334` setzen**

## ⚙️ Systemanforderungen

| Komponente  | Empfehlung          |
|-------------|---------------------|
| Proxmox VE  | 7.x oder 8.x        |
| Template    | Ubuntu 22.04 LTS (läd das Script automatisch) |
| RAM         | ≥ 4 GB (der erste Docker-Build von `ml_api`/PyTorch ist speicherhungrig) |
| Storage     | ≥ 15 GB             |
| CPU         | ≥ 2 Cores           |

## 🔑 Erste Anmeldung

1. `http://<Container-IP>:3334` im Browser öffnen
2. Als **erster Benutzer registrieren** — der erste Account wird automatisch Site-Admin
3. In Obico den Drucker anbinden (OctoPrint- bzw. Moonraker-Plugin) und die Kamera hinzufügen

> 💡 **Tipp:** Im Router eine feste DHCP-Reservierung für die Container-IP vergeben. Wenn sich die IP später ändert, die Django-Site anpassen:
>
> ```bash
> pct exec <CTID> -- docker compose -f /opt/obico/docker-compose.yml exec -T web python manage.py shell -c "from django.contrib.sites.models import Site; s = Site.objects.get(pk=1); s.domain = 'NEUE_IP:3334'; s.save()"
> ```

## 🛠️ Nützliche Befehle

```bash
# In den Container wechseln
pct enter <CTID>

# Service-Status / Logs
pct exec <CTID> -- docker compose -f /opt/obico/docker-compose.yml ps
pct exec <CTID> -- docker compose -f /opt/obico/docker-compose.yml logs -f web

# Services neu starten
pct exec <CTID> -- docker compose -f /opt/obico/docker-compose.yml restart

# Komplett entfernen
pct stop <CTID> && pct destroy <CTID>
```

## 🆘 Troubleshooting

| Problem | Lösung |
|---|---|
| `template: no such template` | Behoben — das Script ermittelt die Template-Version jetzt dynamisch per `pveam`. Falls es trotzdem auftritt: `pveam update` manuell ausführen und erneut starten |
| `Container/VM <ID> existiert bereits` | Andere ID wählen oder aufräumen: `pct destroy <ID>` |
| Erster Aufruf der Weboberfläche lädt lange | Der erste Build (`ml_api`, PyTorch) dauert mehrere Minuten — geduldig bleiben, Logs mit `logs -f web` verfolgen |
| Keine IP-Adresse nach 90 s | DHCP/Bridge prüfen (`brctl show`, DHCP-Bereich des Routers); Container bleibt bestehen und kann mit `pct start <CTID>` erneut geprüft werden |
| IP hat sich geändert, Obico nicht erreichbar | Django-Site auf neue IP setzen (Befehl oben) |

## 🧠 Über Obico

[Obico](https://github.com/TheSpaghettiDetective/obico-server) (früher The Spaghetti Detective) ist eine Open-Source-KI-Plattform zur Echtzeit-Überwachung deiner 3D-Drucker — sie erkennt Spaghetti (Fehldrucke), bevor der ganze Druck versaut ist. Dieses Script richtet den Server **lokal** ein.

---

Entwickelt mit ❤️ für Maker & 3D-Druck-Enthusiasten.

📄 Lizenz: MIT — siehe [LICENSE](LICENSE)
