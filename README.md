# 🧠 Proxmox Helper Script — Obico Server (Local Install)

Interaktiver Installer, der einen vollwertigen **Obico-Server** („The Spaghetti Detective") als LXC-Container auf deinem **Proxmox VE Host** aufsetzt — inklusive Docker CE, automatischer Django-Site-Konfiguration und fertigem Web-Login. Alles lokal in deinem Netzwerk, ohne SSL oder Domain.

[![Proxmox](https://img.shields.io/badge/Proxmox-VE%207%2F8%2F9-orange?logo=proxmox)](https://www.proxmox.com)
[![Ubuntu](https://img.shields.io/badge/Ubuntu%20LTS-24.04%20%7C%2022.04-blue?logo=ubuntu)](https://ubuntu.com)
[![Docker](https://img.shields.io/badge/Docker-CE%20%2B%20Compose-2496ED?logo=docker&logoColor=white)](https://www.docker.com)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![ShellCheck](https://img.shields.io/badge/ShellCheck-clean-success?logo=gnubash)](https://www.shellcheck.net)

---

## 🚀 Ein-Klick-Installation

Als **root auf dem Proxmox-Host** ausführen (nicht in einem Container):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/HatchetMan111/proxmox-obico-helper/main/obico-proxmox-helper.sh)
```

Unbeaufsichtigt mit Standardwerten:

```bash
OBICO_CTID=112 OBICO_ADMIN_PASSWORD='MeinSicheresPasswort' \
  bash <(curl -fsSL https://raw.githubusercontent.com/HatchetMan111/proxmox-obico-helper/main/obico-proxmox-helper.sh) --yes
```

Alle Optionen: `bash obico-proxmox-helper.sh --help`

## ✨ Neu in v2 (wichtigste Fixes)

| Problem in v1 | Lösung in v2 |
|---|---|
| `unable to create CT … can't open '…/etc/lsb-release'` | Es werden **nur noch geprüfte LTS-Templates** verwendet (Ubuntu 24.04/22.04, Debian 13/12). Ubuntu 26.10 enthält kein `/etc/lsb-release` mehr und ist für Proxmox nicht nutzbar. Zusätzlich prüft das Script das Template-Archiv vor dem Erstellen und weicht automatisch auf das nächste Template aus. |
| `lsb_release -cs` schlägt in neuen Ubuntu-Versionen fehl | Der Docker-Codename kommt jetzt aus `/etc/os-release` (`VERSION_CODENAME`), mit Fallback auf die Distribution-Pakete. |
| Falsche Aussage „der erste Benutzer wird Admin" | Obico legt per Migration einen Admin `root@example.com` mit dem öffentlich dokumentierten Passwort `supersecret` an. Das Script **ersetzt dieses Passwort** durch ein zufälliges bzw. selbst gewähltes. |
| `DEBUG=True` in `.env` | `DEBUG=False` (offizielle Obico-Empfehlung), inkl. Verifikation, dass die Login-Seite mit Statics wirklich lädt. |
| Hartcodiertes `local-lvm` / `vmbr0` / `local` | Storage, Bridge und Template-Storage werden automatisch erkannt (überschreibbar). |
| Warteschleife nach 5 Minuten aufgegeben | 10 Minuten Wartezeit, Log-Ausgabe bei Fehlern, ML-API-Status und Prüfung vom Host aus. |
| Bei Fehler keine Hilfe | Klare Wiederaufnahme (`pct exec <CTID> -- bash /root/obico_install.sh`), idempotenter Installer, Zugangsdaten in `/root/obico-<CTID>-access.txt`. |

## 🧩 Was das Script macht

1. **Interaktive Abfrage** mit validierten Defaults: Container-ID (freie ID wird vorgeschlagen), Hostname, CPU, RAM, Disk, Storage, Bridge, Admin-E-Mail, Admin-Passwort, optionale Registrierung, Root-Passwort
2. **Template-Auswahl:** `pveam update` + priorisierte LTS-Templates. Jedes Ubuntu-Template wird vorab auf `/etc/lsb-release` geprüft; bei einem Fehlschlag von `pct create` wird automatisch das nächste Template probiert
3. **LXC-Container erstellen:** unprivilegiert, mit `nesting=1,keyctl=1` (Pflicht für Docker-in-LXC)
4. **Docker CE + Compose-Plugin** aus dem offiziellen Docker-APT-Repo — mit automatischem Fallback auf die Distributionspakete
5. **Obico Server klonen** (Branch `release`) und konfigurieren: generierter `DJANGO_SECRET_KEY`, `CSRF_TRUSTED_ORIGINS` für IP/Hostname, `DEBUG=False`, optional Registrierung
6. **Alle Services bauen & starten:** `web`, `ml_api`, `tasks`, `redis` — Datenbank ist **SQLite**, kein Postgres nötig. Migrationen und `collectstatic` laufen automatisch beim Web-Start
7. **Warten auf Health-Endpoint & Login-Seite**, Django-Site auf `http://<Container-IP>:3334` setzen, **Admin-Passwort ersetzen**
8. **Verifizieren** vom Proxmox-Host aus und Zugangsdaten/Befehle in `/root/obico-<CTID>-access.txt` ablegen

## ⚙️ Systemanforderungen

| Komponente  | Empfehlung          |
|-------------|---------------------|
| Proxmox VE  | 7.x, 8.x oder 9.x   |
| Template    | Ubuntu 24.04/22.04 LTS oder Debian 13/12 — das Script wählt automatisch |
| RAM         | ≥ 4 GB (der erste Docker-Build von `ml_api`/PyTorch ist speicherhungrig) |
| Storage     | ≥ 30 GB (Docker-Images + Daten) |
| CPU         | ≥ 2 Cores           |

## 🔑 Erste Anmeldung

1. `http://<Container-IP>:3334` im Browser öffnen
2. Mit dem **Admin-Konto** anmelden, das das Script am Ende ausgibt (E-Mail + Passwort). Es steht zusätzlich in `/root/obico-<CTID>-access.txt` auf dem Proxmox-Host.
3. Django-Admin: `http://<Container-IP>:3334/admin/`
4. In Obico den Drucker anbinden (OctoPrint- bzw. Moonraker-Plugin) und die Kamera hinzufügen

> 🔐 **Sicherheit:** Das upstream-dokumentierte Standardpasswort `supersecret` wird automatisch ersetzt. Neue Registrierungen sind standardmäßig **deaktiviert**; weitere Benutzer lassen sich im Django-Admin anlegen oder über `ACCOUNT_ALLOW_SIGN_UP=True` in `/opt/obico/.env` freischalten.
>
> 💡 **Tipp:** Im Router eine feste DHCP-Reservierung für die Container-IP vergeben. Wenn sich die IP später ändert, die Django-Site anpassen:
>
> ```bash
> pct exec <CTID> -- obico-set-site 192.168.1.50
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

# Django-Site auf neue IP/neuen Hostnamen setzen
pct exec <CTID> -- obico-set-site 192.168.1.50

# Installation im Container erneut ausführen (Datenbank bleibt erhalten)
pct exec <CTID> -- bash /root/obico_install.sh

# Komplett entfernen
pct stop <CTID> && pct destroy <CTID>
```

## 🔄 Update & Backup

```bash
# Obico aktualisieren (git-Reset auf den release-Branch + Rebuild)
pct exec <CTID> -- bash /root/obico_install.sh

# Backup der Obico-Datenbank
pct exec <CTID> -- tar czf /root/obico-backup.tar.gz /opt/obico/backend/db.sqlite3 /opt/obico/backend/static_build/media
pct pull <CTID> /root/obico-backup.tar.gz ./obico-backup.tar.gz
```

## 🆘 Troubleshooting

| Problem | Lösung |
|---|---|
| `unable to create CT … can't open '/var/lib/lxc/<ID>/rootfs/etc/lsb-release'` | Behoben in v2: Ubuntu 26.10 (und andere neue Nicht-LTS-Releases) enthalten `/etc/lsb-release` nicht mehr, Proxmox kann daraus keinen Container bauen. Das Script nutzt nur noch geprüfte LTS-Templates und prüft das Archiv vorab. Manuell: Template in der Proxmox-GUI auf `ubuntu-24.04-standard` stellen bzw. `OBICO_TEMPLATE=ubuntu-24.04-standard_…_amd64.tar.zst` setzen. |
| `Kein geeignetes LTS-Template im pveam-Index` | `pveam update` manuell ausführen, Netzwerk/DNS prüfen und in der Proxmox-GUI unter *Local → CT Templates* ein Ubuntu-24.04- oder Debian-12-Template laden. |
| `Container/VM <ID> existiert bereits` | Andere ID wählen oder aufräumen: `pct destroy <ID>` |
| Erster Aufruf der Weboberfläche lädt lange | Der erste Build (`ml_api`, PyTorch) dauert 15–30 Minuten. Logs: `pct exec <CTID> -- docker compose -f /opt/obico/docker-compose.yml logs -f ml_api` |
| Keine IP-Adresse nach 120 s | DHCP/Bridge prüfen (`brctl show`, DHCP-Bereich des Routers); Container bleibt bestehen und kann mit `pct start <CTID>` erneut geprüft werden |
| Docker startet im Container nicht | Passiert z. B. auf ZFS-Rootfs mit `overlay2`. Das Script weicht automatisch auf den `vfs`-Treiber aus (langsamer, mehr Speicherbedarf) und informiert darüber. |
| Build bricht mit OOM ab | RAM auf ≥ 4 GB (besser 6–8 GB) erhöhen und `pct exec <CTID> -- bash /root/obico_install.sh` erneut ausführen. |
| IP hat sich geändert, Obico nicht erreichbar | `pct exec <CTID> -- obico-set-site <neue-IP>` |
| Login geht nicht mehr | Admin-Passwort neu setzen: `pct exec <CTID> -- bash /root/obico_install.sh` (setzt das Passwort aus `/root/obico-setup.conf`) oder im Django-Admin zurücksetzen. |

## 🧪 Entwicklung & Tests

```bash
# Syntax + Lint
bash -n obico-proxmox-helper.sh
shellcheck -S warning obico-proxmox-helper.sh

# Sandbox-Test ohne Proxmox (mockt pct/pveam/pvesm und prüft u. a.
# Template-Fallback, Fehlerpfade und die erzeugten Dateien)
bash tests/sandbox-test.sh
```

Die CI (`.github/workflows/lint.yml`) führt ShellCheck, Syntaxprüfung und den Sandbox-Test bei jedem Push aus.

## 🧠 Über Obico

[Obico](https://github.com/TheSpaghettiDetective/obico-server) (früher The Spaghetti Detective) ist eine Open-Source-KI-Plattform zur Echtzeit-Überwachung deiner 3D-Drucker — sie erkennt Spaghetti (Fehldrucke), bevor der ganze Druck versaut ist. Dieses Script richtet den Server **lokal** ein.

---

Entwickelt mit ❤️ für Maker & 3D-Druck-Enthusiasten.

📄 Lizenz: MIT — siehe [LICENSE](LICENSE)
