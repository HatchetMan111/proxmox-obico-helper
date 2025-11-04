#!/usr/bin/env bash
# ===============================================================
# Obico Server - Proxmox Helper Script (Simplified Version)
# Installiert bis zum ersten Login auf localhost:3334
# Django Site kann danach manuell angepasst werden
# ===============================================================

set -e
APP="Obico Server"
BRIDGE="vmbr0"
GIT_URL="https://github.com/TheSpaghettiDetective/obico-server.git"

# --- Konfiguration ---
REDIS_PASS="obico123"

# --- Farbcodes ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
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
echo "Installiert Obico Server bis zum ersten Login"
echo "Django Site kann danach manuell konfiguriert werden"
echo ""

# --- User Input ---
read -p "Container ID (Standard: 200): " CTID
CTID=${CTID:-200}

read -p "Hostname (Standard: obico): " HOSTNAME
HOSTNAME=${HOSTNAME:-obico}

read -p "CPU Cores (Standard: 2): " CORE
CORE=${CORE:-2}

read -p "RAM in MB (Standard: 4096): " MEMORY
MEMORY=${MEMORY:-4096}

read -p "Disk Size in GB (Standard: 30): " DISK
DISK=${DISK:-30}

read -sp "Root Passwort: " ROOTPASS
echo ""
ROOTPASS=${ROOTPASS:-"proxmox"}

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

# --- Installation-Script erstellen ---
INSTALL_SCRIPT="/tmp/obico_install_$CTID.sh"

cat > "$INSTALL_SCRIPT" <<'EOFSCRIPT'
#!/bin/bash
set -e

REDIS_PASS="$1"
GIT_URL="$2"
CONTAINER_IP="$3"

echo "═══════════════════════════════════════"
echo "🔧 Systemvorbereitung"
echo "═══════════════════════════════════════"

export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C.UTF-8
export LANG=C.UTF-8

apt-get update
apt-get upgrade -y

echo "📦 Installiere Docker..."
apt-get install -y curl git ca-certificates gnupg lsb-release

mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

systemctl enable docker
systemctl start docker

docker --version
docker compose version

echo "═══════════════════════════════════════"
echo "📥 Obico Server klonen"
echo "═══════════════════════════════════════"

cd /opt
[ -d "obico" ] && rm -rf obico

git clone "$GIT_URL" obico
cd /opt/obico

echo "✓ Repository geklont"

echo "═══════════════════════════════════════"
echo "⚙️  Minimale Konfiguration"
echo "═══════════════════════════════════════"

# Minimale .env für ersten Start
cat > .env <<ENVFILE
# Redis
REDIS_PASSWORD=${REDIS_PASS}

# Django Basis-Einstellungen (localhost nur)
DEBUG=True
ALLOWED_HOSTS=localhost,127.0.0.1,${CONTAINER_IP}
SECRET_KEY=$(openssl rand -base64 32)

# Web Server
WEB_HOST=0.0.0.0
WEB_PORT=3334

# Obico Einstellungen
ACCOUNT_ALLOW_SIGN_UP=True
SOCIAL_LOGIN=False

# Internes Netzwerk
INTERNAL_MEDIA_HOST=http://web:3334
OCTOPRINT_TUNNEL_PORT_RANGE=0-0
ENVFILE

echo "✓ .env erstellt (localhost-only)"

# Override für Port-Mapping
cat > docker-compose.override.yml <<'OVERRIDE'
services:
  web:
    ports:
      - "3334:3334"
    restart: unless-stopped
    environment:
      - DEBUG=True
  
  ml_api:
    restart: unless-stopped
  
  tasks:
    restart: unless-stopped
  
  redis:
    restart: unless-stopped
OVERRIDE

echo "✓ docker-compose.override.yml erstellt"

# Finde docker-compose Datei
COMPOSE_FILE=""
for f in docker-compose.yml compose/docker-compose.yml docker-compose.yaml; do
    if [ -f "$f" ]; then
        COMPOSE_FILE="$f"
        break
    fi
done

if [ -z "$COMPOSE_FILE" ]; then
    echo "❌ Keine docker-compose Datei gefunden!"
    exit 1
fi

echo "✓ Verwende: $COMPOSE_FILE"

echo "═══════════════════════════════════════"
echo "🚀 Docker Container starten"
echo "═══════════════════════════════════════"

docker compose -f "${COMPOSE_FILE}" pull
docker compose -f "${COMPOSE_FILE}" up -d

echo "⏳ Warte auf Services (30 Sekunden)..."
sleep 30

echo "═══════════════════════════════════════"
echo "🗄️  Datenbank initialisieren"
echo "═══════════════════════════════════════"

# Warte bis Web-Container bereit ist
for i in {1..20}; do
    if docker compose -f "${COMPOSE_FILE}" ps web | grep -q "Up"; then
        echo "✓ Web-Container läuft"
        break
    fi
    echo "   Warte auf Web-Container... ($i/20)"
    sleep 3
done

# Migrationen durchführen
echo "📦 Führe Datenbankmigrationen aus..."
docker compose -f "${COMPOSE_FILE}" exec -T web python manage.py migrate --noinput || \
docker compose -f "${COMPOSE_FILE}" run --rm web python manage.py migrate --noinput

# Statische Dateien
echo "📦 Sammle statische Dateien..."
docker compose -f "${COMPOSE_FILE}" exec -T web python manage.py collectstatic --noinput || \
docker compose -f "${COMPOSE_FILE}" run --rm web python manage.py collectstatic --noinput

echo "═══════════════════════════════════════"
echo "✅ Basis-Installation abgeschlossen"
echo "═══════════════════════════════════════"

echo ""
echo "📊 Service Status:"
docker compose -f "${COMPOSE_FILE}" ps

echo ""
echo "🌐 Server ist bereit auf: http://localhost:3334"
echo "🌐 Oder von außen: http://${CONTAINER_IP}:3334"

EOFSCRIPT

# --- Script in Container kopieren und ausführen ---
echo "📤 Kopiere Installations-Script in Container..."
pct push $CTID "$INSTALL_SCRIPT" /tmp/install.sh
pct exec $CTID -- chmod +x /tmp/install.sh

echo "🚀 Starte Installation..."
pct exec $CTID -- /tmp/install.sh "$REDIS_PASS" "$GIT_URL" "$IP_ADDRESS"

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
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}Erste Anmeldung${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "🌍 Lokaler Zugriff: ${YELLOW}http://localhost:3334${NC} (im Container)"
echo -e "🌍 Externer Zugriff: ${YELLOW}http://${IP_ADDRESS}:3334${NC}"
echo ""
echo -e "${CYAN}📝 NÄCHSTE SCHRITTE:${NC}"
echo ""
echo "1️⃣  Öffne http://${IP_ADDRESS}:3334 im Browser"
echo "2️⃣  Registriere dich als erster Benutzer (wird automatisch Admin)"
echo "3️⃣  Nach erfolgreicher Registrierung, konfiguriere Django Site:"
echo ""
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}Django Site für externe IP konfigurieren:${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "pct exec $CTID -- bash -c 'cd /opt/obico && docker compose exec web python manage.py shell' << EOF"
echo "from django.contrib.sites.models import Site"
echo "site = Site.objects.get(id=1)"
echo "site.domain = \"${IP_ADDRESS}:3334\"  # Oder deine gewünschte Domain"
echo "site.name = \"Obico Server\""
echo "site.save()"
echo "print(f\"Site aktualisiert: {site.domain}\")"
echo "EOF"
echo ""
echo -e "${YELLOW}Dann .env anpassen:${NC}"
echo ""
echo "pct exec $CTID -- bash -c 'cd /opt/obico && cat >> .env << EOF"
echo ""
echo "# Nach der Registrierung für Produktion:"
echo "DEBUG=False"
echo "ALLOWED_HOSTS=${IP_ADDRESS},localhost,127.0.0.1"
echo "CSRF_TRUSTED_ORIGINS=http://${IP_ADDRESS}:3334"
echo "EOF'"
echo ""
echo -e "${YELLOW}Services neu starten:${NC}"
echo "pct exec $CTID -- docker compose -f /opt/obico/docker-compose.yml restart"
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}Nützliche Befehle${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "Container betreten:"
echo "  pct enter $CTID"
echo ""
echo "Logs anzeigen:"
echo "  pct exec $CTID -- docker compose -f /opt/obico/docker-compose.yml logs -f web"
echo ""
echo "Status prüfen:"
echo "  pct exec $CTID -- docker compose -f /opt/obico/docker-compose.yml ps"
echo ""
echo "Services neu starten:"
echo "  pct exec $CTID -- docker compose -f /opt/obico/docker-compose.yml restart"
echo ""
echo "Admin manuell erstellen (falls nötig):"
echo "  pct exec $CTID -- docker compose -f /opt/obico/docker-compose.yml exec web python manage.py createsuperuser"
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "💾 Installation: /opt/obico/"
echo "📄 Konfiguration: /opt/obico/.env"
echo ""
