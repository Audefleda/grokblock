#!/bin/bash
# ============================================================================
#  grokblock.sh — Kombinierter Grok-Blocker fuer macOS
#
#  Blockiert:
#    1. Zugriff auf Grok-Dienste (api.x.ai, grok.com, www.grok.com,
#       console.x.ai) via /etc/hosts + pf-Firewall
#    2. Git-Clone des grok-frontend Repos via Git-Wrapper + Watcher-Daemon
#
#  Verwendung:
#    sudo ./grokblock.sh --enable    — Alle Sperren aktivieren
#    sudo ./grokblock.sh --disable   — Alle Sperren aufheben
#    sudo ./grokblock.sh --status    — Status anzeigen
#    sudo ./grokblock.sh --test      — Tests ausfuehren
# ============================================================================

# Kompatible Fehlerbehandlung (zsh + bash)
set -e
set -u
if [ -n "${BASH_VERSION:-}" ]; then
    set -o pipefail
elif [ -n "${ZSH_VERSION:-}" ]; then
    setopt PIPE_FAIL 2>/dev/null || true
fi

# === KONFIGURATION ==========================================================

# Grok-Domains (alle zu blockierenden Hosts)
DOMAINS="api.x.ai grok.com www.grok.com console.x.ai"
HOSTS_FILE="/etc/hosts"
PF_CONF="/etc/pf.conf"
PF_ANCHOR_DIR="/etc/pf.anchors"
PF_ANCHOR_FILE="${PF_ANCHOR_DIR}/block_grok"
ANCHOR_NAME="block_grok"
MARKER_BEGIN="# >>> BLOCK GROK API - BEGIN"
MARKER_END="# >>> BLOCK GROK API - END"
BACKUP_SUFFIX=".bak_grok_$(date +%Y%m%d%H%M%S)"

# Git-Blocker
BLOCKED_REPOS_LIST="
https://github.com/DE0CH/grok-frontend.git
https://github.com/DE0CH/grok-frontend
git@github.com:DE0CH/grok-frontend.git
git@github.com:DE0CH/grok-frontend
"
GIT_WRAPPER="/usr/local/bin/git"
GIT_WATCHER="/usr/local/bin/git-watcher.sh"
LAUNCH_PLIST="/Library/LaunchDaemons/com.gitblock.watcher.plist"
GIT_LOG_FILE="/var/log/git-block.log"
LABEL="com.gitblock.watcher"

# ============================================================================

# Farben
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_info()    { printf "${BLUE}[INFO]${NC} %s\n" "$1"; }
print_success() { printf "${GREEN}[OK]${NC}   %s\n" "$1"; }
print_warn()    { printf "${YELLOW}[WARN]${NC} %s\n" "$1"; }
print_error()   { printf "${RED}[ERR]${NC}  %s\n" "$1"; }

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        print_error "Dieses Skript muss mit sudo ausgefuehrt werden."
        echo "  Verwendung: sudo $0 --enable | --disable | --status | --test"
        exit 1
    fi
}

# === HILFSFUNKTIONEN: Grok-API ==============================================

resolve_ips() {
    local domain="${1:-}"
    local ips=""
    if command -v dig &>/dev/null; then
        ips=$(dig +short "$domain" @8.8.8.8 2>/dev/null | grep -E '^[0-9]+\.' || true)
    fi
    if [ -z "$ips" ] && command -v nslookup &>/dev/null; then
        ips=$(nslookup "$domain" 8.8.8.8 2>/dev/null \
            | awk '/^Address: / {print $2}' \
            | grep -E '^[0-9]+\.' || true)
    fi
    if [ -z "$ips" ] && command -v host &>/dev/null; then
        ips=$(host "$domain" 8.8.8.8 2>/dev/null \
            | awk '/has address/ {print $4}' || true)
    fi
    echo "$ips"
}

flush_dns() {
    print_info "DNS-Cache leeren..."
    dscacheutil -flushcache 2>/dev/null || true
    killall -HUP mDNSResponder 2>/dev/null || true
}

# === HILFSFUNKTIONEN: Git-Blocker ============================================

get_unique_patterns() {
    SEEN_PATTERNS=""
    echo "$BLOCKED_REPOS_LIST" | while IFS= read -r repo; do
        [ -z "$repo" ] && continue
        pattern=$(echo "$repo" | sed -E 's#.*(github\.com[:/])##; s#\.git$##')
        case "$SEEN_PATTERNS" in
            *"|${pattern}|"*) ;;
            *)
                SEEN_PATTERNS="${SEEN_PATTERNS}|${pattern}|"
                echo "$pattern"
                ;;
        esac
    done
}

# === ENABLE ==================================================================

enable_grok_api_block() {
    echo ""
    echo "━━━ Grok-Domains-Sperre aktivieren ━━━"
    echo ""

    # --- /etc/hosts ---
    print_info "/etc/hosts bearbeiten..."
    if grep -q "$MARKER_BEGIN" "$HOSTS_FILE"; then
        print_warn "Eintraege in /etc/hosts bereits vorhanden. Ueberspringe."
    else
        cp "$HOSTS_FILE" "${HOSTS_FILE}${BACKUP_SUFFIX}"
        print_info "Backup erstellt: ${HOSTS_FILE}${BACKUP_SUFFIX}"
        {
            echo ""
            echo "${MARKER_BEGIN}"
            for domain in $DOMAINS; do
                echo "127.0.0.1   ${domain}"
                echo "0.0.0.0     ${domain}"
            done
            echo "${MARKER_END}"
        } >> "$HOSTS_FILE"
        print_success "/etc/hosts: Eintraege fuer alle Grok-Domains hinzugefuegt."
    fi

    flush_dns

    # --- pf-Firewall ---
    print_info "pf-Firewall konfigurieren..."
    mkdir -p "$PF_ANCHOR_DIR"

    {
        echo "# pf-Regeln zum Blockieren von Grok-Diensten"
        echo "# Erstellt am: $(date)"
        echo ""
    } > "$PF_ANCHOR_FILE"

    for domain in $DOMAINS; do
        local domain_ips
        domain_ips=$(resolve_ips "$domain")
        if [ -z "$domain_ips" ]; then
            print_warn "Konnte keine IP-Adressen fuer ${domain} aufloesen."
            echo "block drop out quick proto tcp to ${domain} port {80, 443}" >> "$PF_ANCHOR_FILE"
        else
            print_info "Aufgeloeste IPs fuer ${domain}:"
            echo "$domain_ips" | while read -r ip; do
                echo "  -> $ip"
                echo "block drop out quick proto tcp to ${ip} port {80, 443}" >> "$PF_ANCHOR_FILE"
            done
        fi
    done

    print_info "Anchor-Datei erstellt: ${PF_ANCHOR_FILE}"

    if grep -q "anchor \"${ANCHOR_NAME}\"" "$PF_CONF"; then
        print_warn "Anchor bereits in ${PF_CONF} registriert. Ueberspringe."
    else
        cp "$PF_CONF" "${PF_CONF}${BACKUP_SUFFIX}"
        print_info "Backup erstellt: ${PF_CONF}${BACKUP_SUFFIX}"
        cat >> "$PF_CONF" <<EOF

${MARKER_BEGIN}
anchor "${ANCHOR_NAME}"
load anchor "${ANCHOR_NAME}" from "${PF_ANCHOR_FILE}"
${MARKER_END}
EOF
        print_success "Anchor in ${PF_CONF} registriert."
    fi

    print_info "pf-Firewall laden und aktivieren..."
    if pfctl -nf "$PF_CONF" 2>/dev/null; then
        pfctl -f "$PF_CONF" 2>/dev/null
        pfctl -e 2>/dev/null || true
        print_success "pf-Firewall erfolgreich geladen und aktiviert."
    else
        print_error "Fehler beim Parsen der pf-Konfiguration!"
        print_error "Bitte manuell pruefen: sudo pfctl -nf ${PF_CONF}"
        exit 1
    fi

    print_success "Grok-Domains-Sperre ist AKTIV."
}

enable_git_block() {
    echo ""
    echo "━━━ Git-Repository-Sperre aktivieren ━━━"
    echo ""

    # --- /usr/local/bin sicherstellen ---
    if [ ! -d /usr/local/bin ]; then
        print_info "Erstelle /usr/local/bin ..."
        mkdir -p /usr/local/bin
    fi

    # --- Prüfe ob bereits ein Git-Wrapper existiert ---
    if [ -f "$GIT_WRAPPER" ] && [ ! -L "$GIT_WRAPPER" ]; then
        if ! grep -q "Git Repository Blocker" "$GIT_WRAPPER" 2>/dev/null; then
            print_warn "Es existiert bereits eine Datei unter $GIT_WRAPPER"
            printf "     Ueberschreiben? (j/N) "
            read -r REPLY
            case "$REPLY" in
                [jJ]) ;;
                *)
                    print_error "Git-Blocker-Installation abgebrochen."
                    return 1
                    ;;
            esac
        fi
    fi

    # --- Git-Wrapper ---
    print_info "Installiere Git-Wrapper -> $GIT_WRAPPER"

    cat > "$GIT_WRAPPER" << 'WRAPPER_HEADER'
#!/bin/bash
# === Git Repository Blocker — Wrapper ===
# Automatisch installiert — nicht manuell bearbeiten.

BLOCKED_REPOS="
WRAPPER_HEADER

    echo "$BLOCKED_REPOS_LIST" | while IFS= read -r repo; do
        [ -z "$repo" ] && continue
        echo "$repo" >> "$GIT_WRAPPER"
    done

    cat >> "$GIT_WRAPPER" << 'WRAPPER_BODY'
"

echo "$BLOCKED_REPOS" | while IFS= read -r blocked; do
    [ -z "$blocked" ] && continue
    for arg in "$@"; do
        arg_lower=$(echo "$arg" | tr '[:upper:]' '[:lower:]')
        blocked_lower=$(echo "$blocked" | tr '[:upper:]' '[:lower:]')
        if [ "$arg_lower" = "$blocked_lower" ]; then
            echo "BLOCKIERT: Das Klonen von '${arg}' ist auf diesem System nicht erlaubt."
            logger -t "git-blocker" "Clone blockiert: ${arg}"
            kill -PIPE $$
            exit 1
        fi
    done
done

/usr/bin/git "$@"
WRAPPER_BODY

    chmod +x "$GIT_WRAPPER"
    print_success "Git-Wrapper installiert."

    # --- Git-Watcher ---
    print_info "Installiere Git-Watcher -> $GIT_WATCHER"

    cat > "$GIT_WATCHER" << 'WATCHER_HEADER'
#!/bin/bash
# === Git Repository Blocker — Watcher Daemon ===
# Automatisch installiert — nicht manuell bearbeiten.

BLOCKED_PATTERNS="
WATCHER_HEADER

    get_unique_patterns >> "$GIT_WATCHER"

    cat >> "$GIT_WATCHER" << 'WATCHER_BODY'
"

LOG_FILE="/var/log/git-block.log"

while true; do
    echo "$BLOCKED_PATTERNS" | while IFS= read -r pattern; do
        [ -z "$pattern" ] && continue
        PIDS=$(pgrep -f "git.*${pattern}" 2>/dev/null || true)
        if [ -n "$PIDS" ]; then
            for pid in $PIDS; do
                if [ "$pid" != "$$" ] && [ "$pid" != "$PPID" ]; then
                    echo "$(date '+%Y-%m-%d %H:%M:%S'): Blockierter Clone-Versuch (${pattern}) — PID: ${pid}" >> "$LOG_FILE"
                    kill "$pid" 2>/dev/null || true
                fi
            done
        fi
    done
    sleep 1
done
WATCHER_BODY

    chmod +x "$GIT_WATCHER"
    print_success "Git-Watcher installiert."

    # --- LaunchDaemon ---
    print_info "Installiere LaunchDaemon -> $LAUNCH_PLIST"

    if launchctl list "$LABEL" >/dev/null 2>&1; then
        print_warn "Dienst war bereits geladen — wird neu geladen."
        launchctl unload "$LAUNCH_PLIST" 2>/dev/null || true
    fi

    cat > "$LAUNCH_PLIST" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${GIT_WATCHER}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/var/log/git-watcher-stdout.log</string>
    <key>StandardErrorPath</key>
    <string>/var/log/git-watcher-stderr.log</string>
</dict>
</plist>
EOF

    if plutil -lint "$LAUNCH_PLIST" >/dev/null 2>&1; then
        print_success "LaunchDaemon plist ist valide."
    else
        print_error "LaunchDaemon plist ist fehlerhaft!"
        plutil -lint "$LAUNCH_PLIST"
        exit 1
    fi

    launchctl load "$LAUNCH_PLIST"
    sleep 1

    if launchctl list "$LABEL" >/dev/null 2>&1; then
        print_success "LaunchDaemon gestartet."
    else
        print_error "LaunchDaemon konnte nicht gestartet werden."
        exit 1
    fi

    print_success "Git-Repository-Sperre ist AKTIV."
}

# === DISABLE =================================================================

disable_grok_api_block() {
    echo ""
    echo "━━━ Grok-Domains-Sperre deaktivieren ━━━"
    echo ""

    # --- /etc/hosts ---
    print_info "/etc/hosts bereinigen..."
    if grep -q "$MARKER_BEGIN" "$HOSTS_FILE"; then
        cp "$HOSTS_FILE" "${HOSTS_FILE}${BACKUP_SUFFIX}"
        sed -i '' "/${MARKER_BEGIN}/,/${MARKER_END}/d" "$HOSTS_FILE"
        sed -i '' -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$HOSTS_FILE"
        print_success "Eintraege aus /etc/hosts entfernt."
    else
        print_warn "Keine Grok-Eintraege in /etc/hosts gefunden."
    fi

    flush_dns

    # --- pf-Firewall ---
    print_info "pf-Firewall bereinigen..."
    if grep -q "$MARKER_BEGIN" "$PF_CONF"; then
        cp "$PF_CONF" "${PF_CONF}${BACKUP_SUFFIX}"
        sed -i '' "/${MARKER_BEGIN}/,/${MARKER_END}/d" "$PF_CONF"
        sed -i '' -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$PF_CONF"
        print_success "Anchor aus ${PF_CONF} entfernt."
    else
        print_warn "Kein Anchor in ${PF_CONF} gefunden."
    fi

    if [ -f "$PF_ANCHOR_FILE" ]; then
        rm -f "$PF_ANCHOR_FILE"
        print_success "Anchor-Datei geloescht: ${PF_ANCHOR_FILE}"
    fi

    print_info "pf-Firewall neu laden..."
    pfctl -f "$PF_CONF" 2>/dev/null || true

    print_success "Grok-Domains-Sperre ist DEAKTIVIERT."
}

disable_git_block() {
    echo ""
    echo "━━━ Git-Repository-Sperre deaktivieren ━━━"
    echo ""

    # LaunchDaemon stoppen
    if launchctl list "$LABEL" >/dev/null 2>&1; then
        print_info "Stoppe LaunchDaemon ..."
        launchctl unload "$LAUNCH_PLIST" 2>/dev/null || true
        print_success "LaunchDaemon gestoppt."
    else
        print_warn "LaunchDaemon war nicht geladen."
    fi

    # Dateien entfernen
    for file in "$GIT_WRAPPER" "$GIT_WATCHER" "$LAUNCH_PLIST"; do
        if [ -f "$file" ]; then
            print_info "Loesche $file"
            rm -f "$file"
            print_success "Geloescht: $file"
        else
            print_warn "Nicht gefunden: $file"
        fi
    done

    # Logs behalten?
    if [ -f "$GIT_LOG_FILE" ]; then
        printf "  Log-Dateien ebenfalls loeschen? (j/N) "
        read -r REPLY
        case "$REPLY" in
            [jJ])
                rm -f "$GIT_LOG_FILE" /var/log/git-watcher-stdout.log /var/log/git-watcher-stderr.log
                print_success "Log-Dateien geloescht."
                ;;
            *)
                print_info "Log-Dateien beibehalten."
                ;;
        esac
    fi

    print_success "Git-Repository-Sperre ist DEAKTIVIERT."
}

# === STATUS ==================================================================

do_status() {
    echo ""
    echo "======================================================="
    echo "  grokblock — Status"
    echo "======================================================="

    # --- Grok-Domains ---
    echo ""
    echo "--- Grok-Domains-Sperre ---"
    echo ""

    if grep -q "$MARKER_BEGIN" "$HOSTS_FILE"; then
        print_success "/etc/hosts: BLOCKIERT"
    else
        print_error "/etc/hosts: NICHT BLOCKIERT"
    fi

    if grep -q "anchor \"${ANCHOR_NAME}\"" "$PF_CONF" 2>/dev/null; then
        print_success "pf-Anchor in pf.conf: VORHANDEN"
    else
        print_error "pf-Anchor in pf.conf: NICHT VORHANDEN"
    fi

    if [ -f "$PF_ANCHOR_FILE" ]; then
        print_success "Anchor-Datei: VORHANDEN"
        grep "^block" "$PF_ANCHOR_FILE" 2>/dev/null | sed 's/^/    /'
    else
        print_error "Anchor-Datei: NICHT VORHANDEN"
    fi

    local pf_status
    pf_status=$(pfctl -s info 2>/dev/null | head -1 || echo "Unbekannt")
    echo "  pf-Status: ${pf_status}"

    echo ""
    echo "  Verbindungstests:"
    for domain in $DOMAINS; do
        printf "    curl https://%-22s " "${domain}:"
        if curl -s --connect-timeout 3 "https://${domain}" &>/dev/null; then
            printf "${RED}ERREICHBAR (Sperre nicht wirksam!)${NC}\n"
        else
            printf "${GREEN}NICHT ERREICHBAR (Sperre wirksam)${NC}\n"
        fi
    done

    # --- Git-Blocker ---
    echo ""
    echo "--- Git-Repository-Sperre ---"
    echo ""

    if [ -f "$GIT_WRAPPER" ] && [ -x "$GIT_WRAPPER" ] && grep -q "Git Repository Blocker" "$GIT_WRAPPER" 2>/dev/null; then
        print_success "Git-Wrapper: installiert ($GIT_WRAPPER)"
    else
        print_error "Git-Wrapper: NICHT installiert"
    fi

    if [ -f "$GIT_WATCHER" ] && [ -x "$GIT_WATCHER" ]; then
        print_success "Git-Watcher: installiert ($GIT_WATCHER)"
    else
        print_error "Git-Watcher: NICHT installiert"
    fi

    if [ -f "$LAUNCH_PLIST" ]; then
        print_success "LaunchDaemon: plist vorhanden"
    else
        print_error "LaunchDaemon: plist NICHT vorhanden"
    fi

    if launchctl list "$LABEL" >/dev/null 2>&1; then
        print_success "Watcher-Dienst: LAEUFT"
    else
        print_error "Watcher-Dienst: NICHT aktiv"
    fi

    if [ -f "$GIT_LOG_FILE" ]; then
        ENTRIES=$(wc -l < "$GIT_LOG_FILE" | tr -d ' ')
        print_info "Git-Block-Log: $ENTRIES blockierte Versuche"
        if [ "$ENTRIES" -gt 0 ]; then
            echo "  Letzte 5 Eintraege:"
            tail -5 "$GIT_LOG_FILE" | sed 's/^/    /'
        fi
    fi

    echo ""
}

# === TEST ====================================================================

do_test() {
    echo ""
    echo "======================================================="
    echo "  grokblock — Tests"
    echo "======================================================="
    echo ""

    PASS=0
    FAIL=0

    # --- Grok-Domains-Tests ---
    echo "--- Grok-Domains ---"
    echo ""
    for domain in $DOMAINS; do
        print_info "Verbindungstest zu https://${domain} ..."
        if curl -s --connect-timeout 3 "https://${domain}" &>/dev/null; then
            print_error "${domain} ERREICHBAR — Sperre nicht wirksam!"
            FAIL=$((FAIL + 1))
        else
            print_success "${domain} NICHT ERREICHBAR — Sperre wirksam."
            PASS=$((PASS + 1))
        fi
    done

    echo ""

    # --- Git-Blocker-Tests ---
    echo "--- Git-Repository-Sperre ---"
    echo ""

    print_info "NEGATIV-TEST: Blockiertes Repo klonen ..."
    echo "  -> git clone https://github.com/DE0CH/grok-frontend.git /tmp/test-gitblock-neg"
    if git clone https://github.com/DE0CH/grok-frontend.git /tmp/test-gitblock-neg 2>&1; then
        print_error "NEGATIV-TEST FEHLGESCHLAGEN — Repo wurde NICHT blockiert!"
        rm -rf /tmp/test-gitblock-neg
        FAIL=$((FAIL + 1))
    else
        print_success "NEGATIV-TEST BESTANDEN — Repo wurde blockiert!"
        PASS=$((PASS + 1))
    fi

    echo ""

    print_info "POSITIV-TEST: Erlaubtes Repo klonen ..."
    echo "  -> git clone https://github.com/octocat/Hello-World.git /tmp/test-gitblock-pos"
    if git clone https://github.com/octocat/Hello-World.git /tmp/test-gitblock-pos 2>&1; then
        print_success "POSITIV-TEST BESTANDEN — Erlaubtes Repo funktioniert!"
        PASS=$((PASS + 1))
    else
        print_error "POSITIV-TEST FEHLGESCHLAGEN — Erlaubtes Repo wurde blockiert!"
        FAIL=$((FAIL + 1))
    fi

    rm -rf /tmp/test-gitblock-neg /tmp/test-gitblock-pos

    # Ergebnis
    TOTAL=$((PASS + FAIL))
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if [ "$FAIL" -eq 0 ]; then
        print_success "Alle Tests bestanden! ($PASS/$TOTAL)"
    else
        print_error "$FAIL von $TOTAL Tests fehlgeschlagen!"
    fi
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

# === HAUPTPROGRAMM ===========================================================

usage() {
    echo ""
    echo "Verwendung: sudo $0 [OPTION]"
    echo ""
    echo "Optionen:"
    echo "  --enable    Alle Sperren aktivieren (Grok-Domains + Git-Clone)"
    echo "  --disable   Alle Sperren aufheben"
    echo "  --status    Aktuellen Status anzeigen"
    echo "  --test      Tests ausfuehren"
    echo ""
}

check_root

case "${1:-}" in
    --enable)
        echo ""
        echo "======================================================="
        echo "  grokblock — Alle Sperren aktivieren"
        echo "======================================================="
        enable_grok_api_block
        enable_git_block
        echo ""
        echo "======================================================="
        print_success "Alle Sperren sind AKTIV."
        echo "======================================================="
        echo ""
        echo "  Installierte Komponenten:"
        echo "    Grok-Domains: /etc/hosts + pf-Firewall"
        echo "    Git-Block:    $GIT_WRAPPER, $GIT_WATCHER, $LAUNCH_PLIST"
        echo ""
        echo "  Naechster Schritt:"
        echo "    sudo $0 --test"
        echo ""
        ;;
    --disable)
        echo ""
        echo "======================================================="
        echo "  grokblock — Alle Sperren deaktivieren"
        echo "======================================================="
        disable_grok_api_block
        disable_git_block
        echo ""
        echo "======================================================="
        print_success "Alle Sperren sind DEAKTIVIERT."
        echo "======================================================="
        echo ""
        ;;
    --status)
        do_status
        ;;
    --test)
        do_test
        ;;
    *)
        usage
        exit 1
        ;;
esac

exit 0
