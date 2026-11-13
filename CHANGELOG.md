# Changelog

Alle wichtigen Änderungen an diesem Projekt.

## [2.0.0] – 2026-11-13

### Behoben

- **Kritisch:** `pct create` schlug mit `can't open '/var/lib/lxc/<ID>/rootfs/etc/lsb-release'`
  fehl, weil automatisch das neueste Ubuntu-Template (26.10) gewählt wurde.
  Ubuntu 26.10 enthält `/etc/lsb-release` nicht mehr. Das Script verwendet jetzt
  ausschließlich geprüfte LTS-Templates (Ubuntu 24.04/22.04, Debian 13/12),
  validiert das Template-Archiv vorab und wechselt bei einem Fehlschlag
  automatisch zum nächsten Template.
- Falsche Dokumentation/Annahme „der erste registrierte Benutzer wird Admin".
  Obico legt per Migration `root@example.com` mit dem Passwort `supersecret` an.
- `DEBUG=True` in der Obico-Konfiguration (nun `False`, wie von Obico empfohlen).
- Docker-Repo-Codename wurde per `lsb_release -cs` ermittelt; das schlägt in
  Distributionen ohne `lsb-release` fehl. Jetzt wird `/etc/os-release`
  (`VERSION_CODENAME`) verwendet.
- Hartcodierte Vorgaben (`local-lvm`, `vmbr0`, `local`) werden durch
  automatische Erkennung ersetzt.
- Die Wartezeit auf den Web-Dienst war zu kurz und lieferte bei Fehlern keine
  Diagnose. Jetzt 10 Minuten, mit Log-Ausgabe und Host-seitiger Verifikation.

### Hinzugefügt

- Automatisches Setzen eines sicheren Admin-Passworts (statt `supersecret`).
- Optionales Aktivieren der Benutzer-Registrierung (standardmäßig aus).
- Helfer `obico-set-site <IP>` im Container zum Ändern der Django-Site.
- Idempotenter Container-Installer (`/root/obico_install.sh`) für Wiederholungen
  ohne Datenverlust, inkl. Beibehaltung des Django-Secret-Keys.
- Zugangsdaten und Befehle in `/root/obico-<CTID>-access.txt` (Modus 600).
- Docker-Fallback auf Distributionspakete und auf den `vfs`-Storage-Treiber
  (z. B. bei ZFS-Rootfs).
- Unbeaufsichtigter Modus (`--yes`) und `--help`/`--version`.
- ShellCheck-CI und Sandbox-Tests (`tests/sandbox-test.sh`).

## [1.0.0]

- Erste Version: LXC-Container, Docker CE, Obico Server, automatische
  Django-Site-Konfiguration.
