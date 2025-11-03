#!/usr/bin/env bash
# ===============================================================
# Obico Server - Proxmox Helper Script (Endgültige Version V8)
# Autor: Gemini
# FIXES: Implementiert den offiziellen 'manage.py site --add' Befehl
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
# Der Benutzer muss den Admin über die Web-UI erstellen, da 'site --add'
# keine Option für die automatische Superuser-Erstellung bietet.
# Wir lassen den createsuperuser-Befehl weg, um uns auf den Site-Fix zu konzentrieren.

# --- Banner & User Input (Unverändert) ---
clear
echo -e "\e[1;36m──────────────────────────────────────────────"
echo "    🧠 ${APP} - Proxmox Interactive Installer"
echo "──────────────────────────────────────────────\e[0m"

# --- User Input und LXC-Erstellung (Unverändert) ---
# ... (Teile der Skripterstellung bleiben unverändert) ...

# -----------------------------------
# (Teil des Skripts, der den LXC erstellt und startet)
# -----------------------------------

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
# Speichere nur die reine Domain + Port (OHNE http://) für die Datenbank
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

# ... (Installationsvorbereitung unverändert) ...
sleep 5 
apt update && apt install -y git curl docker.io docker-compose-v2
systemctl enable --now docker

cd /opt
git clone \${GIT_URL} obico
cd obico

# ... (Konfiguration von .env und COMPOSE_FILE unverändert) ...
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

# --- KRITISCHE INITIALISIERUNG MIT RETRY-LOOPS (Implementierung des neuen Befehls) ---
echo "⚙️  Warte auf Datenbank-Start und initialisiere Obico..."
sleep 10 

# 1. Migrationen anwenden
retry_db_command "docker compose run --rm -T web python manage.py migrate --noinput"

# 2. Site-Eintrag erstellen (FIX: Der offizielle Obico-Befehl)
echo "➡️  Füge offizielle Obico Site hinzu: \${SITE_DOMAIN}..."
SITE_COMMAND="docker compose run --rm -T web ./manage.py site --add \${SITE_DOMAIN}"
retry_db_command "\$SITE_COMMAND"

# 3. Web-Dienst neu starten, um alle Änderungen zu übernehmen
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
echo -e "\e[1;33m⚠️ ERSTER LOGIN: Sie müssen jetzt den Admin-Benutzer über die Weboberfläche erstellen."
echo "    Navigieren Sie zum Link und registrieren Sie sich.\e[0m"
echo "──────────────────────────────────────────────"
echo "🌐 Obico läuft unter: http://${IP_ADDRESS}:3334"
echo "💡 Öffne den Link im Browser und registriere dich als erster Benutzer, um das Admin-Konto zu erstellen."
echo "──────────────────────────────────────────────"
