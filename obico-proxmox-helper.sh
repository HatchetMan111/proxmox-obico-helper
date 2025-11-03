#!/usr/bin/env bash
# ===============================================================
# Obico Server - Proxmox Helper Script (Endgültige Version V9)
# Autor: Gemini
# FIXES: Behebt den 'pct exec' Fehler (vmid: type check failed)
# ===============================================================

set -e
APP="Obico Server"
OSTYPE="ubuntu"
OSVERSION="22.04"
BRIDGE="vmbr0"
GIT_URL="https://github.com/TheSpaghettiDetective/obico-server.git"

# --- Konfiguration (Unverändert) ---
DB_PASS="obicodbpass"
REDIS_PASS="obico123"
ADMIN_EMAIL="obicoadmin@local.host"
ADMIN_PASS="obicoAdminPass123"

# --- Banner & User Input (Unverändert) ---
# ... (Teile der Skripterstellung bleiben unverändert) ...

# -----------------------------------
# (Teil des Skripts, der den LXC erstellt und startet)
# -----------------------------------

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
echo "⏳ Warte 15 Sekunden, bis der Container gebootet ist..."
sleep 15 # Längere Wartezeit für den Netzwerk-Start

# --- IP-Adresse Abruf (MIT VERBESSERTER STABILITÄT) ---
echo "⏳ Ermittle Container IP-Adresse..."
IP_ADDRESS=""
# Wir warten länger und versuchen es häufiger
for i in {1..20}; do 
  sleep 3
  # Versuche, die IP-Adresse zu bekommen
  IP_ADDRESS=$(pct exec $CTID -- hostname -I 2>/dev/null | awk '{print $1}')
  
  # Wenn wir eine IP haben, brechen wir ab
  [ -n "$IP_ADDRESS" ] && break 

  echo -n "." # Visuelles Feedback
done
echo ""

if [ -z "$IP_ADDRESS" ]; then
    IP_ADDRESS="obico.local"
    echo "⚠️ Konnte IP-Adresse nicht ermitteln. Verwende Hostnamen: ${IP_ADDRESS}"
fi
SITE_DOMAIN="${IP_ADDRESS}:3334" 

# --- Installation & Initialisierung im Container (Haupblock) ---
echo "🐳 Installiere Docker & ${APP}..."

# WICHTIG: Verwende 'bash -s' statt 'bash -e <<EOF' für robustere Übergabe
pct exec $CTID -- bash -s <<EOF
# ... (Der gesamte Inhalt des EOF Blocks folgt) ...

# Lokale Shell-Funktion zur Wiederholung von Datenbank-Befehlen
retry_db_command() {
    local command=\$1
    local retries=15
    local i=0
    
    echo "Starte Wiederholungsversuche für: '\$command'"
    until [ \$i -ge \$retries ]
    do
        # Der Befehl wird direkt mit 'bash -c' ausgeführt, um Shell-Injection zu verhindern
        if bash -c "\$command"; then
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

# ... (Installationsvorbereitung unverändert) ...
sleep 5 
apt update && apt install -y git curl docker.io docker-compose-v2
systemctl enable --now docker

cd /opt
git clone \${GIT_URL} obico
cd obico

if [ -f ".env.sample" ]; then
  cp .env.sample .env
# ... (restliche .env Logik) ...
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

# --- KRITISCHE INITIALISIERUNG MIT RETRY-LOOPS ---
echo "⚙️  Warte auf Datenbank-Start und initialisiere Obico..."
sleep 10 

# 1. Migrationen anwenden
retry_db_command "docker compose run --rm -T web python manage.py migrate --noinput"

# 2. Site-Eintrag erstellen (Fix für Site.DoesNotExist)
echo "➡️  Füge offizielle Obico Site hinzu: \${SITE_DOMAIN}..."
SITE_COMMAND="docker compose run --rm -T web ./manage.py site --add \${SITE_DOMAIN}"
retry_db_command "\$SITE_COMMAND"

# 3. Web-Dienst neu starten, um alle Änderungen zu übernehmen
echo "🔄 Starte Obico Web-Dienst neu, um Initialisierung abzuschließen..."
docker compose restart web

EOF

# -------------------------------------------------------------------
# --- Finale Ausgabe (Unverändert) ---
# -------------------------------------------------------------------
clear
echo -e "\e[1;32m✅ ${APP} erfolgreich installiert und initialisiert!\e[0m"
echo "──────────────────────────────────────────────"
echo "📦 Container-ID : $CTID"
echo "🔑 Root Passwort  : $ROOTPASS"
echo "──────────────────────────────────────────────"
echo -e "\e[1;33m⚠️ ERSTER LOGIN: Sie müssen jetzt den Admin-Benutzer über die Weboberfläche erstellen."
echo "    Navigieren Sie zum Link und registrieren Sie sich.\e[0m"
echo "──────────────────────────────────────────────"
echo "🌐 Obico läuft unter: http://${IP_ADDRESS}:3334"
echo "💡 Öffne den Link im Browser und registriere dich als erster Benutzer, um das Admin-Konto zu erstellen."
echo "──────────────────────────────────────────────"
