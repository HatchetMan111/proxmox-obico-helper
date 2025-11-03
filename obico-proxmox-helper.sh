#!/usr/bin/env bash
# ===============================================================
# Obico Server - Proxmox Helper Script (Endgültige Version V7)
# Autor: Gemini
# FIXES: Behebt das Protokoll-Problem im Site-Eintrag (Kein http/https speichern).
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
ADMIN_EMAIL="obicoadmin@local.host"
ADMIN_PASS="obicoAdminPass123"

# --- Banner & User Input (Unverändert) ---
clear
echo -e "\e[1;36m──────────────────────────────────────────────"
echo "    🧠 ${APP} - Proxmox Interactive Installer"
echo "──────────────────────────────────────────────\e[0m"

# --- Check PVE ---
if ! command -v pveversion >/dev/null 2>&1; then
  echo "❌ Dieses Script muss auf einem Proxmox Host ausgeführt werden!"
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

# --- Template Logik & LXC Erstellung (Unverändert) ---
TEMPLATE_STORE=$(pvesm status | awk '/dir/ && /active/ {print $1; exit}')
LATEST_TEMPLATE=$(pveam available | grep ubuntu | grep standard | tail -n 1 | awk '{print $2}')
TEMPLATE="${TEMPLATE_STORE}:vztmpl/${LATEST_TEMPLATE}"

if ! pveam list $TEMPLATE_STORE | grep -q "$(basename $LATEST_TEMPLATE)"; then
  echo "📦 Lade Ubuntu Template (${LATEST_TEMPLATE}) herunter..."
  pveam download $TEMPLATE_STORE $LATEST_TEMPLATE
fi

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

# --- IP-Adresse Abruf (WICHTIG: Erzeugt die Domain OHNE Protokoll) ---
echo "⏳ Ermittle Container IP-Adresse..."
IP_ADDRESS=""
for i in {1..15}; do
  sleep 2
  IP_ADDRESS=$(pct exec $CTID -- hostname -I 2>/dev/null | awk '{print $1}')
  [ -n "$IP_ADDRESS" ] && break
done

if [ -z "$IP_ADDRESS" ]; then
    IP_ADDRESS="obico.local"
    echo "⚠️ Konnte IP-Adresse nicht ermitteln. Verwende Hostnamen: ${IP_ADDRESS}"
fi
# HIER IST DER FIX: Speichere nur die reine Domain + Port (OHNE http://)
SITE_DOMAIN="${IP_ADDRESS}:3334" 

# --- Installation & Initialisierung im Container ---
echo "🐳 Installiere Docker & ${APP}..."

pct exec $CTID -- bash -e <<EOF

# Lokale Shell-Funktion zur Wiederholung von Datenbank-Befehlen
retry_db_command() {
    local command=\$1
    local retries=15
    local i=0
    
    echo "Starte Wiederholungsversuche für: '\$command'"
    until [ \$i -ge \$retries ]
    do
        if eval "\$command"; then
            echo "Befehl erfolgreich."
            return 0
        fi
        i=\$((i+1))
        echo "Befehl fehlgeschlagen. Versuch \$i/\$retries. Warte 5 Sekunden..."
        sleep 5
    done

    echo "❌ Befehl konnte nach \$retries Versuchen nicht erfolgreich ausgeführt werden."
    return 1
}

# Container-Variablen aus dem Host-Skript setzen
DB_PASS="${DB_PASS}"
REDIS_PASS="${REDIS_PASS}"
ADMIN_EMAIL="${ADMIN_EMAIL}"
ADMIN_PASS="${ADMIN_PASS}"
GIT_URL="${GIT_URL}"
SITE_DOMAIN="${SITE_DOMAIN}" 

# ... (Installation und Konfiguration unverändert) ...
sleep 5 
apt update && apt install -y git curl docker.io docker-compose-v2
systemctl enable --now docker

cd /opt
git clone \${GIT_URL} obico
cd obico

if [ -f ".env.sample" ]; then
  cp .env.sample .env
elif [ -f ".env.template" ]; then
  cp .env.template .env
elif [ -f "compose.env.sample" ]; then
  cp compose.env.sample .env
else
  echo "POSTGRES_PASSWORD=\${DB_PASS}" > .env
  echo "REDIS_PASSWORD=\${REDIS_PASS}" >> .env
  echo "WEB_HOST=0.0.0.0" >> .env
fi

sed -i "s#POSTGRES_PASSWORD=.*#POSTGRES_PASSWORD=\${DB_PASS}#" .env
sed -i "s#REDIS_PASSWORD=.*#REDIS_PASSWORD=\${REDIS_PASS}#" .env
sed -i "s#WEB_HOST=.*#WEB_HOST=0.0.0.0#" .env

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
docker compose -f "\${COMPOSE_FILE}" up -d

# --- KRITISCHE INITIALISIERUNG MIT RETRY-LOOPS (Der Fix) ---
echo "⚙️  Warte auf Datenbank-Start und initialisiere Obico..."
sleep 10 

# 1. Migrationen anwenden
retry_db_command "docker compose run --rm -T web python manage.py migrate --noinput"

# 2. Admin-Benutzer erstellen
echo "➡️  Erstelle Admin-Benutzer (\${ADMIN_EMAIL})..."
ADMIN_COMMAND="echo \"from django.contrib.auth import get_user_model; User = get_user_model(); User.objects.create_superuser('\${ADMIN_EMAIL}', '\${ADMIN_PASS}')\" | docker compose run --rm -T web python manage.py shell"
retry_db_command "\$ADMIN_COMMAND"

# 3. Site-Eintrag korrigieren/erstellen (FIX: Verwendet \${SITE_DOMAIN} OHNE Protokoll)
echo "➡️  Erstelle/Korrigiere Site-Eintrag: \${SITE_DOMAIN}..."
SITE_COMMAND="echo \"from django.contrib.sites.models import Site; Site.objects.update_or_create(id=1, defaults={'domain': '\${SITE_DOMAIN}', 'name': 'Obico Local Server'})\" | docker compose run --rm -T web python manage.py shell"
retry_db_command "\$SITE_COMMAND"

# 4. Web-Dienst neu starten, um alle Änderungen zu übernehmen
echo "🔄 Starte Obico Web-Dienst neu, um Initialisierung abzuschließen..."
docker compose restart web

EOF

# -------------------------------------------------------------------
# --- Finale Ausgabe ---
# -------------------------------------------------------------------
clear
echo -e "\e[1;32m✅ ${APP} erfolgreich installiert und initialisiert!\e[0m"
echo "──────────────────────────────────────────────"
echo "📦 Container-ID : $CTID"
echo "🔑 Root Passwort  : $ROOTPASS"
echo "──────────────────────────────────────────────"
echo -e "\e[1;33m⚠️ Admin Zugangsdaten für Obico Server (3334):"
echo "    E-Mail: ${ADMIN_EMAIL}"
echo "    Passwort: ${ADMIN_PASS}\e[0m"
echo "──────────────────────────────────────────────"
# HIER wird das Protokoll für den Browser-Link hinzugefügt
echo "🌐 Obico läuft unter: http://${IP_ADDRESS}:3334" 
echo "💡 Öffne den Link im Browser und melde dich mit den obigen Daten an."
echo "──────────────────────────────────────────────"
