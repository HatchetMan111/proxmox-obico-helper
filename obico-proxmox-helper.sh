#!/usr/bin/env bash
# ===============================================================
# Obico Server - Proxmox Helper Script (Local Installation)
# Author: GPT-5
# Tested on Proxmox VE 8.x with Ubuntu 22.04 template
# ===============================================================

set -e
APP="Obico Server"
OSTYPE="ubuntu"
OSVERSION="22.04"
BRIDGE="vmbr0"
GIT_URL="https://github.com/TheSpaghettiDetective/obico-server.git"

# --- Banner ---
clear
echo -e "\e[1;36m──────────────────────────────────────────────"
echo "   🧠 ${APP} - Proxmox Interactive Installer"
echo "──────────────────────────────────────────────\e[0m"

# --- Check PVE ---
if ! command -v pveversion >/dev/null 2>&1; then
  echo "❌  Dieses Script muss auf einem Proxmox Host ausgeführt werden!"
  exit 1
fi

# --- User Input ---
read -p "🆔 Container ID (leer = auto): " CTID
CTID=${CTID:-$(pvesh get /cluster/nextid)}

read -p "🖥️  Hostname [obico]: " HOSTNAME
HOSTNAME=${HOSTNAME:-obico}

read -p "💾 Disk Size in GB [15]: " DISK
DISK=${DISK:-15}

read -p "🧠 Memory in MB [2048]: " MEMORY
MEMORY=${MEMORY:-2048}

read -p "⚙️  CPU Cores [2]: " CORE
CORE=${CORE:-2}

read -p "🔐 Root Passwort für Container [obicoAdmin]: " ROOTPASS
ROOTPASS=${ROOTPASS:-obicoAdmin}

echo -e "\n🚀 Starte Installation von ${APP} im Container #${CTID}...\n"

# --- Find valid template storage automatically ---
# --- Dynamisches Ubuntu-Template finden ---
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
sleep 10

# --- Installation im Container ---
echo "🐳  Installiere Docker & ${APP}..."
pct exec $CTID -- bash -c "
#!/bin/bash
set -e
apt update && apt upgrade -y
apt install -y git curl docker.io docker-compose-v2
systemctl enable --now docker
cd /opt
git clone https://github.com/TheSpaghettiDetective/obico-server.git obico
cd obico
if [ -f ".env.sample" ]; then
  cp .env.sample .env
elif [ -f ".env.template" ]; then
  cp .env.template .env
elif [ -f "compose.env.sample" ]; then
  cp compose.env.sample .env
else
  echo "POSTGRES_PASSWORD=obicodbpass" > .env
  echo "REDIS_PASSWORD=obico123" >> .env
  echo "WEB_HOST=localhost" >> .env
fi
# Finde Compose-Datei automatisch
if [ -f "docker-compose.yml" ]; then
  docker compose -f docker-compose.yml up -d
elif [ -f "compose/docker-compose.yml" ]; then
  docker compose -f compose/docker-compose.yml up -d
elif [ -f "compose.yaml" ]; then
  docker compose -f compose.yaml up -d
else
  echo "❌ Keine Docker Compose Datei gefunden! Bitte überprüfe das Repo."
  exit 1
fi
sed -i 's/POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=obicodbpass/' .env
sed -i 's/REDIS_PASSWORD=.*/REDIS_PASSWORD=obico123/' .env
sed -i 's/WEB_HOST=.*/WEB_HOST=localhost/' .env
docker compose up -d
"
# --- Ausgabe ---
clear
echo -e "\e[1;32m✅ ${APP} erfolgreich installiert!\e[0m"
echo "──────────────────────────────────────────────"
echo "📦 Container-ID : $CTID"
echo "🌐 Zugriff       : http://${IP}:3334"
echo "🧱 Admin-Setup   : /opt/obico im Container"
echo "🔑 Root Passwort : $ROOTPASS"
echo "──────────────────────────────────────────────"
echo "🌐 Obico läuft unter: http://$(pct exec $CTID -- hostname -I | awk '{print $1}'):3334"
echo "💡 Öffne den Link im Browser und führe das Setup durch."
echo "──────────────────────────────────────────────"
