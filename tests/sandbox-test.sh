#!/usr/bin/env bash
# =====================================================================
#  Sandbox-Tests für obico-proxmox-helper.sh
#
#  Simuliert einen Proxmox-Host mit gefälschten pct/pveam/pvesm-Befehlen
#  und prüft die kritischen Pfade:
#    - Template-Auswahl (nur LTS, Ubuntu ohne /etc/lsb-release wird
#      übersprungen, Debian-Fallback)
#    - automatischer Template-Wechsel, wenn "pct create" scheitert
#    - sauberer Abbruch, wenn kein LTS-Template verfügbar ist
#    - erzeugte Config, inneres Install-Script und Zugangsdaten-Datei
#
#  Aufruf:  bash tests/sandbox-test.sh
#  Benötigt: bash, tar, zstd (für die Template-Archive)
# =====================================================================
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SRC="$REPO_ROOT/obico-proxmox-helper.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/obico-sandbox.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0

expect() { # <datei> <muster> <beschreibung>
    if grep -qE -- "$2" "$1"; then
        echo "  ✓ $3"
        pass=$((pass + 1))
    else
        echo "  ✗ $3"
        fail=$((fail + 1))
    fi
}

refute() { # <datei> <muster> <beschreibung>
    if grep -qE -- "$2" "$1"; then
        echo "  ✗ $3"
        fail=$((fail + 1))
    else
        echo "  ✓ $3"
        pass=$((pass + 1))
    fi
}

command -v zstd >/dev/null 2>&1 || {
    echo "zstd wird für die Template-Tests benötigt (apt-get install zstd)." >&2
    exit 1
}

# --- Sandbox mit gefälschten Proxmox-Befehlen aufbauen ---
setup() {
    local scenario="$1"
    BASE="$WORK/$scenario"
    mkdir -p "$BASE"/{bin,template-cache,pushed,root,tpl}

    # Root-/Proxmox-Prüfungen entfernen und die Info-Datei ins Temp-Verzeichnis
    # umlenken – der Test läuft bewusst ohne root.
    sed -e 's|^\[\[ ${EUID} -eq 0 \]\].*|true|' \
        -e 's|^\[\[ -d /etc/pve \]\].*|true|' \
        -e "s|INFO_FILE=\"/root/obico-\${CTID}-access.txt\"|INFO_FILE=\"$BASE/root/obico-\${CTID}-access.txt\"|" \
        "$SRC" > "$BASE/helper-test.sh"
    chmod +x "$BASE/helper-test.sh"

    cat > "$BASE/bin/pct" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
STATE="${FAKE_STATE:?}"
cmd="${1:?}"; shift || true
case "$cmd" in
  status) [[ -f $STATE ]] || exit 1; echo "status: running" ;;
  create)
    id="$1"
    echo "create $id $*" >> "$FAKE_LOG"
    if [[ -n ${FAKE_FAIL_TEMPLATE:-} ]] && [[ "$*" == *"$FAKE_FAIL_TEMPLATE"* ]]; then
        echo "unable to create CT ${id} (simulierter Fehler)" >&2
        exit 255
    fi
    touch "$STATE"
    ;;
  start) echo "start $*" >> "$FAKE_LOG" ;;
  destroy) rm -f "$STATE"; echo "destroy $*" >> "$FAKE_LOG" ;;
  push) id="$1"; shift; cp "$1" "$FAKE_PUSHED/$(basename "$2")"; echo "push $1 -> $2" >> "$FAKE_LOG" ;;
  exec)
    id="$1"; shift; [[ $1 == "--" ]] && shift
    case "$*" in
      *"hostname -I"*) echo "192.168.1.50 " ;;
      *"ip -4 -o addr"*) echo "2: eth0    inet 192.168.1.50/24 scope global eth0" ;;
      *obico_install.sh*) echo "install-script-aufgerufen" >> "$FAKE_LOG" ;;
      *) : ;;
    esac
    ;;
  *) : ;;
esac
EOF

    cat > "$BASE/bin/pveam" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:?}" in
  update) : ;;
  list)
    shopt -s nullglob
    for f in "$FAKE_TPL_DIR"/*; do
      echo "local:vztmpl/$(basename "$f")  144.20MB"
    done
    ;;
  available) cat "$FAKE_AVAILABLE" ;;
  download) : ;;
  *) : ;;
esac
EOF

    cat > "$BASE/bin/pvesm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:?}" in
  status)
    if [[ ${2:-} == "--storage" ]]; then
      printf 'Name Type Status Total Used Available %%\nlocal-lvm lvmthin active 100 10 90000000000 10%%\n'
    elif [[ ${3:-} == "vztmpl" ]]; then
      printf 'Name Type Status Total Used Available %%\nlocal dir active 1 1 1 1%%\n'
    else
      printf 'Name Type Status Total Used Available %%\nlocal-lvm lvmthin active 100 10 90000000000 10%%\n'
    fi
    ;;
  path) tpl="${2##*/}"; echo "$FAKE_TPL_DIR/$tpl" ;;
  *) : ;;
esac
EOF

    printf '#!/usr/bin/env bash\nexit 1\n' > "$BASE/bin/qm"
    printf '#!/usr/bin/env bash\necho \x27"112"\x27\n' > "$BASE/bin/pvesh"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$BASE/bin/curl"
    chmod +x "$BASE/bin/"*

    printf 'system          ubuntu-26.10-standard_26.10-1_amd64.tar.zst\nsystem          ubuntu-24.04-standard_24.04-2_amd64.tar.zst\nsystem          ubuntu-22.04-standard_22.04-1_amd64.tar.zst\nsystem          debian-12-standard_12.7-1_amd64.tar.zst\n' \
        > "$BASE/available.txt"

    export PATH="$BASE/bin:$PATH"
    export FAKE_STATE="$BASE/ct.state" FAKE_LOG="$BASE/actions.log" \
           FAKE_PUSHED="$BASE/pushed" FAKE_TPL_DIR="$BASE/template-cache" \
           FAKE_AVAILABLE="$BASE/available.txt"
}

make_template() { # <dateiname> [yes|no = enthält /etc/lsb-release]
    local name="$1" lsb="${2:-yes}"
    local dir="$BASE/tpl/$name"
    rm -rf "$dir"; mkdir -p "$dir/etc"
    echo "ID=ubuntu" > "$dir/etc/os-release"
    if [[ $lsb == yes ]]; then echo "DISTRIB_ID=Ubuntu" > "$dir/etc/lsb-release"; fi
    tar -C "$dir" -cf - . | zstd -q -o "$BASE/template-cache/$name"
}

run_helper() {
    : > "$FAKE_LOG"
    OBICO_CTID=112 OBICO_ADMIN_EMAIL="admin@example.com" OBICO_BRIDGE=lo \
        bash "$BASE/helper-test.sh" --yes > "$BASE/run.log" 2>&1 || true
}

echo "Szenario 1: Ubuntu 24.04 ohne lsb-release, 22.04 vorhanden"
setup s1
make_template ubuntu-24.04-standard_24.04-2_amd64.tar.zst no
make_template ubuntu-22.04-standard_22.04-1_amd64.tar.zst yes
run_helper
expect "$BASE/run.log" "ubuntu-22.04-standard_22.04-1_amd64.tar.zst" "22.04 wird als Fallback gewählt"
expect "$BASE/run.log" "Überspringe" "inkompatibles Template wird gemeldet"
refute "$BASE/run.log" "Ubuntu 26.10" "26.10 wird nie automatisch gewählt"

echo "Szenario 2: nur Ubuntu 26.10 verfügbar"
setup s2
printf 'system          ubuntu-26.10-standard_26.10-1_amd64.tar.zst\n' > "$BASE/available.txt"
run_helper
expect "$BASE/run.log" "Kein geeignetes LTS-Template" "sauberer Abbruch mit Hinweis"
refute "$BASE/run.log" "Erstelle LXC-Container" "kein Container wird erstellt"

echo "Szenario 3: Ubuntu-Templates defekt, Debian 12 vorhanden"
setup s3
make_template ubuntu-24.04-standard_24.04-2_amd64.tar.zst no
make_template ubuntu-22.04-standard_22.04-1_amd64.tar.zst no
make_template debian-12-standard_12.7-1_amd64.tar.zst yes
run_helper
expect "$BASE/run.log" "debian-12-standard_12.7-1_amd64.tar.zst" "Debian-Fallback funktioniert"

echo "Szenario 4: pct create scheitert beim ersten Template"
setup s4
make_template ubuntu-24.04-standard_24.04-2_amd64.tar.zst yes
make_template ubuntu-22.04-standard_22.04-1_amd64.tar.zst yes
export FAKE_FAIL_TEMPLATE="ubuntu-24.04-standard"
run_helper
unset FAKE_FAIL_TEMPLATE
expect "$BASE/run.log" "ubuntu-22.04-standard_22.04-1_amd64.tar.zst" "zweites Template wird verwendet"
expect "$BASE/actions.log" "^destroy" "fehlgeschlagener Container wird aufgeräumt"

echo "Szenario 5: erzeugte Artefakte"
setup s5
make_template ubuntu-24.04-standard_24.04-2_amd64.tar.zst yes
run_helper
expect "$BASE/run.log" "INSTALLATION ERFOLGREICH" "Installation läuft durch"
bash -n "$BASE/pushed/obico_install.sh" && { echo "  ✓ inneres Script ist syntaktisch korrekt"; pass=$((pass + 1)); }
expect "$BASE/pushed/obico-setup.conf" '^CONTAINER_IP=192.168.1.50$' "Container-IP in Config"
expect "$BASE/pushed/obico-setup.conf" '^DJANGO_SECRET_KEY=[0-9a-f]{64}$' "Secret Key wird generiert"
expect "$BASE/pushed/obico-setup.conf" '^SIGNUP_BOOL=False$' "Registrierung standardmäßig aus"
refute "$BASE/root/obico-112-access.txt" "supersecret" "kein Standardpasswort in den Zugangsdaten"
expect "$BASE/root/obico-112-access.txt" "obico-set-site" "IP-Helfer ist dokumentiert"

echo ""
echo "Ergebnis: ${pass} bestanden, ${fail} fehlgeschlagen"
(( fail == 0 ))
