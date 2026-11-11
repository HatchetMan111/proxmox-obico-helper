#!/usr/bin/env bash
# ===============================================================
# Obico Server – Proxmox Helper Script
# Installiert den Obico Server (Docker) bis zum ersten Login
# in einen unprivilegierten LXC-Container auf Proxmox VE.
#
# - Ubuntu-Template wird dynamisch per pveam ermittelt
#   (keine hartcodierte Version → kein „no such template")
# - Django-Site wird automatisch auf die Container-IP gesetzt
# - Der erste registrierte Benutzer wird automatisch Admin
# ===============================================================

set -euo pipefail

# --- Farbcodes ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- Konfiguration ---
APP="Obico Server"
BRIDGE="vmbr0"
STORAGE="local-lvm"
OS_VERSION="22.04"
GIT_URL="https://github.com/TheSpaghettiDetective/obico-server.git"

err()  { echo -e "${RED}❌ $*${NC}" >&2; }
ok()   { echo -e "${GREEN}✓ $*${NC}"; }
info() { echo -e "${CYAN}ℹ️  $*${NC}"; }
warn() { echo -e "${YELLOW}⚠️  $*${NC}"; }
die()  { err "$*"; exit 1; }

TMP_INSTALL=""
cleanup() { if [[ -n "$TMP_INSTALL" ]]; then rm -f "$TMP_INSTALL"; fi; }
trap cleanup EXIT
trap 'err "Installation abgebrochen (Fehler in Zeile $LINENO)."' ERR

# --- Voraussetzungen ---
[[ $EUID -eq 0 ]] || die "Bitte als root auf dem Proxmox VE Host ausführen (nicht im Container)."
for cmd in pct pveam pvesm qm curl openssl; do
    command -v "$cmd" >/dev/null 2>&1 || die "'$cmd' nicht gefunden – ist das ein Proxmox VE Host?"
done

clear
cat << "EOF"
╔═══════════════════════════════════════╗
║     OBICO SERVER INSTALLATION         ║
║       für Proxmox LXC Container       ║
╚═══════════════════════════════════════╝
EOF
echo ""
echo "Installiert Obico Server (Docker, SQLite) bis zum ersten Login."
echo "Die Django-Site wird automatisch auf die Container-IP gesetzt."
echo ""

# --- User Input mit Validierung ---
DEFAULT_CTID=$(pvesh get /cluster/nextid 2>/dev/null || echo 200)
while :; do
    read -rp "Container ID (Standard: ${DEFAULT_CTID}): " CTID
    CTID=${CTID:-$DEFAULT_CTID}
    if ! [[ $CTID =~ ^[0-9]+$ ]]; then
        err "Bitte eine numerische Container-ID angeben."
        continue
    fi
    if pct status "$CTID" &>/dev/null; then
        err "LXC-Container ${CTID} existiert bereits (löschen mit: pct destroy ${CTID})."
        continue
    fi
    if qm status "$CTID" &>/dev/null; then
        err "VM ${CTID} existiert bereits – ID ist belegt."
        continue
    fi
    break
done

while :; do
    read -rp "Hostname (Standard: obico): " HOSTNAME
    HOSTNAME=${HOSTNAME:-obico}
    [[ $HOSTNAME =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*$ ]] || { err "Hostname: nur Buchstaben, Zahlen und Bindestriche."; continue; }
    break
done

while :; do
    read -rp "CPU Cores (Standard: 2): " CORES
    CORES=${CORES:-2}
    [[ $CORES =~ ^[0-9]+$ ]] || { err "Bitte eine Zahl angeben."; continue; }
    break
done

while :; do
    read -rp "RAM in MB (Standard: 4096): " MEMORY
    MEMORY=${MEMORY:-4096}
    [[ $MEMORY =~ ^[0-9]+$ ]] || { err "Bitte eine Zahl angeben."; continue; }
    if (( MEMORY < 4096 )); then
        warn "Weniger als 4096 MB RAM: der erste Docker-Build (ml_api/PyTorch) kann scheitern oder sehr lange dauern."
    fi
    break
done

while :; do
    read -rp "Disk Size in GB (Standard: 30): " DISK
    DISK=${DISK:-30}
    [[ $DISK =~ ^[0-9]+$ ]] || { err "Bitte eine Zahl angeben."; continue; }
    if (( DISK < 15 )); then
        warn "Weniger als 15 GB: Docker-Images + Daten können knapp werden."
    fi
    break
done

while :; do
    read -rp "Storage für Root-Volume (Standard: ${STORAGE}): " STORAGE_IN
    STORAGE=${STORAGE_IN:-$STORAGE}
    if pvesm status -content rootdir 2>/dev/null | awk -v s="$STORAGE" 'NR>1 && $1==s {found=1} END {exit !found}'; then
        break
    fi
    err "Storage '${STORAGE}' existiert nicht oder unterstützt kein rootdir. Verfügbar:"
    pvesm status -content rootdir 2>/dev/null | awk 'NR>1 {print "    - "$1}' || true
done

while :; do
    read -rp "Netzwerk-Bridge (Standard: ${BRIDGE}): " BRIDGE_IN
    BRIDGE=${BRIDGE_IN:-$BRIDGE}
    if [[ -e "/sys/class/net/${BRIDGE}" ]]; then
        break
    fi
    err "Bridge '${BRIDGE}' nicht gefunden. Vorhandene Bridges:"
    found=0
    for net in /sys/class/net/*; do
        if [[ ${net##*/} == vmbr* ]]; then
            echo "    - ${net##*/}"
            found=1
        fi
    done
    if [[ $found == 0 ]]; then
        echo "    (keine vmbr* gefunden)"
    fi
done

read -rsp "Root-Passwort (leer = automatisch generieren): " ROOTPASS
echo ""
GENERATED_PASS=0
if [[ -z $ROOTPASS ]]; then
    ROOTPASS=$(openssl rand -hex 10)
    GENERATED_PASS=1
fi

echo ""
info "Zusammenfassung: CT ${CTID} · ${HOSTNAME} · ${CORES} Cores · ${MEMORY} MB RAM · ${DISK} GB auf ${STORAGE} · Bridge ${BRIDGE}"
read -rp "Installation starten? [J/n]: " CONFIRM
CONFIRM=${CONFIRM:-J}
if ! [[ $CONFIRM =~ ^[JjYy1]$ ]]; then
    info "Abgebrochen – es wurde nichts geändert."
    exit 0
fi

# --- Template dynamisch ermitteln (Fix: „no such template") ---
echo ""
echo "📦 Ubuntu-${OS_VERSION}-Template prüfen..."
pveam update >/dev/null 2>&1 || warn "pveam update fehlgeschlagen – verwende den vorhandenen Template-Index."
OS_PATTERN="${OS_VERSION//./\\.}"

TEMPLATE_FILE=$(pveam list local 2>/dev/null | grep -Eo "ubuntu-${OS_PATTERN}-standard_[0-9.]+-[0-9]+_amd64\.tar\.(zst|xz)" | sort -V | tail -1 || true)
if [[ -n $TEMPLATE_FILE ]]; then
    ok "Template bereits lokal vorhanden: ${TEMPLATE_FILE}"
else
    TEMPLATE_FILE=$(pveam available 2>/dev/null | grep -Eo "ubuntu-${OS_PATTERN}-standard_[0-9.]+-[0-9]+_amd64\.tar\.(zst|xz)" | sort -V | tail -1 || true)
    if [[ -z $TEMPLATE_FILE ]]; then
        die "Kein Ubuntu-${OS_VERSION}-Template im Index gefunden. Bitte prüfe die Ausgabe von 'pveam available'."
    fi
    echo "⬇️  Lade ${TEMPLATE_FILE} herunter..."
    pveam download local "$TEMPLATE_FILE"
fi
TEMPLATE="local:vztmpl/${TEMPLATE_FILE}"
ok "Verwende Template: ${TEMPLATE}"

# --- Container erstellen ---
echo ""
echo "🚀 Erstelle LXC-Container ${CTID}..."
pct create "$CTID" "$TEMPLATE" \
    -hostname "$HOSTNAME" \
    -cores "$CORES" \
    -memory "$MEMORY" \
    -rootfs "${STORAGE}:${DISK}" \
    -net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
    -unprivileged 1 \
    -features nesting=1,keyctl=1 \
    -onboot 1 \
    -password "$ROOTPASS" \
    -description "${APP} (Docker) – installiert am $(date '+%d.%m.%Y %H:%M')"
ok "Container erstellt."

pct start "$CTID"
echo "⏳ Warte auf Netzwerk des Containers..."
IP_ADDRESS=""
for _ in $(seq 1 45); do
    IP_ADDRESS=$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1}' | tr -d '\r\n' || true)
    if [[ $IP_ADDRESS =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        ok "IP-Adresse: ${IP_ADDRESS}"
        break
    fi
    IP_ADDRESS=""
    echo -n "."
    sleep 2
done
echo ""
if [[ -z $IP_ADDRESS ]]; then
    die "Konnte keine IP ermitteln (90 s). DHCP/Bridge prüfen. Der Container ${CTID} bleibt bestehen."
fi

# --- Installations-Script für den Container ---
echo ""
echo "📝 Erstelle Installations-Script..."
TMP_INSTALL=$(mktemp /tmp/obico-install.XXXXXX.sh)
SECRET_KEY=$(openssl rand -hex 32)

cat > "$TMP_INSTALL" <<'EOF_INSTALL'
#!/bin/bash
# Läuft im Inneren des LXC-Containers
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C.UTF-8
export LANG=C.UTF-8

echo "═══════════════════════════════════════"
echo "🔧 Systemvorbereitung"
echo "═══════════════════════════════════════"
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq git curl ca-certificates gnupg lsb-release

echo ""
echo "═══════════════════════════════════════"
echo "🐳 Docker CE installieren"
echo "═══════════════════════════════════════"
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
apt-get update -qq
apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker
docker --version
docker compose version

echo ""
echo "═══════════════════════════════════════"
echo "📥 Obico Server klonen"
echo "═══════════════════════════════════════"
cd /opt
rm -rf obico
git clone --depth 1 "$GIT_URL" obico
cd /opt/obico

echo ""
echo "═══════════════════════════════════════"
echo "⚙️  Konfiguration (.env)"
echo "═══════════════════════════════════════"
# Obico liest diese Werte per Compose-Interpolation; ALLOWED_HOSTS ist
# upstream auf ['*'] gesetzt, Datenbank ist SQLite (kein Postgres nötig).
cat > .env <<ENVFILE
DEBUG=True
DJANGO_SECRET_KEY=${SECRET_KEY}
CSRF_TRUSTED_ORIGINS=["http://${CONTAINER_IP}:3334","http://localhost:3334"]
ACCOUNT_ALLOW_SIGN_UP=True
SOCIAL_LOGIN=False
SITE_IS_PUBLIC=False
SITE_USES_HTTPS=False
ENVFILE
echo "✓ .env erstellt (Secret generiert, CSRF-Origins auf ${CONTAINER_IP}:3334)"

echo ""
echo "═══════════════════════════════════════"
echo "🏗️  Images bauen & Services starten (erster Build: mehrere Minuten)"
echo "═══════════════════════════════════════"
docker compose up -d

echo ""
echo "⏳ Warte auf Obico Web-Dienst (/hc/)..."
WEB_READY=0
for _ in $(seq 1 60); do
    if curl -fsS http://localhost:3334/hc/ >/dev/null 2>&1; then
        WEB_READY=1
        break
    fi
    echo -n "."
    sleep 5
done
echo ""
if [[ $WEB_READY == 1 ]]; then
    echo "✓ Obico Web-Dienst ist erreichbar"
else
    echo "⚠️  Web-Dienst nach 5 Minuten nicht erreichbar – Migrationen können noch laufen."
    echo "    Logs: docker compose -f /opt/obico/docker-compose.yml logs -f web"
fi

echo ""
echo "═══════════════════════════════════════"
echo "🌐 Django-Site konfigurieren"
echo "═══════════════════════════════════════"
if docker compose exec -T web python manage.py shell -c "
from django.contrib.sites.models import Site
s, _ = Site.objects.get_or_create(pk=1)
s.domain = '${CONTAINER_IP}:3334'
s.name = 'Obico Server'
s.save()
print('Site-Domain gesetzt auf:', s.domain)
"; then
    echo "✓ Django-Site: ${CONTAINER_IP}:3334"
else
    echo "⚠️  Django-Site konnte nicht automatisch gesetzt werden – später über die Django-Admin-UI möglich."
fi

echo ""
echo "📊 Service-Status:"
docker compose ps
echo ""
echo "✅ Container-Installation abgeschlossen."
EOF_INSTALL

pct push "$CTID" "$TMP_INSTALL" /root/obico_install.sh
echo "🚀 Starte Installation im Container (Docker-Build kann dauern – nicht abbrechen)..."
pct exec "$CTID" -- env GIT_URL="$GIT_URL" CONTAINER_IP="$IP_ADDRESS" SECRET_KEY="$SECRET_KEY" bash /root/obico_install.sh
pct exec "$CTID" -- rm -f /root/obico_install.sh || true

# --- Finale Ausgabe ---
clear
cat << "EOF"
╔═══════════════════════════════════════╗
║     ✅ INSTALLATION ERFOLGREICH       ║
╚═══════════════════════════════════════╝
EOF
echo ""
echo "📦 Container ID    : $CTID"
echo "🏷️  Hostname        : $HOSTNAME"
if [[ $GENERATED_PASS == 1 ]]; then
    echo "🔑 Root Passwort   : $ROOTPASS   (automatisch generiert)"
else
    echo "🔑 Root Passwort   : $ROOTPASS"
fi
echo "🌐 IP-Adresse      : $IP_ADDRESS"
echo ""
echo -e "${GREEN}🌍 Obico läuft unter: http://${IP_ADDRESS}:3334${NC}"
echo ""
echo "📝 NÄCHSTE SCHRITTE:"
echo "   1️⃣  http://${IP_ADDRESS}:3334 im Browser öffnen"
echo "   2️⃣  Account registrieren – der erste Benutzer wird automatisch Admin"
echo "   3️⃣  Drucker anbinden (OctoPrint/Moonraker-Plugin) und Kamera hinzufügen"
echo ""
echo "💡 Tipp: Vergib im Router eine feste DHCP-Reservierung für die Container-IP,"
echo "   damit URL- und Django-Site-Konfiguration stabil bleiben."
echo ""
echo "🛠️  Nützliche Befehle:"
echo "   pct enter $CTID"
echo "   pct exec $CTID -- docker compose -f /opt/obico/docker-compose.yml ps"
echo "   pct exec $CTID -- docker compose -f /opt/obico/docker-compose.yml logs -f web"
echo "   pct exec $CTID -- docker compose -f /opt/obico/docker-compose.yml restart"
