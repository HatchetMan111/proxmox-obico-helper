#!/usr/bin/env bash
# ===============================================================
# Obico Server - Proxmox One-Click Installer (Final Gemini Fix)
# Funktioniert mit aktuellem Repo (manage.py in backend/, dotenv.example)
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
ADMIN_PASS="obicoAdmin123"

clear
echo -e "\e[1;36m──────────────────────────────────────────────"
echo "   🧠 ${APP} - Proxmox LXC Installer"
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

TEMPLATE_STORE=$(pvesm status | awk '/dir/ && /active/ {print $1; exit}')
LATEST_TEMPLATE=$(pveam available | grep ubuntu-22.04 | grep standard | tail -n 1 | awk '{print $2}')
TEMPLATE="${TEMPLATE_STORE}:vztmpl/${LATEST_TEMPLATE}"

if ! pveam list $TEMPLATE_STORE | grep -q "$(basename $LATEST_TEMPLATE)"; then
  echo "📦 Lade Ubuntu Template herunter..."
  pveam download $TEMPLATE_STORE $LATEST_TEMPLATE
fi

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
sleep 10

IP_ADDRESS=$(pct exec $CTID -- hostname -I | awk '{print $1}')
SITE_DOMAIN="${IP_ADDRESS}:3334"

# --- Installation im Container ---
pct exec $CTID -- bash -e <<EOF
apt update && apt install -y git curl docker.io docker-compose-v2
systemctl enable --now docker

cd /opt
git clone ${GIT_URL} obico
cd obico

# .env erstellen
if [ -f "dotenv.example" ]; then
  cp dotenv.example .env
else
  echo "POSTGRES_PASSWORD=${DB_PASS}" > .env
  echo "REDIS_PASSWORD=${REDIS_PASS}" >> .env
  echo "WEB_HOST=0.0.0.0" >> .env
fi

sed -i "s#POSTGRES_PASSWORD=.*#POSTGRES_PASSWORD=${DB_PASS}#" .env || true
sed -i "s#REDIS_PASSWORD=.*#REDIS_PASSWORD=${REDIS_PASS}#" .env || true
sed -i "s#WEB_HOST=.*#WEB_HOST=0.0.0.0#" .env || true

# Port 3334 sicherstellen
grep -q "3334:3334" docker-compose.yml || \
sed -i '/ports:/a\      - "3334:3334"' docker-compose.yml

# Docker Build + Start
docker compose down || true
docker compose up -d --build

# Warte auf DB
echo "⏳ Warte auf Datenbank..."
sleep 20

cd backend

# Migrationen
docker compose exec -T web python manage.py migrate --noinput || \
docker compose run --rm -T web python manage.py migrate --noinput

# Admin anlegen
docker compose exec -T web python manage.py shell <<PY
from django.contrib.auth import get_user_model
User = get_user_model()
if not User.objects.filter(email="${ADMIN_EMAIL}").exists():
    User.objects.create_superuser("${ADMIN_EMAIL}", "${ADMIN_PASS}")
PY

# Site konfigurieren
docker compose exec -T web python manage.py shell <<PY
from django.contrib.sites.models import Site
Site.objects.update_or_create(id=1, defaults={'domain': '${SITE_DOMAIN}', 'name': 'Obico Local'})
PY

docker compose restart web
EOF

clear
echo -e "\e[1;32m✅ ${APP} erfolgreich installiert!\e[0m"
echo "──────────────────────────────────────────────"
echo "📦 Container ID : $CTID"
echo "🌐 Zugriff unter: http://${IP_ADDRESS}:3334"
echo "🔑 Login:"
echo "   E-Mail: ${ADMIN_EMAIL}"
echo "   Passwort: ${ADMIN_PASS}"
echo "──────────────────────────────────────────────"
