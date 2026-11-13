#!/usr/bin/env bash
# =====================================================================
#  Obico Server – Proxmox VE Helper  (v2)
#  Installiert den Obico Server (Docker + SQLite) bis zum ersten Login
#  in einen unprivilegierten LXC-Container auf Proxmox VE.
#
#  Wichtig gegenüber v1:
#   - Es werden nur noch geprüfte LTS-Templates verwendet (Ubuntu 24.04/
#     22.04, Debian 13/12). Ubuntu 26.10 & Co. enthalten kein
#     /etc/lsb-release mehr und lassen sich von Proxmox nicht erstellen.
#   - Das Standard-Passwort des Obico-Admin-Accounts (supersecret) wird
#     durch ein zufälliges bzw. selbst gewähltes Passwort ersetzt.
#   - DEBUG bleibt aus (Produktionsempfehlung von Obico).
#   - Storage/Bridge/Template-Storage werden automatisch erkannt.
#   - Fehler hinterlassen einen klaren Wiederaufnahme-Befehl.
#
#  Kompatibel mit: Proxmox VE 8.x/9.x, obico-server (Branch "release")
# =====================================================================

set -Eeuo pipefail

SCRIPT_VERSION="2.0.0"
APP="Obico Server"
# Fester Port: docker-compose.yml von Obico mappt 3334:3334.
OBICO_PORT=3334
GIT_URL="${OBICO_GIT_URL:-https://github.com/TheSpaghettiDetective/obico-server.git}"
GIT_BRANCH="${OBICO_GIT_BRANCH:-release}"
DEFAULT_HOSTNAME="obico"
DEFAULT_CORES="2"
DEFAULT_MEMORY="4096"
DEFAULT_DISK="30"

# --- Farben (abschaltbar via NO_COLOR / Pipe) ---
if [[ -n ${NO_COLOR:-} ]] || [[ ! -t 1 ]]; then
    RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; NC=''
else
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
fi

err()  { echo -e "${RED}❌ $*${NC}" >&2; }
ok()   { echo -e "${GREEN}✓ $*${NC}"; }
info() { echo -e "${CYAN}ℹ️  $*${NC}"; }
warn() { echo -e "${YELLOW}⚠️  $*${NC}"; }
die()  { err "$*"; exit 1; }

# "clear" schlägt fehl, wenn TERM nicht gesetzt ist (CI, cron, nohup) und
# würde das Script durch "set -e" abbrechen. Deshalb nur bei echtem TTY.
clear_screen() {
    if [[ -t 1 ]]; then
        clear 2>/dev/null || true
    fi
}

usage() {
    cat <<EOF
${BOLD}Obico Server – Proxmox VE Helper v${SCRIPT_VERSION}${NC}

Aufruf:
  bash obico-proxmox-helper.sh [Optionen]

Optionen:
  -y, --yes      Alle Fragen mit den Standardwerten beantworten (unbeaufsichtigt)
  -h, --help     Diese Hilfe anzeigen
  -v, --version  Version anzeigen

Umgebungsvariablen (optional, überschreiben die Standardwerte):
  OBICO_CTID, OBICO_HOSTNAME, OBICO_CORES, OBICO_MEMORY, OBICO_DISK
  OBICO_STORAGE, OBICO_BRIDGE, OBICO_TEMPLATE
  OBICO_ADMIN_EMAIL, OBICO_ROOT_PASSWORD, OBICO_ADMIN_PASSWORD
  OBICO_GIT_URL, OBICO_GIT_BRANCH

Beispiel (unbeaufsichtigt):
  OBICO_CTID=112 OBICO_ADMIN_PASSWORD='MeinSicheresPasswort' \\
    bash obico-proxmox-helper.sh --yes
EOF
}

ASSUME_YES=0
for arg in "$@"; do
    case "$arg" in
        -y|--yes)   ASSUME_YES=1 ;;
        -h|--help)  usage; exit 0 ;;
        -v|--version) echo "obico-proxmox-helper.sh ${SCRIPT_VERSION}"; exit 0 ;;
        *) die "Unbekannte Option: ${arg} (siehe --help)" ;;
    esac
done

# --- Aufräumen ---
TMP_INSTALL=""
TMP_CONFIG=""
cleanup() {
    [[ -n $TMP_INSTALL ]] && rm -f "$TMP_INSTALL"
    [[ -n $TMP_CONFIG ]] && rm -f "$TMP_CONFIG"
    return 0
}
trap cleanup EXIT

CTID=""
trap 'trap_err $LINENO' ERR
trap_err() {
    local line="$1"
    err "Installation abgebrochen (Fehler in Zeile ${line})."
    if [[ -n $CTID ]] && pct status "$CTID" &>/dev/null; then
        echo ""
        echo "   Container ${CTID} existiert weiterhin. Installation im Container wiederholen:"
        echo "     pct exec ${CTID} -- bash /root/obico_install.sh"
        echo "   Oder komplett neu aufsetzen:"
        echo "     pct stop ${CTID} && pct destroy ${CTID}"
    fi
}

# --- Voraussetzungen ---
[[ ${EUID} -eq 0 ]] || die "Bitte als root auf dem Proxmox-VE-Host ausführen (nicht im Container)."
[[ -d /etc/pve ]] || die "'/etc/pve' fehlt – das ist kein Proxmox-VE-Host."

missing=()
for cmd in pct pveam pvesm qm openssl curl awk sed grep sort mktemp tar timeout; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done
(( ${#missing[@]} == 0 )) || die "Folgende Befehle fehlen: ${missing[*]} – ist das ein Proxmox-VE-Host?"

clear_screen
cat << "EOF"
╔═══════════════════════════════════════╗
║     OBICO SERVER INSTALLATION         ║
║       für Proxmox LXC Container       ║
╚═══════════════════════════════════════╝
EOF
echo ""
echo "Installiert Obico Server (Docker, SQLite) bis zum ersten Login."
echo "Die Django-Site wird automatisch auf die Container-IP gesetzt."
echo ""

# --- Hilfsfunktionen für Defaults ---
prompt_value() { # <Prompt> <Default> -> Wert auf stdout
    local prompt="$1" default="$2" input=""
    if (( ASSUME_YES )); then
        printf '%s' "$default"
        return 0
    fi
    read -rp "${prompt} (Standard: ${default}): " input || input=""
    printf '%s' "${input:-$default}"
}

list_storages() { # <content-type>
    pvesm status --content "$1" 2>/dev/null | awk 'NR>1 {print $1}'
}

default_rootfs_storage() {
    local s
    for s in local-lvm local-zfs; do
        if list_storages rootdir | grep -qx "$s"; then
            printf '%s' "$s"
            return 0
        fi
    done
    list_storages rootdir | head -n1
}

default_template_storage() {
    local s
    if list_storages vztmpl | grep -qx "local"; then
        printf '%s' "local"
        return 0
    fi
    list_storages vztmpl | head -n1
}

default_bridge() {
    local iface
    for iface in vmbr0 vmbr1 vmbr2; do
        [[ -e "/sys/class/net/${iface}" ]] && { printf '%s' "$iface"; return 0; }
    done
    for iface in /sys/class/net/vmbr*; do
        [[ -e $iface ]] && { printf '%s' "${iface##*/}"; return 0; }
    done
    printf '%s' ""
}

storage_available_bytes() {
    local sz
    sz=$(pvesm status --storage "$1" 2>/dev/null | awk 'NR==2 {print $6}')
    [[ $sz =~ ^[0-9]+$ ]] && printf '%s' "$sz" || printf '0'
}

# --- Container-ID ---
DEFAULT_CTID="${OBICO_CTID:-}"
if [[ -z $DEFAULT_CTID ]]; then
    DEFAULT_CTID=$(pvesh get /cluster/nextid --output-format json 2>/dev/null | tr -d '"[:space:]' || true)
fi
[[ $DEFAULT_CTID =~ ^[0-9]+$ ]] || DEFAULT_CTID=200

while :; do
    CTID=$(prompt_value "Container ID" "$DEFAULT_CTID")
    if ! [[ $CTID =~ ^[0-9]+$ ]]; then
        err "Bitte eine numerische Container-ID angeben."
        (( ASSUME_YES )) && die "Ungültige Container-ID: ${CTID}"
        continue
    fi
    if pct status "$CTID" &>/dev/null; then
        err "LXC-Container ${CTID} existiert bereits (löschen mit: pct destroy ${CTID})."
        (( ASSUME_YES )) && die "Container ${CTID} existiert bereits."
        continue
    fi
    if qm status "$CTID" &>/dev/null; then
        err "VM ${CTID} existiert bereits – ID ist belegt."
        (( ASSUME_YES )) && die "VM ${CTID} existiert bereits."
        continue
    fi
    break
done

# --- Hostname ---
DEFAULT_HOSTNAME="${OBICO_HOSTNAME:-$DEFAULT_HOSTNAME}"
while :; do
    HOSTNAME=$(prompt_value "Hostname" "$DEFAULT_HOSTNAME")
    if [[ ! $HOSTNAME =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]{0,61}[a-zA-Z0-9])?$ ]]; then
        err "Hostname: nur Buchstaben, Zahlen, Punkte und Bindestriche (max. 63 Zeichen)."
        (( ASSUME_YES )) && die "Ungültiger Hostname: ${HOSTNAME}"
        continue
    fi
    break
done

# --- CPU ---
while :; do
    CORES=$(prompt_value "CPU Cores" "${OBICO_CORES:-$DEFAULT_CORES}")
    if [[ ! $CORES =~ ^[0-9]+$ ]] || (( CORES < 1 || CORES > 128 )); then
        err "Bitte 1–128 Cores angeben."
        (( ASSUME_YES )) && die "Ungültige Core-Anzahl: ${CORES}"
        continue
    fi
    break
done

# --- RAM ---
while :; do
    MEMORY=$(prompt_value "RAM in MB" "${OBICO_MEMORY:-$DEFAULT_MEMORY}")
    if [[ ! $MEMORY =~ ^[0-9]+$ ]] || (( MEMORY < 1024 )); then
        err "Bitte mindestens 1024 MB RAM angeben."
        (( ASSUME_YES )) && die "Ungültige RAM-Angabe: ${MEMORY}"
        continue
    fi
    if (( MEMORY < 4096 )); then
        warn "Weniger als 4096 MB RAM: der erste Docker-Build (ml_api/PyTorch) kann scheitern oder sehr lange dauern."
    fi
    break
done

# --- Disk ---
while :; do
    DISK=$(prompt_value "Disk Size in GB" "${OBICO_DISK:-$DEFAULT_DISK}")
    if [[ ! $DISK =~ ^[0-9]+$ ]] || (( DISK < 10 )); then
        err "Bitte mindestens 10 GB angeben."
        (( ASSUME_YES )) && die "Ungültige Disk-Größe: ${DISK}"
        continue
    fi
    if (( DISK < 30 )); then
        warn "Unter 30 GB kann der Docker-Build (PyTorch-Images) knapp werden."
    fi
    break
done

# --- Storage ---
AUTO_STORAGE=$(default_rootfs_storage)
[[ -n $AUTO_STORAGE ]] || die "Kein Storage mit 'rootdir'-Inhalt gefunden – bitte in der Proxmox-GUI einen Storage für Container anlegen."
STORAGE="${OBICO_STORAGE:-$AUTO_STORAGE}"
while :; do
    STORAGE=$(prompt_value "Storage für Root-Volume" "$STORAGE")
    if list_storages rootdir | grep -qx "$STORAGE"; then
        break
    fi
    err "Storage '${STORAGE}' existiert nicht oder unterstützt kein rootdir. Verfügbar:"
    list_storages rootdir | sed 's/^/    - /'
    (( ASSUME_YES )) && die "Ungültiger Storage: ${STORAGE}"
done

AVAIL_BYTES=$(storage_available_bytes "$STORAGE")
if (( AVAIL_BYTES > 0 )); then
    AVAIL_GB=$(( AVAIL_BYTES / 1024 / 1024 / 1024 ))
    if (( AVAIL_GB < DISK + 2 )); then
        warn "Nur ${AVAIL_GB} GB auf '${STORAGE}' frei – ${DISK} GB Root-Volume + Template/Build benötigen mehr."
    else
        info "Freier Platz auf '${STORAGE}': ${AVAIL_GB} GB"
    fi
fi

# --- Bridge ---
AUTO_BRIDGE=$(default_bridge)
if [[ -z $AUTO_BRIDGE ]]; then
    err "Keine vmbr*-Bridge gefunden. Bitte zuerst eine Linux-Bridge in Proxmox anlegen."
    AUTO_BRIDGE="vmbr0"
fi
BRIDGE="${OBICO_BRIDGE:-$AUTO_BRIDGE}"
while :; do
    BRIDGE=$(prompt_value "Netzwerk-Bridge" "$BRIDGE")
    if [[ -e "/sys/class/net/${BRIDGE}" ]]; then
        break
    fi
    err "Bridge '${BRIDGE}' nicht gefunden. Vorhandene Bridges:"
    found=0
    for net in /sys/class/net/*; do
        if [[ ${net##*/} == vmbr* ]]; then
            echo "    - ${net##*/}"
            found=1
        fi
    done
    (( found == 0 )) && echo "    (keine vmbr* gefunden)"
    (( ASSUME_YES )) && die "Ungültige Bridge: ${BRIDGE}"
done

# --- Admin-Zugang ---
ADMIN_EMAIL="${OBICO_ADMIN_EMAIL:-root@example.com}"
while :; do
    ADMIN_EMAIL=$(prompt_value "Obico Admin-E-Mail" "$ADMIN_EMAIL")
    if [[ $ADMIN_EMAIL =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; then
        break
    fi
    err "Bitte eine gültige E-Mail-Adresse angeben."
    (( ASSUME_YES )) && die "Ungültige Admin-E-Mail: ${ADMIN_EMAIL}"
done

ADMIN_PASS="${OBICO_ADMIN_PASSWORD:-}"
if [[ -z $ADMIN_PASS ]]; then
    if (( ASSUME_YES )); then
        ADMIN_PASS=$(openssl rand -hex 8)
    else
        read -rsp "Obico Admin-Passwort (leer = automatisch generieren): " ADMIN_PASS || true
        echo ""
        [[ -z $ADMIN_PASS ]] && ADMIN_PASS=$(openssl rand -hex 8)
    fi
fi
(( ${#ADMIN_PASS} >= 8 )) || die "Das Admin-Passwort muss mindestens 8 Zeichen lang sein."

# --- Registrierung ---
ALLOW_SIGNUP="n"
if (( ! ASSUME_YES )); then
    read -rp "Neue Benutzer-Registrierung erlauben? [j/N]: " signup_in || signup_in="n"
    [[ ${signup_in:-n} =~ ^[JjYy1]$ ]] && ALLOW_SIGNUP="y"
fi
if [[ $ALLOW_SIGNUP == "y" ]]; then SIGNUP_BOOL="True"; else SIGNUP_BOOL="False"; fi

# --- Root-Passwort ---
ROOTPASS="${OBICO_ROOT_PASSWORD:-}"
GENERATED_PASS=0
if [[ -z $ROOTPASS ]]; then
    if (( ASSUME_YES )); then
        ROOTPASS=$(openssl rand -hex 10)
        GENERATED_PASS=1
    else
        read -rsp "Root-Passwort des Containers (leer = automatisch generieren): " ROOTPASS || true
        echo ""
        if [[ -z $ROOTPASS ]]; then
            ROOTPASS=$(openssl rand -hex 10)
            GENERATED_PASS=1
        fi
    fi
fi
(( ${#ROOTPASS} >= 5 )) || die "Das Root-Passwort muss mindestens 5 Zeichen lang sein (Proxmox-Vorgabe)."

# --- Zusammenfassung & Bestätigung ---
echo ""
info "Zusammenfassung:"
echo "   CT ${CTID} · ${HOSTNAME} · ${CORES} Cores · ${MEMORY} MB RAM · ${DISK} GB auf ${STORAGE} · Bridge ${BRIDGE}"
echo "   Admin-Login: ${ADMIN_EMAIL} · Registrierung: $([[ $ALLOW_SIGNUP == y ]] && echo "erlaubt" || echo "aus")"
if (( ! ASSUME_YES )); then
    read -rp "Installation starten? [J/n]: " CONFIRM || CONFIRM="J"
    CONFIRM=${CONFIRM:-J}
    if ! [[ $CONFIRM =~ ^[JjYy1]$ ]]; then
        info "Abgebrochen – es wurde nichts geändert."
        exit 0
    fi
fi

# --- Template-Auswahl (geprüfte LTS-Templates) ---
# Hintergrund: Proxmox wertet beim Erstellen /etc/lsb-release im Template aus.
# Ubuntu 26.10 (und ggf. weitere neue Nicht-LTS-Releases) enthält diese Datei
# nicht mehr -> "can't open '/var/lib/lxc/<ID>/rootfs/etc/lsb-release'".
# Deshalb: ausschließlich erprobte LTS-Templates, in dieser Reihenfolge.
TEMPLATE_PRIORITIES=(
    'ubuntu-24\.04-standard_[^[:space:]]+_amd64\.tar\.(zst|xz)'
    'ubuntu-22\.04-standard_[^[:space:]]+_amd64\.tar\.(zst|xz)'
    'debian-13-standard_[^[:space:]]+_amd64\.tar\.(zst|xz)'
    'debian-12-standard_[^[:space:]]+_amd64\.tar\.(zst|xz)'
)

echo ""
echo "📦 Template prüfen..."
pveam update >/dev/null 2>&1 || warn "pveam update fehlgeschlagen – verwende den vorhandenen Template-Index."

TPL_STORAGE=$(default_template_storage)
[[ -n $TPL_STORAGE ]] || die "Kein Storage mit 'vztmpl'-Inhalt gefunden (z. B. 'local')."
info "Template-Storage: ${TPL_STORAGE}"

LOCAL_TEMPLATES=$(pveam list "$TPL_STORAGE" 2>/dev/null || true)
AVAILABLE_TEMPLATES=$(pveam available 2>/dev/null || true)

CANDIDATES=()
for re in "${TEMPLATE_PRIORITIES[@]}"; do
    tpl=$(grep -Eo "$re" <<<"$LOCAL_TEMPLATES" | sort -uV | tail -n1 || true)
    if [[ -z $tpl ]]; then
        tpl=$(grep -Eo "$re" <<<"$AVAILABLE_TEMPLATES" | sort -uV | tail -n1 || true)
    fi
    if [[ -n $tpl ]] && [[ " ${CANDIDATES[*]:-} " != *" $tpl "* ]]; then
        CANDIDATES+=("$tpl")
    fi
done

if [[ -n ${OBICO_TEMPLATE:-} ]]; then
    CANDIDATES=("$OBICO_TEMPLATE" "${CANDIDATES[@]}")
fi

if (( ${#CANDIDATES[@]} == 0 )); then
    err "Kein geeignetes LTS-Template im pveam-Index gefunden (Ubuntu 24.04/22.04, Debian 13/12)."
    echo "Vorhandene Ubuntu-/Debian-Einträge:"
    grep -Ei 'ubuntu|debian' <<<"$AVAILABLE_TEMPLATES" | head -n 10 | sed 's/^/    /' || true
    info "Bitte 'pveam update' manuell ausführen und Netzwerk/DNS prüfen."
    die "Installation abgebrochen – es wurde noch kein Container erstellt."
fi

template_is_downloaded() {
    grep -qF ":vztmpl/$1" <<<"$LOCAL_TEMPLATES" 2>/dev/null || {
        LOCAL_TEMPLATES=$(pveam list "$TPL_STORAGE" 2>/dev/null || true)
        grep -qF ":vztmpl/$1" <<<"$LOCAL_TEMPLATES"
    }
}

download_template() {
    local tpl="$1"
    template_is_downloaded "$tpl" && return 0
    echo "⬇️  Lade ${tpl} herunter..."
    pveam download "$TPL_STORAGE" "$tpl"
    LOCAL_TEMPLATES=$(pveam list "$TPL_STORAGE" 2>/dev/null || true)
    template_is_downloaded "$tpl"
}

# Prüft, ob das Template /etc/lsb-release enthält (von älteren pve-container
# Versionen zwingend benötigt). Nur für Ubuntu-Templates relevant.
template_is_compatible() {
    local tpl="$1" path
    case "$tpl" in
        ubuntu-*) ;;
        *) return 0 ;;
    esac
    command -v zstd >/dev/null 2>&1 || return 0
    path=$(pvesm path "${TPL_STORAGE}:vztmpl/${tpl}" 2>/dev/null || true)
    [[ -n $path && -r $path ]] || return 0

    case "$path" in
        *.zst) zstd -dcq "$path" 2>/dev/null ;;
        *.xz)  xz -dc "$path" 2>/dev/null ;;
        *)     return 0 ;;
    esac | tar -tf - 2>/dev/null | awk '
        { sub(/^\.\//, "") }
        $0 == "etc/lsb-release" { found = 1 }
        END { exit(found ? 0 : 1) }
    '
}

cleanup_failed_ct() {
    pct destroy "$CTID" --force 1 >/dev/null 2>&1 || true
    rm -f "/etc/pve/lxc/${CTID}.conf" 2>/dev/null || true
}

# --- Container erstellen ---
echo ""
TEMPLATE=""
for tpl in "${CANDIDATES[@]}"; do
    if ! download_template "$tpl"; then
        warn "Template ${tpl} konnte nicht geladen werden – versuche das nächste."
        continue
    fi
    if ! template_is_compatible "$tpl"; then
        warn "Template ${tpl} enthält kein /etc/lsb-release – Proxmox kann daraus keinen Container erstellen. Überspringe."
        continue
    fi

    OSTYPE="ubuntu"
    [[ $tpl == debian-* ]] && OSTYPE="debian"

    echo "🚀 Erstelle LXC-Container ${CTID} mit ${tpl}..."
    if pct create "$CTID" "${TPL_STORAGE}:vztmpl/${tpl}" \
        -ostype "$OSTYPE" \
        -hostname "$HOSTNAME" \
        -cores "$CORES" \
        -memory "$MEMORY" \
        -rootfs "${STORAGE}:${DISK}" \
        -net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
        -unprivileged 1 \
        -features "nesting=1,keyctl=1" \
        -onboot 1 \
        -password "$ROOTPASS" \
        -description "${APP} (Docker) – installiert am $(date '+%d.%m.%Y %H:%M')"
    then
        TEMPLATE="${TPL_STORAGE}:vztmpl/${tpl}"
        break
    fi

    warn "Container-Erstellung mit ${tpl} fehlgeschlagen – Aufräumen und nächstes Template versuchen."
    cleanup_failed_ct
done

[[ -n $TEMPLATE ]] || die "Container ${CTID} konnte mit keinem verfügbaren Template erstellt werden. Details siehe oben."
ok "Container erstellt mit Template: ${TEMPLATE}"

pct start "$CTID"
echo "⏳ Warte auf Netzwerk des Containers..."

get_ct_ip() {
    local ip
    ip=$(timeout 15 pct exec "$CTID" -- hostname -I 2>/dev/null \
        | tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1 || true)
    if [[ -z $ip ]]; then
        ip=$(timeout 15 pct exec "$CTID" -- ip -4 -o addr show dev eth0 2>/dev/null \
            | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)
    fi
    printf '%s' "$ip"
}

IP_ADDRESS=""
for _ in $(seq 1 60); do
    IP_ADDRESS=$(get_ct_ip)
    if [[ -n $IP_ADDRESS ]]; then
        ok "IP-Adresse: ${IP_ADDRESS}"
        break
    fi
    echo -n "."
    sleep 2
done
echo ""
if [[ -z $IP_ADDRESS ]]; then
    die "Konnte keine IP ermitteln (120 s). DHCP/Bridge prüfen. Der Container ${CTID} bleibt bestehen."
fi

# --- Werte für die Installation im Container ---
DJANGO_SECRET=$(openssl rand -hex 32)

TMP_CONFIG=$(mktemp /tmp/obico-config.XXXXXX)
{
    printf 'CONTAINER_IP=%q\n'        "$IP_ADDRESS"
    printf 'OBICO_HOSTNAME=%q\n'      "$HOSTNAME"
    printf 'OBICO_PORT=%q\n'          "$OBICO_PORT"
    printf 'OBICO_ADMIN_EMAIL=%q\n'   "$ADMIN_EMAIL"
    printf 'OBICO_ADMIN_PASS=%q\n'    "$ADMIN_PASS"
    printf 'DJANGO_SECRET_KEY=%q\n'   "$DJANGO_SECRET"
    printf 'SIGNUP_BOOL=%q\n'         "$SIGNUP_BOOL"
    printf 'GIT_URL=%q\n'             "$GIT_URL"
    printf 'GIT_BRANCH=%q\n'          "$GIT_BRANCH"
} > "$TMP_CONFIG"

# --- Installations-Script für den Container ---
echo "📝 Erstelle Installations-Script..."
TMP_INSTALL=$(mktemp /tmp/obico-install.XXXXXX.sh)

cat > "$TMP_INSTALL" <<'EOF_INSTALL'
#!/bin/bash
# Läuft im Inneren des LXC-Containers. Kann nach einem Fehler erneut
# ausgeführt werden (idempotent, Datenbank bleibt erhalten).
set -Eeuo pipefail

CONF=/root/obico-setup.conf
[[ -r $CONF ]] || { echo "❌ ${CONF} fehlt." >&2; exit 1; }
# shellcheck source=/dev/null
source "$CONF"

export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C.UTF-8
export LANG=C.UTF-8
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "\n${CYAN}═══════════════════════════════════════${NC}"; echo -e "🔧 $*"; }
warn() { echo -e "${YELLOW}⚠️  $*${NC}"; }
ok()   { echo -e "${GREEN}✓ $*${NC}"; }
die()  { echo -e "${RED}❌ $*${NC}" >&2; exit 1; }
trap 'echo "❌ Fehler in Zeile $LINENO (Exit-Code $?)" >&2' ERR

log "Systemvorbereitung"
apt-get update -qq -o Acquire::Retries=5
apt-get -y -qq -o Dpkg::Options::=--force-confold upgrade
apt-get install -y -qq --no-install-recommends ca-certificates curl gnupg git
apt-get install -y -qq --no-install-recommends lsb-release >/dev/null 2>&1 || true

log "Docker CE installieren"
# Distribution zuverlässig aus /etc/os-release lesen (lsb_release fehlt
# z. B. in Ubuntu 26.10).
# shellcheck source=/dev/null
. /etc/os-release
DISTRO_ID="${ID}"
CODENAME="${VERSION_CODENAME:-}"
[[ -n $CODENAME ]] || die "VERSION_CODENAME fehlt in /etc/os-release – unbekannte Distribution."

install -m 0755 -d /etc/apt/keyrings
curl -fsSL --retry 5 --retry-delay 2 \
    "https://download.docker.com/linux/${DISTRO_ID}/gpg" \
    -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${DISTRO_ID} ${CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list

DOCKER_OK=0
if apt-get update -qq -o Acquire::Retries=3 && \
   apt-get install -y -qq --no-install-recommends \
       docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
    DOCKER_OK=1
else
    warn "Offizielles Docker-Repo für ${DISTRO_ID}/${CODENAME} nicht nutzbar – verwende Distribution-Pakete."
    rm -f /etc/apt/sources.list.d/docker.list
    apt-get update -qq -o Acquire::Retries=5
    apt-get install -y -qq --no-install-recommends docker.io docker-compose-v2 || \
        apt-get install -y -qq --no-install-recommends docker.io docker-compose
    DOCKER_OK=1
fi
(( DOCKER_OK == 1 )) || die "Docker konnte nicht installiert werden."

if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now docker >/dev/null 2>&1 || service docker start || true
else
    service docker start || true
fi
for _ in $(seq 1 10); do
    docker info >/dev/null 2>&1 && break
    sleep 2
done

# Auf ZFS-/Sonder-Storages kann overlay2 im unprivilegierten LXC scheitern.
# In dem Fall einmalig auf den (langsameren, speicherhungrigen) vfs-Treiber
# ausweichen, statt die Installation abzubrechen.
if ! docker info >/dev/null 2>&1; then
    warn "Docker startet nicht mit dem Standard-Storage-Treiber – weiche auf 'vfs' aus."
    mkdir -p /etc/docker
    printf '{\n  "storage-driver": "vfs"\n}\n' > /etc/docker/daemon.json
    if command -v systemctl >/dev/null 2>&1; then
        systemctl restart docker >/dev/null 2>&1 || service docker restart || true
    else
        service docker restart || true
    fi
    for _ in $(seq 1 15); do
        docker info >/dev/null 2>&1 && break
        sleep 2
    done
fi
docker info >/dev/null 2>&1 || die "Docker-Daemon läuft nicht."
docker --version

# Fallback, falls nur das alte 'docker-compose'-Binary installiert wurde.
if ! docker compose version >/dev/null 2>&1; then
    if command -v docker-compose >/dev/null 2>&1; then
        mkdir -p /usr/local/lib/docker/cli-plugins
        ln -sf "$(command -v docker-compose)" /usr/local/lib/docker/cli-plugins/docker-compose
    fi
fi
docker compose version || die "'docker compose' (Compose v2) ist nicht verfügbar."

log "Obico Server klonen (Branch ${GIT_BRANCH})"
if [[ -d /opt/obico/.git ]]; then
    git -C /opt/obico remote set-url origin "$GIT_URL"
    git -C /opt/obico fetch --depth 1 origin "$GIT_BRANCH"
    git -C /opt/obico reset --hard FETCH_HEAD
else
    # Niemals ein vorhandenes Verzeichnis mit Daten (z. B. db.sqlite3) löschen.
    if [[ -d /opt/obico ]] && [[ -n $(ls -A /opt/obico 2>/dev/null || true) ]]; then
        die "/opt/obico existiert, ist aber kein Git-Repository. Bitte Inhalt sichern/prüfen und das Verzeichnis manuell entfernen."
    fi
    rm -rf /opt/obico
    for attempt in 1 2 3; do
        if git clone --depth 1 --branch "$GIT_BRANCH" "$GIT_URL" /opt/obico; then
            break
        fi
        warn "git clone fehlgeschlagen (Versuch ${attempt}/3) – neuer Versuch..."
        rm -rf /opt/obico
        sleep 5
    done
fi
[[ -d /opt/obico/.git ]] || die "Obico-Repository konnte nicht geklont werden."
cd /opt/obico

log "Konfiguration (.env)"
# Bei einem erneuten Lauf den vorhandenen Secret Key behalten, damit
# bestehende Sitzungen gültig bleiben.
if [[ -f .env ]]; then
    EXISTING_SECRET=$(sed -n 's/^DJANGO_SECRET_KEY=//p' .env | head -n1)
    [[ -n $EXISTING_SECRET ]] && DJANGO_SECRET_KEY="$EXISTING_SECRET"
fi

cat > .env <<ENVFILE
DEBUG=False
DJANGO_SECRET_KEY=${DJANGO_SECRET_KEY}
CSRF_TRUSTED_ORIGINS=["http://${CONTAINER_IP}:${OBICO_PORT}","http://${OBICO_HOSTNAME}:${OBICO_PORT}","http://localhost:${OBICO_PORT}"]
ACCOUNT_ALLOW_SIGN_UP=${SIGNUP_BOOL}
SOCIAL_LOGIN=False
SITE_IS_PUBLIC=False
SITE_USES_HTTPS=False
ENVFILE
chmod 600 .env
ok ".env erstellt (Secret Key gesetzt, CSRF für ${CONTAINER_IP}:${OBICO_PORT})"

log "Images bauen & Services starten (erster Build: 15–30 Minuten)"
docker compose up -d --build

log "Warte auf den Web-Dienst (max. 10 Minuten)"
WEB_READY=0
DEADLINE=$(( SECONDS + 600 ))
while (( SECONDS < DEADLINE )); do
    if curl -fsS --max-time 5 "http://localhost:${OBICO_PORT}/hc/" >/dev/null 2>&1; then
        WEB_READY=1
        break
    fi
    echo -n "."
    sleep 5
done
echo ""
if (( WEB_READY != 1 )); then
    warn "Web-Dienst nach 10 Minuten nicht erreichbar. Letzte Logzeilen:"
    docker compose logs --tail=80 web || true
    die "Web-Dienst konnte nicht gestartet werden."
fi
ok "Obico Web-Dienst ist erreichbar."

# Der Login-Test beweist, dass auch collectstatic/Whitenoise funktionieren
# (mit DEBUG=False würde ein fehlendes Static-Manifest hier einen 500er geben).
for _ in $(seq 1 12); do
    curl -fsS --max-time 5 "http://localhost:${OBICO_PORT}/accounts/login/" >/dev/null 2>&1 && break
    sleep 5
done
curl -fsS --max-time 5 "http://localhost:${OBICO_PORT}/accounts/login/" >/dev/null 2>&1 \
    || warn "Login-Seite liefert keinen 200er – bitte 'docker compose logs web' prüfen."

log "Admin-Zugang & Django-Site konfigurieren"
ADMIN_PY=$(cat <<'PY'
import os
from django.contrib.auth import get_user_model
from django.contrib.sites.models import Site
from app.models import Syndicate

domain = os.environ["OBICO_SITE_DOMAIN"]
email = os.environ["OBICO_ADMIN_EMAIL"]
password = os.environ["OBICO_ADMIN_PASS"]

User = get_user_model()
user = User.objects.filter(is_superuser=True).order_by("id").first()
if user is None:
    user = User.objects.create_superuser(email, password)
    print(f"Neuer Admin angelegt: {email}")
else:
    user.email = email
    user.set_password(password)
    user.is_staff = True
    user.is_superuser = True
    user.is_active = True
    user.save()
    print(f"Admin aktualisiert: {email}")

# Obico legt per Migration eine Site "localhost:3334" an. Diese wird
# umbenannt (statt eine zweite Site anzulegen – davon rät Obico ab).
site = (
    Site.objects.filter(domain__iexact=domain).first()
    or Site.objects.filter(domain__iexact="localhost:3334").first()
    or Site.objects.order_by("id").first()
)
if site is None:
    site = Site.objects.create(domain=domain, name="Obico Server")
else:
    site.domain = domain
    site.name = "Obico Server"
    site.save()

syndicate = Syndicate.objects.order_by("id").first()
if syndicate is not None and not site.syndicates.filter(pk=syndicate.pk).exists():
    site.syndicates.add(syndicate)

print(f"Django-Site: {site.domain}")
PY
)

if docker compose exec -T \
    -e OBICO_SITE_DOMAIN="${CONTAINER_IP}:${OBICO_PORT}" \
    -e OBICO_ADMIN_EMAIL="$OBICO_ADMIN_EMAIL" \
    -e OBICO_ADMIN_PASS="$OBICO_ADMIN_PASS" \
    web python manage.py shell -c "$ADMIN_PY"
then
    ok "Admin: ${OBICO_ADMIN_EMAIL} · Site: ${CONTAINER_IP}:${OBICO_PORT}"
else
    warn "Admin/Site konnten nicht gesetzt werden – später über http://${CONTAINER_IP}:${OBICO_PORT}/admin/ möglich."
fi

# Kleiner Helfer für IP-Änderungen (bleibt bei git-Updates erhalten).
cat > /usr/local/bin/obico-set-site <<'HELPER'
#!/bin/bash
set -euo pipefail
domain="${1:?Aufruf: obico-set-site <ip-oder-hostname>[:port]}"
[[ $domain == *:* ]] || domain="${domain}:3334"
cd /opt/obico
docker compose exec -T -e OBICO_SITE_DOMAIN="$domain" web python manage.py shell -c '
import os
from django.contrib.sites.models import Site
from app.models import Syndicate

domain = os.environ["OBICO_SITE_DOMAIN"]
site = (
    Site.objects.filter(domain__iexact=domain).first()
    or Site.objects.filter(domain__iexact="localhost:3334").first()
    or Site.objects.order_by("id").first()
)
if site is None:
    site = Site.objects.create(domain=domain, name="Obico Server")
else:
    site.domain = domain
    site.name = "Obico Server"
    site.save()

syndicate = Syndicate.objects.order_by("id").first()
if syndicate is not None and not site.syndicates.filter(pk=syndicate.pk).exists():
    site.syndicates.add(syndicate)
print("Django-Site:", site.domain)
'
HELPER
chmod 0755 /usr/local/bin/obico-set-site

log "Warte auf die ML-API (erster Start kann einige Minuten dauern)"
ML_READY=0
for _ in $(seq 1 60); do
    if docker compose exec -T web wget -q --spider --no-check-certificate http://ml_api:3333/hc/ >/dev/null 2>&1; then
        ML_READY=1
        break
    fi
    echo -n "."
    sleep 5
done
echo ""
if (( ML_READY == 1 )); then
    ok "ML-API ist erreichbar."
else
    warn "ML-API noch nicht erreichbar – sie lädt beim ersten Start das Modell. Logs:"
    docker compose logs --tail=40 ml_api || true
fi

log "Service-Status"
docker compose ps
echo ""
ok "Installation im Container abgeschlossen."
EOF_INSTALL

pct push "$CTID" "$TMP_INSTALL" /root/obico_install.sh --perms 0700
pct push "$CTID" "$TMP_CONFIG" /root/obico-setup.conf --perms 0600
pct exec "$CTID" -- chmod 600 /root/obico-setup.conf
echo "🚀 Starte Installation im Container (Docker-Build kann dauern – nicht abbrechen)..."
pct exec "$CTID" -- bash /root/obico_install.sh

# --- Verifikation vom Host aus ---
echo ""
info "Prüfe Obico vom Proxmox-Host aus..."
HOST_CHECK=0
for _ in $(seq 1 20); do
    if curl -fsS --max-time 5 "http://${IP_ADDRESS}:${OBICO_PORT}/hc/" >/dev/null 2>&1; then
        HOST_CHECK=1
        break
    fi
    sleep 3
done
if (( HOST_CHECK == 1 )); then
    ok "Obico antwortet unter http://${IP_ADDRESS}:${OBICO_PORT}"
else
    warn "Obico antwortet vom Host aus noch nicht – Container-IP/Firewall prüfen."
fi

# --- Zugangsdaten ablegen ---
INFO_FILE="/root/obico-${CTID}-access.txt"
umask 077
cat > "$INFO_FILE" <<EOF
Obico Server – Zugangsdaten & Befehle
Erstellt: $(date '+%d.%m.%Y %H:%M')

Container ID : ${CTID}
Hostname     : ${HOSTNAME}
IP-Adresse   : ${IP_ADDRESS}
URL          : http://${IP_ADDRESS}:${OBICO_PORT}
Admin-URL    : http://${IP_ADDRESS}:${OBICO_PORT}/admin/
Admin-Login  : ${ADMIN_EMAIL}
Admin-Passwort: ${ADMIN_PASS}
Root-Passwort: ${ROOTPASS}
Obico-Branch : ${GIT_BRANCH}

Befehle:
  pct enter ${CTID}
  pct exec ${CTID} -- docker compose -f /opt/obico/docker-compose.yml ps
  pct exec ${CTID} -- docker compose -f /opt/obico/docker-compose.yml logs -f web
  pct exec ${CTID} -- bash /root/obico_install.sh        # Installation erneut ausführen
  pct exec ${CTID} -- obico-set-site <neue-ip>           # Django-Site auf neue IP setzen

Entfernen:
  pct stop ${CTID} && pct destroy ${CTID}
EOF
chmod 600 "$INFO_FILE"

# --- Finale Ausgabe ---
clear_screen
cat << "EOF"
╔═══════════════════════════════════════╗
║     ✅ INSTALLATION ERFOLGREICH       ║
╚═══════════════════════════════════════╝
EOF
echo ""
echo "📦 Container ID  : $CTID"
echo "🏷️  Hostname      : $HOSTNAME"
if (( GENERATED_PASS == 1 )); then
    echo "🔑 Root-Passwort : $ROOTPASS (automatisch generiert)"
else
    echo "🔑 Root-Passwort : $ROOTPASS"
fi
echo "🌐 IP-Adresse    : $IP_ADDRESS"
echo ""
echo -e "${GREEN}🌍 Obico:      http://${IP_ADDRESS}:${OBICO_PORT}${NC}"
echo -e "${GREEN}🛠️  Django-Admin: http://${IP_ADDRESS}:${OBICO_PORT}/admin/${NC}"
echo "   E-Mail   : ${ADMIN_EMAIL}"
echo "   Passwort : ${ADMIN_PASS}"
echo ""
echo "📝 NÄCHSTE SCHRITTE:"
echo "   1️⃣  http://${IP_ADDRESS}:${OBICO_PORT} im Browser öffnen"
echo "   2️⃣  Mit den oben genannten Admin-Zugangsdaten anmelden"
echo "      (das unsichere Upstream-Standardpasswort 'supersecret' wurde ersetzt)"
echo "   3️⃣  Drucker anbinden (OctoPrint/Moonraker-Plugin) und Kamera hinzufügen"
echo ""
echo "💾 Alle Zugangsdaten stehen in: ${INFO_FILE}"
echo ""
echo "💡 Tipp: Vergib im Router eine feste DHCP-Reservierung für ${IP_ADDRESS},"
echo "   damit URL- und Django-Site-Konfiguration stabil bleiben."
echo ""
echo "🛠️  Nützliche Befehle:"
echo "   pct enter $CTID"
echo "   pct exec $CTID -- docker compose -f /opt/obico/docker-compose.yml ps"
echo "   pct exec $CTID -- docker compose -f /opt/obico/docker-compose.yml logs -f web"
echo "   pct exec $CTID -- docker compose -f /opt/obico/docker-compose.yml restart"
echo "   pct exec $CTID -- obico-set-site <neue-ip>"
