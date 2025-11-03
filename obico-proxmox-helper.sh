#!/usr/bin/env bash
# ===============================================================
# Obico Server - Proxmox Helper Script (Fixed Version V11)
# Fixes: Variable substitution, Error 500, Django Site Config
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

# --- Farbcodes ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

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

# --- Installation-Script in temporäre Datei schreiben ---
INSTALL_SCRIPT="/tmp/obico_install_$CTID.sh"

cat > "$INSTALL_SCRIPT" <<'EOFSCRIPT'
#!/bin/bash
set -e

# Variablen werden vom Host gesetzt
DB_PASS="$1"
REDIS_PASS="$2"
ADMIN_EMAIL="$3"
GIT_URL="$4"
SITE_DOMAIN="$5"
CONTAINER_IP="$6"

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

echo "═══════════════════════════════════════"
echo "🔧 Systemvorbereitung"
echo "═══════════════════════════════════════"

# Locale fix
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C.UTF-8
export LANG=C.UTF-8

# Grundsystem aktualisieren
apt-get update
apt-get upgrade -y

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

# Docker Status prüfen
echo "🔍 Prüfe Docker Status..."
docker --version
docker compose version

echo "═══════════════════════════════════════"
echo "📥 Obico Server klonen"
echo "═══════════════════════════════════════"

cd /opt
if [ -d "obico" ]; then
    echo "⚠ Altes obico Verzeichnis gefunden, entferne es..."
    rm -rf obico
fi

echo "📦 Clone Repository: $GIT_URL"
git clone "$GIT_URL" obico
cd /opt/obico

echo "✓ Repository erfolgreich geklont"
ls -la

echo "═══════════════════════════════════════"
echo "⚙️  Konfiguration erstellen"
echo "═══════════════════════════════════════"

# Prüfe ob PostgreSQL in LXC funktioniert
echo "🔍 Teste PostgreSQL Kompatibilität..."
TEST_COMPOSE=$(cat <<'TESTCOMPOSE'
services:
  test-db:
    image: postgres:14
    environment:
      POSTGRES_PASSWORD: test123
    command: postgres -c shared_buffers=128MB
TESTCOMPOSE
)

echo "$TEST_COMPOSE" > docker-compose.test.yml
if timeout 30 docker compose -f docker-compose.test.yml up -d && sleep 10 && docker compose -f docker-compose.test.yml ps | grep -q "running"; then
    echo "✓ PostgreSQL funktioniert in diesem Container"
    USE_POSTGRES=true
    docker compose -f docker-compose.test.yml down -v
else
    echo "⚠ PostgreSQL hat Probleme, verwende SQLite"
    USE_POSTGRES=false
    docker compose -f docker-compose.test.yml down -v 2>/dev/null || true
fi
rm -f docker-compose.test.yml

# .env Datei erstellen (mit bedingter DB-Konfiguration)
if [ "$USE_POSTGRES" = true ]; then
    cat > .env <<ENVFILE
# Datenbank (PostgreSQL)
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

# Email (Optional)
EMAIL_HOST=localhost
EMAIL_PORT=25
DEFAULT_FROM_EMAIL=${ADMIN_EMAIL}

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
else
    # SQLite Konfiguration
    cat > .env <<ENVFILE
# Datenbank (SQLite - für LXC Kompatibilität)
DATABASE_URL=sqlite:///data/db.sqlite3

# Redis
REDIS_PASSWORD=${REDIS_PASS}

# Django Settings
DEBUG=False
ALLOWED_HOSTS=${SITE_DOMAIN},${CONTAINER_IP},localhost,127.0.0.1
SITE_USES_HTTPS=False
SITE_IS_PUBLIC=True

# Email (Optional)
EMAIL_HOST=localhost
EMAIL_PORT=25
DEFAULT_FROM_EMAIL=${ADMIN_EMAIL}

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

    # Override für SQLite
    cat > docker-compose.override.yml <<'OVERRIDE'
services:
  web:
    environment:
      - CSRF_TRUSTED_ORIGINS=http://${SITE_DOMAIN},http://${CONTAINER_IP}:3334
      - DATABASE_URL=sqlite:////app/data/db.sqlite3
    ports:
      - "3334:3334"
    restart: unless-stopped
    volumes:
      - sqlite_data:/app/data
  
  ml_api:
    restart: unless-stopped
  
  redis:
    restart: unless-stopped

volumes:
  sqlite_data:
OVERRIDE
fi

echo "✓ .env Datei erstellt:"
cat .env

# Docker Compose Datei finden
COMPOSE_FILE=""
if [ -f "docker-compose.yml" ]; then
    COMPOSE_FILE="docker-compose.yml"
elif [ -f "compose/docker-compose.yml" ]; then
    COMPOSE_FILE="compose/docker-compose.yml"
elif [ -f "docker-compose.yaml" ]; then
    COMPOSE_FILE="docker-compose.yaml"
else
    echo "❌ Keine docker-compose.yml gefunden!"
    echo "Verfügbare Dateien:"
    ls -la
    exit 1
fi

echo "✓ Verwende Compose Datei: $COMPOSE_FILE"

# Docker Compose Override für externe Zugriffe
if [ "$USE_POSTGRES" = true ]; then
    cat > docker-compose.override.yml <<'OVERRIDE'
services:
  web:
    environment:
      - CSRF_TRUSTED_ORIGINS=http://${SITE_DOMAIN},http://${CONTAINER_IP}:3334
    ports:
      - "3334:3334"
    restart: unless-stopped
  
  ml_api:
    restart: unless-stopped
  
  db:
    restart: unless-stopped
    volumes:
      - db_data:/var/lib/postgresql/data
    command: postgres -c shared_buffers=128MB -c max_connections=100
  
  redis:
    restart: unless-stopped

volumes:
  db_data:
OVERRIDE
else
    echo "ℹ SQLite Override bereits erstellt"
fi

echo "✓ docker-compose.override.yml erstellt"

echo "═══════════════════════════════════════"
echo "🚀 Docker Container starten"
echo "═══════════════════════════════════════"

# Images pullen
echo "📦 Lade Docker Images..."
docker compose -f "${COMPOSE_FILE}" pull

# Container starten
echo "🚀 Starte Container..."
docker compose -f "${COMPOSE_FILE}" up -d

echo "⏳ Warte auf Datenbankstart (30 Sekunden)..."
sleep 30

echo "═══════════════════════════════════════"
echo "🗄️  Datenbank initialisieren"
echo "═══════════════════════════════════════"

if [ "$USE_POSTGRES" = true ]; then
    # Prüfe Container Status
    echo "🔍 Prüfe welche Container laufen..."
    docker compose -f "${COMPOSE_FILE}" ps
    
    # Prüfe DB Container Logs
    echo "📋 Datenbank Logs (letzte 20 Zeilen):"
    docker compose -f "${COMPOSE_FILE}" logs db --tail=20
    
    # Stelle sicher dass DB läuft
    echo "🔄 Stelle sicher dass DB läuft..."
    docker compose -f "${COMPOSE_FILE}" up -d db
    sleep 15
    
    # Warte auf Datenbank mit besserem Check
    retry_command \
        "docker compose -f '${COMPOSE_FILE}' exec -T db pg_isready -U obico" \
        "Warte auf PostgreSQL..."
else
    echo "ℹ Verwende SQLite, keine separate DB nötig"
fi

# Migrationen ausführen
retry_command \
    "docker compose -f '${COMPOSE_FILE}' run --rm web python manage.py migrate --noinput" \
    "Führe Datenbankmigrationen aus..."

# Statische Dateien sammeln
echo "📦 Sammle statische Dateien..."
docker compose -f "${COMPOSE_FILE}" run --rm web python manage.py collectstatic --noinput || true

echo "═══════════════════════════════════════"
echo "🌐 Django Site konfigurieren"
echo "═══════════════════════════════════════"

# Django Site via Python Shell setzen
docker compose -f "${COMPOSE_FILE}" run --rm web python manage.py shell <<PYTHONSCRIPT
from django.contrib.sites.models import Site
import os

site_domain = os.environ.get('SITE_DOMAIN', '${SITE_DOMAIN}')

try:
    site = Site.objects.get(id=1)
    site.domain = site_domain
    site.name = 'Obico Server'
    site.save()
    print(f'✓ Site aktualisiert: {site.domain}')
except Site.DoesNotExist:
    site = Site.objects.create(id=1, domain=site_domain, name='Obico Server')
    print(f'✓ Site erstellt: {site.domain}')

# Verify
all_sites = Site.objects.all()
print(f'Alle Sites: {list(all_sites.values_list("domain", flat=True))}')
PYTHONSCRIPT

echo "═══════════════════════════════════════"
echo "🔄 Services neu starten"
echo "═══════════════════════════════════════"

docker compose -f "${COMPOSE_FILE}" restart

echo "⏳ Warte auf Service-Start (20 Sekunden)..."
sleep 20

# Status prüfen
echo ""
echo "📊 Container Status:"
docker compose -f "${COMPOSE_FILE}" ps

echo ""
echo "📋 Web Service Logs (letzte 20 Zeilen):"
docker compose -f "${COMPOSE_FILE}" logs --tail=20 web

echo ""
echo "✅ Installation im Container abgeschlossen!"

EOFSCRIPT

# --- Script in Container kopieren und ausführen ---
echo "📤 Kopiere Installations-Script in Container..."
pct push $CTID "$INSTALL_SCRIPT" /tmp/install.sh

echo "🔧 Mache Script ausführbar..."
pct exec $CTID -- chmod +x /tmp/install.sh

echo "🚀 Starte Installation im Container..."
pct exec $CTID -- /tmp/install.sh "$DB_PASS" "$REDIS_PASS" "$ADMIN_EMAIL" "$GIT_URL" "$SITE_DOMAIN" "$IP_ADDRESS"

# Cleanup
rm -f "$INSTALL_SCRIPT"

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
echo "🔧 DB Password     : $DB_PASS"
echo "🔧 Redis Password  : $REDIS_PASS"
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
echo "  pct exec $CTID -- docker compose -f /opt/obico/docker-compose.yml logs -f web"
echo ""
echo "Alle Services neu starten:"
echo "  pct exec $CTID -- docker compose -f /opt/obico/docker-compose.yml restart"
echo ""
echo "Services Status:"
echo "  pct exec $CTID -- docker compose -f /opt/obico/docker-compose.yml ps"
echo ""
echo "Admin-User manuell erstellen (falls nötig):"
echo "  pct exec $CTID -- docker compose -f /opt/obico/docker-compose.yml run --rm web python manage.py createsuperuser"
echo ""
echo -e "${YELLOW}Bei Problemen:${NC}"
echo "  pct exec $CTID -- docker compose -f /opt/obico/docker-compose.yml logs web"
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "💾 Konfiguration gespeichert in: /opt/obico/"
echo ""
