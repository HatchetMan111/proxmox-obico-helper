#!/usr/bin/env bash
# ===============================================================
# Kern-Installationsskript für Obico Server (Läuft IM Container)
# ===============================================================

set -e

# Lokale Shell-Funktion zur Wiederholung von Datenbank-Befehlen
retry_db_command() {
    local command="$1"
    local retries=15
    local i=0
    
    echo "Starte Wiederholungsversuche für: '$command'"
    until [ $i -ge $retries ]
    do
        # Führe den Befehl direkt aus
        if bash -c "$command"; then
            echo "Befehl erfolgreich."
            return 0
        fi
        i=$((i+1))
        echo "Befehl fehlgeschlagen. Versuch $i/$retries. Warte 5 Sekunden..."
        sleep 5
    done

    echo "❌ Befehl konnte nach $retries Versuchen nicht erfolgreich ausgeführt werden."
    return 1
}

echo "➡️  Aktualisiere System und installiere Docker Komponenten..."
apt update && apt install -y git curl docker.io docker-compose-v2
systemctl enable --now docker

cd /opt
git clone ${GIT_URL} obico
cd obico

# --- Konfiguriere .env Datei ---
echo "➡️  Konfiguriere Obico Umgebungsvariablen..."
if [ -f ".env.sample" ]; then
  cp .env.sample .env
elif [ -f ".env.template" ]; then
  cp .env.template .env
elif [ -f "compose.env.sample" ]; then
  cp compose.env.sample .env
else
  echo "POSTGRES_PASSWORD=${DB_PASS}" > .env
  echo "REDIS_PASSWORD=${REDIS_PASS}" >> .env
  echo "WEB_HOST=0.0.0.0" >> .env
fi

# Ersetze oder setze die Passwörter und den Host
sed -i "s#POSTGRES_PASSWORD=.*#POSTGRES_PASSWORD=${DB_PASS}#" .env
sed -i "s#REDIS_PASSWORD=.*#REDIS_PASSWORD=${REDIS_PASS}#" .env
sed -i "s#WEB_HOST=.*#WEB_HOST=0.0.0.0#" .env

# --- Finde Docker Compose Datei ---
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

# --- KRITISCHE INITIALISIERUNG UND FIX ---
echo "⚙️  Warte auf Datenbank-Start und initialisiere Obico..."
sleep 15 

# 1. Migrationen anwenden
retry_db_command "docker compose run --rm -T web python manage.py migrate --noinput"

# 2. Site-Eintrag erstellen (FIX für Site.DoesNotExist)
echo "➡️  Füge offizielle Obico Site hinzu: ${SITE_DOMAIN}..."
SITE_COMMAND="docker compose run --rm -T web ./manage.py site --add ${SITE_DOMAIN}"
retry_db_command "$SITE_COMMAND"

# 3. Web-Dienst neu starten, um alle Änderungen zu übernehmen
echo "🔄 Starte Obico Web-Dienst neu, um Initialisierung abzuschließen..."
docker compose restart web

echo "✅ Container-Installation abgeschlossen."
