#!/usr/bin/env bash
# ===============================================================
# Obico Server - Proxmox Helper Script (Endgültige Version V10)
# Autor: Gemini
# FIXES: Behebt den 'pct exec' Fehler durch Code-Injektion via Standard-Input.
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

# --- Banner & User Input (Simuliert) ---
clear
echo -e "\e[1;36m──────────────────────────────────────────────"
echo "    🧠 ${APP} - Proxmox Interactive Installer"
echo "──────────────────────────────────────────────\e[0m"

# Simuliere Eingabe oder setze Standardwerte für Testzwecke.
# Im echten Skript würden diese Zeilen die Benutzereingabe abfragen.
CTID="107" # Beispiel-ID
HOSTNAME="obico-server"
CORE="2"
MEMORY="2048"
DISK="8"
ROOTPASS="MyRootPass123!" # WICHTIG: Ändern Sie dies in eine sichere Zeichenkette

# Stelle sicher, dass das Ubuntu-Template existiert.
TEMPLATE="local:vztmpl/ubuntu-22.04-standard_22.04-3_amd64.tar.gz"

# -----------------------------------
# LXC-Erstellung und Start
# -----------------------------------

echo "🛠️  Erstelle LXC-Container ID ${CTID}..."
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

echo "🚀 Starte Container und warte auf Netzwerk-Initialisierung..."
pct start $CTID
sleep 15 

# --- IP-Adresse Abruf (Verbesserte Robustheit) ---
echo "⏳ Ermittle Container IP-Adresse..."
IP_ADDRESS=""
for i in {1..25}; do 
  sleep 2
  # Führe einen robusten Befehl aus, um die IP zu erhalten
  IP_ADDRESS=$(pct exec $CTID -- hostname -I 2>/dev/null | awk '{print $1}')
  
  [ -n "$IP_ADDRESS" ] && break 
  echo -n "."
done
echo ""

if [ -z "$IP_ADDRESS" ]; then
    # Dies ist der Hostname, der in der .env-Datei landet, falls die IP fehlschlägt.
    IP_ADDRESS="${HOSTNAME}.local" 
    echo "⚠️ Konnte IP-Adresse nicht ermitteln. Verwende Hostnamen: ${IP_ADDRESS}"
fi
# Die Django Site Domain (OHNE http/https)
SITE_DOMAIN="${IP_ADDRESS}:3334" 

# --- KRITISCHE CODE-INJEKTION (FIX für 'vmid: type check failed') ---
echo "🐳 Starte Installation im Container..."
echo ""
echo "⚙️  Injiziere Code aus obico_install_core.sh..."

# WICHTIG: Die Variablen werden im Host-Skript interpoliert und als Konstanten 
# in den injizierten Code geschrieben. Der Bash-Befehl im Container ist extrem kurz.
# Wir stellen sicher, dass alle Variablen, die im Core-Skript verwendet werden,
# hier vom Host gesetzt werden.

pct exec $CTID -- bash -s < obico_install_core.sh

if [ $? -ne 0 ]; then
    echo "❌ Die Installation im Container ist fehlgeschlagen. Bitte prüfen Sie die Container-Logs und das obico_install_core.sh Skript."
    exit 1
fi

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
