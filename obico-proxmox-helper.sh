#!/usr/bin/env bash
# ===============================================================
# Obico Server - Proxmox Helper Script (Local Installation)
# Author: GPT-5 (Verbessert von Gemini)
# FIXES: WEB_HOST=0.0.0.0 & Automatischer Server-Init (500 Fehler)
# ===============================================================

set -e
APP="Obico Server"
OSTYPE="ubuntu"
OSVERSION="22.04"
BRIDGE="vmbr0"
GIT_URL="https://github.com/TheSpaghettiDetective/obico-server.git"

# --- Standardwerte für die Obico-Initialisierung ---
OBICO_ADMIN_EMAIL="obicoadmin@local.host"
OBICO_ADMIN_PASS="obicoAdminPass123"

# --- Banner ---
clear
echo -e "\e[1;36m──────────────────────────────────────────────"
echo "    🧠 ${APP} - Proxmox Interactive Installer"
echo "──────────────────────────────────────────────\e[0m"

# --- Check PVE ---
if ! command -v pveversion >/dev/null 2>&1; then
  echo "❌  Dieses Script muss auf einem Proxmox Host ausgeführt werden!"
  exit 1
fi

# --- User Input ---
read -p "🆔 Container ID (leer = auto): " CTID
CTID=${CTID:-$(pvesh get /cluster/nextid)}

read -p "🖥️   Hostname [obico]: " HOSTNAME
HOSTNAME=${HOSTNAME:-obico}

read -p "💾 Disk Size in GB [15]: " DISK
DISK=${DISK:-15}

read -p "🧠 Memory in MB [2048]: " MEMORY
MEMORY=${MEMORY:-2048}

read -p "⚙️   CPU Cores [2]: " CORE
CORE=${CORE:-2}

read -p "🔐 Root Passwort für Container [obicoAdmin]: " ROOTPASS
ROOTPASS=${ROOTPASS:-obicoAdmin}

echo -e "\n🚀 Starte Installation von ${APP} im Container #${CTID}...\n"

# --- Find valid template storage automatically ---
TEMPLATE_STORE=$(pvesm status | awk '/dir/ && /active/ {print $1; exit}')
LATEST_TEMPLATE=$(pveam available | grep ubuntu | grep standard | tail -n 1 | awk '{print $2}')
TEMPLATE="${TEMPLATE_STORE}:vztmpl/${LATEST_TEMPLATE}"

# --- Template herunterladen falls nötig ---
if ! pveam list $TEMPLATE_STORE | grep -q "$(basename $LATEST_TEMPLATE)"; then
  echo "📦 Lade Ubuntu Template (${LATEST_TEMPLATE}) herunter..."
  pveam download $TEMPLATE_STORE $LATEST_TEMPLATE
fi

# --- LXC erstellen ---
pct create $CTID $TEMPLATE \
  -hostname $HOSTNAME \
  -cores $CORE \
  -memory $MEMORY \
  -rootfs local-lvm:${DISK} \
  -net0 name=eth0,bridge=$BRIDGE,ip=dhcp \
  -unprivileged 1 \
  -features nesting=1,keyctl=1 \
  -onboot 1 \
  -password "$ROOTPASS" \
  -description "${APP} (Docker)"

pct start $CTID
echo "⏳ Warte 10 Sekunden, bis der Container gebootet ist..."
sleep 10

# --- Installation & Initialisierung im Container ---
echo "🐳  Installiere Docker & ${APP}..."
pct exec $CTID -- bash -e <<EOF

# Warten auf Netzwerkverbindung
sleep 5 

# System aktualisieren und Docker installieren
apt update && apt upgrade -y
apt install -y git curl docker.io docker-compose-v2
systemctl enable --now docker

# Obico Klonen
cd /opt
git clone ${GIT_URL} obico
cd obico

# --- .env Datei erstellen und konfigurieren ---
if [ -f ".env.sample" ]; then
  cp .env.sample .env
elif [ -f ".env.template" ]; then
  cp .env.template .env
elif [ -f "compose.env.sample" ]; then
  cp compose.env.sample .env
else
  # Minimales .env erstellen, falls kein Template gefunden wird
  echo "POSTGRES_PASSWORD=obicodbpass" > .env
  echo "REDIS_PASSWORD=obico123" >> .env
  echo "WEB_HOST=0.0.0.0" >> .env
fi

# Passwörter und Host in .env setzen/überschreiben
sed -i 's#POSTGRES_PASSWORD=.*#POSTGRES_PASSWORD=obicodbpass#' .env
sed -i 's#REDIS_PASSWORD=.*#REDIS_PASSWORD=obico123#' .env
sed -i 's#WEB_HOST=.*#WEB_HOST=0.0.0.0#' .env

# --- Docker Compose Datei finden ---
COMPOSE_FILE=""
if [ -f "docker-compose.yml" ]; then
  COMPOSE_FILE="docker-compose.yml"
elif [ -f "compose/docker-compose.yml" ]; then
  COMPOSE_FILE="compose/docker-compose.yml"
elif [ -f "compose.yaml" ]; then
  COMPOSE_FILE="compose.yaml"
else
  echo "❌ Keine Docker Compose Datei gefunden! Bitte überprüfe das Repo."
  exit 1
fi

echo "🚀 Starte Obico Server Komponenten..."
docker compose -f "${COMPOSE_FILE}" up -d

# --- Initialisierung (Fix für 500 Error: Site matching query does not exist) ---
echo "⚙️  Warte auf Datenbank-Start und initialisiere Obico..."
sleep 15 # Zusätzliche Wartezeit, damit die Datenbank wirklich bereit ist

# 1. Migrationen anwenden
echo "➡️  Führe Datenbank-Migrationen durch..."
docker compose run --rm web python manage.py migrate --noinput

# 2. Obico Initialisierung (Site-Eintrag und Admin-Benutzer erstellen)
# Wir nutzen 'echo' zur automatischen Eingabe von E-Mail/Passwort.
echo "➡️  Erstelle Obico Admin-Benutzer (${OBICO_ADMIN_EMAIL})..."
echo -e "${OBICO_ADMIN_EMAIL}\n${OBICO_ADMIN_PASS}\n${OBICO_ADMIN_PASS}" | docker compose run --rm web python manage.py obico_server_init

# 3. Web-Dienst neu starten, um alle Änderungen zu übernehmen
echo "🔄 Starte Obico Web-Dienst neu..."
docker compose restart web

EOF

# --- Ausgabe ---
clear
# IP-Adresse dynamisch und sicher abrufen
echo "⏳ Warte auf die Zuweisung der IP-Adresse..."
IP_ADDRESS=""
while [ -z "$IP_ADDRESS" ]; do
  sleep 2
  IP_ADDRESS=$(pct exec $CTID -- hostname -I | awk '{print $1}')
done

echo -e "\e[1;32m✅ ${APP} erfolgreich installiert und initialisiert!\e[0m"
echo "──────────────────────────────────────────────"
echo "📦 Container-ID : $CTID"
echo "🧱 Admin-Setup    : /opt/obico im Container"
echo "🔑 Root Passwort  : $ROOTPASS"
echo "──────────────────────────────────────────────"
echo -e "\e[1;33m⚠️ Admin Zugangsdaten für Obico Server (3334):"
echo "    E-Mail: ${OBICO_ADMIN_EMAIL}"
echo "    Passwort: ${OBICO_ADMIN_PASS}\e[0m"
echo "──────────────────────────────────────────────"
echo "🌐 Obico läuft unter: http://${IP_ADDRESS}:3334"
echo "💡 Öffne den Link im Browser und melde dich mit den obigen Daten an."
echo "──────────────────────────────────────────────"
