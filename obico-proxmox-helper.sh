#!/usr/bin/env bash
# ===============================================================
# Obico Server - Proxmox Helper Script (Verbesserte Version V10)
# Fixes: Error 500, Django Site Konfiguration, Externe Zugriffe
# ===============================================================

set -e
APP="Obico Server"
OSTYPE="ubuntu"
OSVERSION="22.04"
BRIDGE="vmbr0"
GIT_URL="https://github.com/TheSpaghettiDetective/obico-server.git"

# --- Konfiguration ---
DB_PASS="obicodbpass"
REDIS_PASS="obico123"
ADMIN_EMAIL="admin@obico.local"
ADMIN_PASS="obicoAdminPass123"

# --- Farbcodes ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# --- Banner ---
clear
cat << "EOF"
╔═══════════════════════════════════════╗
║     OBICO SERVER INSTALLATION         ║
║       für Proxmox LXC Container       ║
╚═══════════════════════════════════════╝
EOF

echo ""
echo "Dieses Script installiert Obico Server in einem LXC Container"
echo ""

# --- User Input ---
read -p "Container ID (Standard: 200): " CTID
CTID=${CTID:-200}

read -p "Hostname (Standard: obico): " HOSTNAME
HOSTNAME=${HOSTNAME:-obico}

read -p "CPU Cores (Standard: 2): " CORE
CORE=${CORE:-2}

read -p "RAM in MB (Standard: 2048): " MEMORY
MEMORY=${MEMORY:-2048}

read -p "Disk Size in GB (Standard: 20): " DISK
DISK=${DISK:-20}

read -sp "Root Passwort: " ROOTPASS
echo ""
ROOTPASS=${ROOTPASS:-"proxmox"}

# --- Externe Domain/IP Konfiguration ---
echo ""
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}WICHTIG: Externe Zugriffskonfiguration${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "Gib die Domain oder IP-Adresse ein, über die Obico erreichbar sein soll:"
echo "Beispiele:"
echo "  - obico.meinedomain.de (mit Reverse Proxy)"
echo "  - 192.168.1.100 (Lokale IP)"
echo "  - obico.local (lokaler Hostname)"
echo ""
read -p "Domain/IP (Standard: auto-detect): " EXTERNAL_HOST

# --- Template Download ---
TEMPLATE="local:vztmpl/ubuntu-22.04-standard_22.04-1_amd64.tar.zst"
if ! pveam list local | grep -q "ubuntu-22.04"; then
    echo "📦 Lade Ubuntu 22.04 Template herunter..."
    pveam download local ubuntu-22.04-standard_22.04-1_amd64.tar.zst
fi

# --- Container erstellen ---
echo "🚀 Erstelle LXC Container..."
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
echo "⏳ Warte auf Container Boot (20 Sekunden)..."
sleep 20

# --- IP-Adresse ermitteln ---
echo "🔍 Ermittle Container IP-Adresse..."
IP_ADDRESS=""
for i in {1..30}; do 
  sleep 2
  IP_ADDRESS=$(pct exec $CTID -- hostname -I 2>/dev/null | awk '{print $1}' | tr -d '\n\r')
  
  if [ -n "$IP_ADDRESS" ] && [[ "$IP_ADDRESS" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo -e "${GREEN}✓ IP gefunden: $IP_ADDRESS${NC}"
    break
  fi
  echo -n "."
done
echo ""

if [ -z "$IP_ADDRESS" ]; then
    IP_ADDRESS="$HOSTNAME.local"
    echo -e "${YELLOW}⚠ Konnte IP nicht ermitteln. Verwende: ${IP_ADDRESS}${NC}"
fi

# Site Domain festlegen
if [ -n "$EXTERNAL_HOST" ]; then
    SITE_DOMAIN="$EXTERNAL_HOST"
else
    SITE_DOMAIN="$IP_ADDRESS"
fi

echo -e "${GREEN}🌐 Obico wird konfiguriert für: ${SITE_DOMAIN}${NC}"

# --- Hauptinstallation im Container ---
echo "🐳 Starte Installation im Container..."

pct exec $CTID -- bash -c "$(cat <<'CONTAINER_SCRIPT'
#!/bin/bash
set -e

# Funktion für Retry-Logik
retry_command() {
    local cmd="$1"
    local desc="$2"
    local max_attempts=20
    local attempt=1
    
    echo "⏳ $desc"
    while [ $attempt -le $max_attempts ]; do
        echo "   Versuch $attempt/$max_attempts..."
        if eval "$cmd" 2>&1; then
            echo "   ✓ Erfolgreich"
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 5
    done
    
    echo "   ✗ Fehlgeschlagen nach $max_attempts Versuchen"
    return 1
}

# Variablen aus Host übernehmen
DB_PASS="__DB_PASS__"
REDIS_PASS="__REDIS_PASS__"
ADMIN_EMAIL="__ADMIN_EMAIL__"
GIT_URL="__GIT_URL__"
SITE_DOMAIN="__SITE_DOMAIN__"
CONTAINER_IP="__CONTAINER_IP__"

echo "═══════════════════════════════════════"
echo "🔧 Systemvorbereitung"
echo "═══════════════════════════════════════"

# Grundsystem aktualisieren
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

# Docker installieren
echo "📦 Installiere Docker..."
apt-get install -y \
    curl \
    git \
    ca-certificates \
    gnupg \
    lsb-release

# Offizieller Docker GPG Key
mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg

# Docker Repository
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

systemctl enable docker
systemctl start docker

echo "═══════════════════════════════════════"
echo "📥 Obico Server klonen"
echo "═══════════════════════════════════════"

cd /opt
if [ -d "obico" ]; then
    rm -rf obico
fi

git clone ${GIT_URL} obico
cd /opt/obico

echo "═══════════════════════════════════════"
echo "⚙️  Konfiguration erstellen"
echo "═══════════════════════════════════════"

# .env Datei erstellen
cat > .env <<ENVFILE
# Datenbank
POSTGRES_PASSWORD=${DB_PASS}
POSTGRES_USER=obico
POSTGRES_DB=obico

# Redis
REDIS_PASSWORD=${REDIS_PASS}

# Django Settings
DEBUG=False
ALLOWED_HOSTS=${SITE_DOMAIN},${CONTAINER_IP},localhost,127.0.0.1
SITE_USES_HTTPS=False
SITE_IS_PUBLIC=True

# Email (Optional - später konfigurierbar)
EMAIL_HOST=localhost
EMAIL_PORT=25

# Obico Einstellungen
ACCOUNT_ALLOW_SIGN_UP=True
SOCIAL_LOGIN=False

# Web Server
WEB_HOST=0.0.0.0
WEB_PORT=3334

# Internes Netzwerk
INTERNAL_MEDIA_HOST=http://web:3334
OCTOPRINT_TUNNEL_PORT_RANGE=0-0
ENVFILE

echo "✓ .env Datei erstellt"

# Docker Compose Datei finden
COMPOSE_FILE=""
if [ -f "docker-compose.yml" ]; then
    COMPOSE_FILE="docker-compose.yml"
elif [ -f "compose/docker-compose.yml" ]; then
    COMPOSE_FILE="compose/docker-compose.yml"
else
    echo "❌ Keine docker-compose.yml gefunden!"
    exit 1
fi

echo "✓ Verwende: $COMPOSE_FILE"

# Docker Compose Datei anpassen für externe Zugriffe
cat > docker-compose.override.yml <<'OVERRIDE'
version: '3'
services:
  web:
    environment:
      - CSRF_TRUSTED_ORIGINS=http://${SITE_DOMAIN}
    ports:
      - "3334:3334"
    restart: unless-stopped
  
  ml_api:
    restart: unless-stopped
  
  db:
    restart: unless-stopped
    volumes:
      - db_data:/var/lib/postgresql/data
  
  redis:
    restart: unless-stopped

volumes:
  db_data:
OVERRIDE

echo "✓ docker-compose.override.yml erstellt"

echo "═══════════════════════════════════════"
echo "🚀 Docker Container starten"
echo "═══════════════════════════════════════"

docker compose -f "${COMPOSE_FILE}" pull
docker compose -f "${COMPOSE_FILE}" up -d

echo "⏳ Warte auf Datenbankstart (30 Sekunden)..."
sleep 30

echo "═══════════════════════════════════════"
echo "🗄️  Datenbank initialisieren"
echo "═══════════════════════════════════════"

# Migrationen mit Retry
retry_command \
    "docker compose -f '${COMPOSE_FILE}' exec -T db psql -U obico -d obico -c 'SELECT 1;'" \
    "Warte auf Datenbank..."

retry_command \
    "docker compose -f '${COMPOSE_FILE}' run --rm web python manage.py migrate --noinput" \
    "Führe Datenbankmigrationen aus..."

# Statische Dateien sammeln
echo "📦 Sammle statische Dateien..."
docker compose -f "${COMPOSE_FILE}" run --rm web python manage.py collectstatic --noinput || true

echo "═══════════════════════════════════════"
echo "🌐 Django Site konfigurieren"
echo "═══════════════════════════════════════"

# KRITISCH: Django Site korrekt setzen
# Methode 1: Via Django Shell (robuster)
docker compose -f "${COMPOSE_FILE}" run --rm web python manage.py shell <<PYTHON_SCRIPT
from django.contrib.sites.models import Site
try:
    site = Site.objects.get(id=1)
    site.domain = '${SITE_DOMAIN}'
    site.name = 'Obico Server'
    site.save()
    print(f'✓ Site aktualisiert: {site.domain}')
except Site.DoesNotExist:
    site = Site.objects.create(id=1, domain='${SITE_DOMAIN}', name='Obico Server')
    print(f'✓ Site erstellt: {site.domain}')
PYTHON_SCRIPT

# Alternative: Via Management Command (falls vorhanden)
docker compose -f "${COMPOSE_FILE}" run --rm web python manage.py shell -c "
from django.contrib.sites.models import Site
Site.objects.update_or_create(id=1, defaults={'domain': '${SITE_DOMAIN}', 'name': 'Obico Server'})
" 2>/dev/null || true

echo "═══════════════════════════════════════"
echo "🔄 Services neu starten"
echo "═══════════════════════════════════════"

docker compose -f "${COMPOSE_FILE}" restart

echo "⏳ Warte auf Service-Start (15 Sekunden)..."
sleep 15

# Status prüfen
echo ""
echo "📊 Container Status:"
docker compose -f "${COMPOSE_FILE}" ps

echo ""
echo "✅ Installation abgeschlossen!"

CONTAINER_SCRIPT
)"

# Variablen in Container-Script ersetzen
CONTAINER_SCRIPT_CONTENT=$(cat <<'CONTAINER_SCRIPT'
#!/bin/bash
set -e

# Funktion für Retry-Logik
retry_command() {
    local cmd="$1"
    local desc="$2"
    local max_attempts=20
    local attempt=1
    
    echo "⏳ $desc"
    while [ $attempt -le $max_attempts ]; do
        echo "   Versuch $attempt/$max_attempts..."
        if eval "$cmd" 2>&1; then
            echo "   ✓ Erfolgreich"
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 5
    done
    
    echo "   ✗ Fehlgeschlagen nach $max_attempts Versuchen"
    return 1
}

# Variablen aus Host übernehmen
DB_PASS="__DB_PASS__"
REDIS_PASS="__REDIS_PASS__"
ADMIN_EMAIL="__ADMIN_EMAIL__"
GIT_URL="__GIT_URL__"
SITE_DOMAIN="__SITE_DOMAIN__"
CONTAINER_IP="__CONTAINER_IP__"

echo "═══════════════════════════════════════"
echo "🔧 Systemvorbereitung"
echo "═══════════════════════════════════════"

# Grundsystem aktualisieren
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

# Docker installieren
echo "📦 Installiere Docker..."
apt-get install -y \
    curl \
    git \
    ca-certificates \
    gnupg \
    lsb-release

# Offizieller Docker GPG Key
mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg

# Docker Repository
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

systemctl enable docker
systemctl start docker

echo "═══════════════════════════════════════"
echo "📥 Obico Server klonen"
echo "═══════════════════════════════════════"

cd /opt
if [ -d "obico" ]; then
    rm -rf obico
fi

git clone ${GIT_URL} obico
cd /opt/obico

echo "═══════════════════════════════════════"
echo "⚙️  Konfiguration erstellen"
echo "═══════════════════════════════════════"

# .env Datei erstellen
cat > .env <<ENVFILE
# Datenbank
POSTGRES_PASSWORD=${DB_PASS}
POSTGRES_USER=obico
POSTGRES_DB=obico

# Redis
REDIS_PASSWORD=${REDIS_PASS}

# Django Settings
DEBUG=False
ALLOWED_HOSTS=${SITE_DOMAIN},${CONTAINER_IP},localhost,127.0.0.1
SITE_USES_HTTPS=False
SITE_IS_PUBLIC=True

# Email (Optional - später konfigurierbar)
EMAIL_HOST=localhost
EMAIL_PORT=25

# Obico Einstellungen
ACCOUNT_ALLOW_SIGN_UP=True
SOCIAL_LOGIN=False

# Web Server
WEB_HOST=0.0.0.0
WEB_PORT=3334

# Internes Netzwerk
INTERNAL_MEDIA_HOST=http://web:3334
OCTOPRINT_TUNNEL_PORT_RANGE=0-0
ENVFILE

echo "✓ .env Datei erstellt"

# Docker Compose Datei finden
COMPOSE_FILE=""
if [ -f "docker-compose.yml" ]; then
    COMPOSE_FILE="docker-compose.yml"
elif [ -f "compose/docker-compose.yml" ]; then
    COMPOSE_FILE="compose/docker-compose.yml"
else
    echo "❌ Keine docker-compose.yml gefunden!"
    exit 1
fi

echo "✓ Verwende: $COMPOSE_FILE"

# Docker Compose Datei anpassen für externe Zugriffe
cat > docker-compose.override.yml <<'OVERRIDE'
version: '3'
services:
  web:
    environment:
      - CSRF_TRUSTED_ORIGINS=http://${SITE_DOMAIN}
    ports:
      - "3334:3334"
    restart: unless-stopped
  
  ml_api:
    restart: unless-stopped
  
  db:
    restart: unless-stopped
    volumes:
      - db_data:/var/lib/postgresql/data
  
  redis:
    restart: unless-stopped

volumes:
  db_data:
OVERRIDE

echo "✓ docker-compose.override.yml erstellt"

echo "═══════════════════════════════════════"
echo "🚀 Docker Container starten"
echo "═══════════════════════════════════════"

docker compose -f "${COMPOSE_FILE}" pull
docker compose -f "${COMPOSE_FILE}" up -d

echo "⏳ Warte auf Datenbankstart (30 Sekunden)..."
sleep 30

echo "═══════════════════════════════════════"
echo "🗄️  Datenbank initialisieren"
echo "═══════════════════════════════════════"

# Migrationen mit Retry
retry_command \
    "docker compose -f '${COMPOSE_FILE}' exec -T db psql -U obico -d obico -c 'SELECT 1;'" \
    "Warte auf Datenbank..."

retry_command \
    "docker compose -f '${COMPOSE_FILE}' run --rm web python manage.py migrate --noinput" \
    "Führe Datenbankmigrationen aus..."

# Statische Dateien sammeln
echo "📦 Sammle statische Dateien..."
docker compose -f "${COMPOSE_FILE}" run --rm web python manage.py collectstatic --noinput || true

echo "═══════════════════════════════════════"
echo "🌐 Django Site konfigurieren"
echo "═══════════════════════════════════════"

# KRITISCH: Django Site korrekt setzen
docker compose -f "${COMPOSE_FILE}" run --rm web python manage.py shell <<PYTHON_SCRIPT
from django.contrib.sites.models import Site
try:
    site = Site.objects.get(id=1)
    site.domain = '${SITE_DOMAIN}'
    site.name = 'Obico Server'
    site.save()
    print(f'✓ Site aktualisiert: {site.domain}')
except Site.DoesNotExist:
    site = Site.objects.create(id=1, domain='${SITE_DOMAIN}', name='Obico Server')
    print(f'✓ Site erstellt: {site.domain}')
PYTHON_SCRIPT

echo "═══════════════════════════════════════"
echo "🔄 Services neu starten"
echo "═══════════════════════════════════════"

docker compose -f "${COMPOSE_FILE}" restart

echo "⏳ Warte auf Service-Start (15 Sekunden)..."
sleep 15

# Status prüfen
echo ""
echo "📊 Container Status:"
docker compose -f "${COMPOSE_FILE}" ps

echo ""
echo "✅ Installation abgeschlossen!"

CONTAINER_SCRIPT
)

# Variablen ersetzen und ausführen
CONTAINER_SCRIPT_CONTENT="${CONTAINER_SCRIPT_CONTENT//__DB_PASS__/$DB_PASS}"
CONTAINER_SCRIPT_CONTENT="${CONTAINER_SCRIPT_CONTENT//__REDIS_PASS__/$REDIS_PASS}"
CONTAINER_SCRIPT_CONTENT="${CONTAINER_SCRIPT_CONTENT//__ADMIN_EMAIL__/$ADMIN_EMAIL}"
CONTAINER_SCRIPT_CONTENT="${CONTAINER_SCRIPT_CONTENT//__GIT_URL__/$GIT_URL}"
CONTAINER_SCRIPT_CONTENT="${CONTAINER_SCRIPT_CONTENT//__SITE_DOMAIN__/$SITE_DOMAIN}"
CONTAINER_SCRIPT_CONTENT="${CONTAINER_SCRIPT_CONTENT//__CONTAINER_IP__/$IP_ADDRESS}"

pct exec $CTID -- bash -c "$CONTAINER_SCRIPT_CONTENT"

# --- Finale Ausgabe ---
clear
cat << "EOF"
╔═══════════════════════════════════════╗
║     ✅ INSTALLATION ERFOLGREICH       ║
╚═══════════════════════════════════════╝
EOF

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}Container Details${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo "📦 Container ID    : $CTID"
echo "🏷️  Hostname        : $HOSTNAME"
echo "🔑 Root Passwort   : $ROOTPASS"
echo "🌐 IP-Adresse      : $IP_ADDRESS"
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}Zugriff auf Obico${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "🌍 URL: ${YELLOW}http://${SITE_DOMAIN}:3334${NC}"
echo ""
echo -e "${YELLOW}⚠️  WICHTIGE SCHRITTE:${NC}"
echo "1. Öffne die URL im Browser"
echo "2. Registriere dich als erster Benutzer (wird automatisch Admin)"
echo "3. Bestätige deine E-Mail (falls konfiguriert)"
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}Nützliche Befehle${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo "Container betreten:"
echo "  pct enter $CTID"
echo ""
echo "Logs anzeigen:"
echo "  pct exec $CTID -- docker compose -f /opt/obico/docker-compose.yml logs -f"
echo ""
echo "Services neu starten:"
echo "  pct exec $CTID -- docker compose -f /opt/obico/docker-compose.yml restart"
echo ""
echo "Admin-User manuell erstellen (falls nötig):"
echo "  pct exec $CTID -- docker compose -f /opt/obico/docker-compose.yml run --rm web python manage.py createsuperuser"
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
