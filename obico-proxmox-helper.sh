#!/usr/bin/env bash
# ===============================================================
# Obico Server - Proxmox One-Click Installer (Verbesserte Version)
# Fokus auf Stabilität der Docker- und Django-Schritte
# ===============================================================

set -e
APP="Obico Server"
OSTYPE="ubuntu"
OSVERSION="22.04"
BRIDGE="vmbr0" # Standard Proxmox Bridge
GIT_URL="https://github.com/TheSpaghettiDetective/obico-server.git"

# --- Konfiguration ---
DB_PASS="obicodbpass"
REDIS_PASS="obico123"
ADMIN_EMAIL="admin@obico.local"
ADMIN_PASS="obicoAdmin123"

clear
echo -e "\e[1;36m──────────────────────────────────────────────"
echo "    🧠 ${APP} - Proxmox LXC Installer (Verbessert)"
echo "──────────────────────────────────────────────\e[0m"

# --- Check PVE ---
if ! command -v pveversion >/dev/null 2>&1; then
  echo "❌ Dieses Script muss auf einem Proxmox Host ausgeführt werden!"
  exit 1
fi

# --- User Input ---
read -p "🆔 Container ID (leer = auto): " CTID
CTID=${CTID:-$(pvesh get /cluster/nextid)}

read -p "💾 Disk Size in GB [15]: " DISK
DISK=${DISK:-15}
read -p "🧠 Memory in MB [2048]: " MEMORY
MEMORY=${MEMORY:-2048}
read -p "⚙️  CPU Cores [2]: " CORE
CORE=${CORE:-2}
read -p "🔐 Root Passwort für Container [obicoAdmin]: " ROOTPASS
ROOTPASS=${ROOTPASS:-obicoAdmin}

# --- Template Logik ---
TEMPLATE_STORE=$(pvesm status | awk '/dir/ && /active/ {print $1; exit}')
LATEST_TEMPLATE=$(pveam available | grep ubuntu-22.04 | grep standard | tail -n 1 | awk '{print $2}')
TEMPLATE="${TEMPLATE_STORE}:vztmpl/${LATEST_TEMPLATE}"

if ! pveam list $TEMPLATE_STORE | grep -q "$(basename $LATEST_TEMPLATE)"; then
  echo "📦 Lade Ubuntu Template herunter..."
  pveam download $TEMPLATE_STORE $LATEST_TEMPLATE
fi

# --- LXC Erstellen ---
echo "⚙️ Erstelle Container $CTID..."
pct create $CTID $TEMPLATE \
  -hostname obico \
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
echo "⏳ Warte, bis Container gestartet ist..."
sleep 15 # Längere Wartezeit für stabilen Start

IP_ADDRESS=$(pct exec $CTID -- hostname -I | awk '{print $1}')
SITE_DOMAIN="${IP_ADDRESS}:3334"

# --- Installation im Container ---
echo "💻 Starte Installation im Container $CTID (IP: $IP_ADDRESS)..."

pct exec $CTID -- bash -e <<EOF
apt update && apt install -y git curl docker.io docker-compose-v2 python3-pip
systemctl enable --now docker

cd /opt
git clone ${GIT_URL} obico
cd obico

# .env erstellen und konfigurieren
echo "⚙️ Konfiguriere .env..."
if [ -f "dotenv.example" ]; then
  cp dotenv.example .env
else
  # Fallback, falls dotenv.example nicht existiert
  echo "POSTGRES_PASSWORD=${DB_PASS}" > .env
  echo "REDIS_PASSWORD=${REDIS_PASS}" >> .env
  echo "WEB_HOST=0.0.0.0" >> .env
  echo "DJANGO_SETTINGS_MODULE=backend.settings.production" >> .env # Sicherstellen, dass Prod-Settings genutzt werden
fi

sed -i "s#POSTGRES_PASSWORD=.*#POSTGRES_PASSWORD=${DB_PASS}#" .env || true
sed -i "s#REDIS_PASSWORD=.*#REDIS_PASSWORD=${REDIS_PASS}#" .env || true
sed -i "s#WEB_HOST=.*#WEB_HOST=0.0.0.0#" .env || true

# Port 3334 sicherstellen
if ! grep -q "3334:3334" docker-compose.yml; then
  echo "🔌 Füge Port 3334 zum docker-compose.yml hinzu..."
  sed -i '/ports:/a\      - "3334:3334"' docker-compose.yml
fi

# Docker Build + Start
echo "🐳 Starte Docker Container..."
docker compose down || true
docker compose up -d --build

# Warte auf DB und Web-Service
echo "⏳ Warte 30 Sekunden auf Datenbank und Web-Service-Initialisierung..."
sleep 30

# Migrationen
echo "🔄 Führe Django Migrationen durch..."
# Verwenden Sie exec -T, um TTY-Probleme zu vermeiden
if ! docker compose exec -T web python manage.py migrate --noinput; then
    echo "❌ Migrationen fehlgeschlagen. Versuche es erneut..."
    sleep 10
    docker compose exec -T web python manage.py migrate --noinput || { echo "❌ FATAL: Migrationen nach Wiederholung fehlgeschlagen."; exit 1; }
fi

# Admin anlegen
echo "👤 Erstelle Admin-Benutzer..."
docker compose exec -T web python manage.py shell <<PY
from django.contrib.auth import get_user_model
User = get_user_model()
try:
    if not User.objects.filter(email="${ADMIN_EMAIL}").exists():
        User.objects.create_superuser(email="${ADMIN_EMAIL}", password="${ADMIN_PASS}", is_active=True, is_staff=True, is_superuser=True)
        print("Admin-User erstellt.")
    else:
        print("Admin-User existiert bereits.")
except Exception as e:
    print(f"Fehler beim Erstellen des Admin-Users: {e}")
PY

# Site konfigurieren
echo "🌐 Konfiguriere Django Site..."
docker compose exec -T web python manage.py shell <<PY
from django.contrib.sites.models import Site
try:
    Site.objects.update_or_create(id=1, defaults={'domain': '${SITE_DOMAIN}', 'name': 'Obico Local'})
    print(f"Site-Domain auf {SITE_DOMAIN} gesetzt.")
except Exception as e:
    print(f"Fehler beim Konfigurieren der Site: {e}")
PY

# Web-Service neu starten, um alle Änderungen zu übernehmen
echo "♻️ Starte Web-Service neu..."
docker compose restart web

# Warte kurz, bis der Webserver wieder läuft (sollte den 500er beheben)
sleep 10

EOF

# --- Erfolgsmeldung ---
clear
echo -e "\e[1;32m✅ ${APP} erfolgreich installiert!\e[0m"
echo "──────────────────────────────────────────────"
echo "📦 Container ID : $CTID"
echo "🌐 Zugriff unter: http://${IP_ADDRESS}:3334"
echo "🔑 Login:"
echo "    E-Mail: ${ADMIN_EMAIL}"
echo "    Passwort: ${ADMIN_PASS}"
echo "──────────────────────────────────────────────"
