#!/usr/bin/env bash
# =============================================================================
# Ghostwire Minion — Installer
#
# Supports: Alpine (OpenRC), Debian/Ubuntu, RHEL/Fedora, Arch (systemd)
#
# Quick install (interactive):
#   curl -fsSL https://raw.githubusercontent.com/garethcheyne/ghostwire-minion/main/install.sh | sudo bash
#
# Non-interactive:
#   curl -fsSL ... | sudo bash -s -- --parent https://ghostwire.err403.com --key gw-node-xxxx
#   sudo ./install.sh --parent https://ghostwire.err403.com --key gw-node-xxxx [--port 1080]
# =============================================================================

# ---------------------------------------------------------------------------
# Parse CLI arguments
# ---------------------------------------------------------------------------

ARG_PARENT=""
ARG_KEY=""
ARG_PORT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --parent|-p)  ARG_PARENT="$2"; shift 2 ;;
        --key|-k)     ARG_KEY="$2";    shift 2 ;;
        --port)       ARG_PORT="$2";   shift 2 ;;
        --help|-h)
            echo "Usage: install.sh [--parent URL] [--key API_KEY] [--port PORT]"
            echo ""
            echo "Options:"
            echo "  --parent, -p   Ghostwire server URL (e.g. https://ghostwire.err403.com)"
            echo "  --key, -k      Minion API key (starts with gw-node-)"
            echo "  --port         Proxy listen port (default: 1080)"
            echo "  --help, -h     Show this help"
            echo ""
            echo "If --parent and --key are provided, runs non-interactively."
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

INSTALL_DIR="/opt/ghostwire-minion"
SERVICE_NAME="ghostwire-minion"
REPO_URL="https://github.com/garethcheyne/ghostwire-minion.git"

RED='\033[0;31m'   GREEN='\033[0;32m'
CYAN='\033[0;36m'  YELLOW='\033[1;33m'  NC='\033[0m'

info()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; exit 1; }
ask()   { echo -ne "${CYAN}[?]${NC} $1"; }

banner() {
    echo -e "${CYAN}"
    echo "  ╔══════════════════════════════════════════╗"
    echo "  ║        Ghostwire Minion Installer        ║"
    echo "  ║          v2026.04.05.1200                ║"
    echo "  ╚══════════════════════════════════════════╝"
    echo -e "${NC}"
}

# ---------------------------------------------------------------------------
# Detect init system and package manager
# ---------------------------------------------------------------------------

INIT_SYSTEM=""
PKG_MANAGER=""

detect_system() {
    # Detect package manager
    if   command -v apk     &>/dev/null; then PKG_MANAGER="apk"
    elif command -v apt-get &>/dev/null; then PKG_MANAGER="apt"
    elif command -v dnf     &>/dev/null; then PKG_MANAGER="dnf"
    elif command -v yum     &>/dev/null; then PKG_MANAGER="yum"
    elif command -v pacman  &>/dev/null; then PKG_MANAGER="pacman"
    else error "No supported package manager found (apk, apt, dnf, yum, pacman)"; fi

    # Detect init system
    if command -v systemctl &>/dev/null && systemctl --version &>/dev/null 2>&1; then
        INIT_SYSTEM="systemd"
    elif command -v rc-service &>/dev/null; then
        INIT_SYSTEM="openrc"
    else
        error "No supported init system found (systemd or OpenRC)"
    fi

    info "Detected: $PKG_MANAGER + $INIT_SYSTEM"
}

# ---------------------------------------------------------------------------
# Package install helper
# ---------------------------------------------------------------------------

pkg_install() {
    local pkgs=("$@")
    case "$PKG_MANAGER" in
        apk)    apk add --quiet "${pkgs[@]}" ;;
        apt)    apt-get install -y -qq "${pkgs[@]}" ;;
        dnf)    dnf install -y -q "${pkgs[@]}" ;;
        yum)    yum install -y -q "${pkgs[@]}" ;;
        pacman) pacman -Sy --noconfirm "${pkgs[@]}" ;;
    esac
}

pkg_update() {
    case "$PKG_MANAGER" in
        apk) apk update --quiet ;;
        apt) apt-get update -qq ;;
        *)   ;; # dnf/yum/pacman update index on install
    esac
}

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------

check_root() {
    [[ $EUID -eq 0 ]] || error "Run as root: sudo ./install.sh"
}

check_python() {
    if command -v python3 &>/dev/null; then
        if python3 -c "import sys; exit(0 if sys.version_info >= (3, 10) else 1)" 2>/dev/null; then
            info "Python $(python3 --version 2>&1 | awk '{print $2}') found"
            return
        fi
    fi
    warn "Python >= 3.10 not found — installing..."
    pkg_update
    case "$PKG_MANAGER" in
        apk)    pkg_install python3 py3-pip ;;
        apt)    pkg_install python3 python3-venv python3-pip ;;
        dnf)    pkg_install python3 python3-pip ;;
        yum)    pkg_install python3 python3-pip ;;
        pacman) pkg_install python python-pip ;;
    esac
    command -v python3 &>/dev/null || error "Failed to install Python — install Python >= 3.10 manually"
    info "Python installed"
}

ensure_cmd() {
    command -v "$1" &>/dev/null && return
    warn "$1 not found — installing..."
    pkg_update
    # Map command names to package names per distro
    local pkg="$1"
    case "$PKG_MANAGER" in
        apk)
            # Alpine package names sometimes differ
            case "$1" in
                git)  pkg="git" ;;
                curl) pkg="curl" ;;
            esac
            ;;
        pacman)
            case "$1" in
                git)  pkg="git" ;;
                curl) pkg="curl" ;;
            esac
            ;;
    esac
    pkg_install "$pkg"
    command -v "$1" &>/dev/null || error "Failed to install $1"
}

# ---------------------------------------------------------------------------
# Upgrade detection
# ---------------------------------------------------------------------------

UPGRADE=false

detect_existing() {
    if [[ -f "$INSTALL_DIR/config.json" ]] && [[ -f "$INSTALL_DIR/minion.py" ]]; then
        UPGRADE=true
        info "Existing installation detected — upgrading code only"
        info "Config preserved: $INSTALL_DIR/config.json"
    fi
}

# ---------------------------------------------------------------------------
# Setup questions
# ---------------------------------------------------------------------------

configure() {
    if [[ "$UPGRADE" == true ]]; then
        PROXY_PORT=$(python3 -c "import json; print(json.load(open('$INSTALL_DIR/config.json')).get('proxy_port', 1080))" 2>/dev/null || echo 1080)
        return
    fi

    # Non-interactive mode: use CLI args
    if [[ -n "$ARG_PARENT" && -n "$ARG_KEY" ]]; then
        SERVER_URL="${ARG_PARENT%/}"
        API_KEY="$ARG_KEY"
        PROXY_PORT="${ARG_PORT:-1080}"

        [[ "$SERVER_URL" =~ ^https?:// ]] || error "URL must start with http:// or https://"
        [[ "$API_KEY" =~ ^gw-node- ]] || error "Key must start with 'gw-node-' — get it from Ghostwire → Worker Nodes"

        info "Non-interactive mode"
        info "Parent:  $SERVER_URL"
        info "API key: ${API_KEY:0:20}..."
        info "Port:    $PROXY_PORT"
        return
    fi

    # Interactive mode
    echo ""
    echo -e "${CYAN}── Setup ──────────────────────────────────────────${NC}"
    echo ""

    ask "Who is your parent? (Ghostwire server URL): "
    read -r SERVER_URL
    SERVER_URL="${SERVER_URL%/}"
    [[ -z "$SERVER_URL" ]] && error "Server URL is required"
    [[ "$SERVER_URL" =~ ^https?:// ]] || error "URL must start with http:// or https://"

    echo ""
    ask "API key for this minion: "
    read -r API_KEY
    [[ -z "$API_KEY" ]] && error "API key is required"
    [[ "$API_KEY" =~ ^gw-node- ]] || error "Key must start with 'gw-node-' — get it from Ghostwire → Worker Nodes"

    echo ""
    ask "Proxy listen port [1080]: "
    read -r PROXY_PORT
    PROXY_PORT="${PROXY_PORT:-1080}"

    echo ""
    info "Configuration:"
    echo "    Parent:     $SERVER_URL"
    echo "    API key:    ${API_KEY:0:20}..."
    echo "    Port:       $PROXY_PORT"
    echo ""

    ask "Correct? [Y/n] "
    read -r OK
    if [[ "$OK" =~ ^[Nn] ]]; then
        error "Cancelled"
    fi
}

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------

install_files() {
    info "Installing to $INSTALL_DIR ..."
    mkdir -p "$INSTALL_DIR"

    # Stop service before overwriting files (if upgrading)
    if [[ "$UPGRADE" == true ]]; then
        info "Stopping service for upgrade..."
        if [[ "$INIT_SYSTEM" == "systemd" ]]; then
            systemctl stop "$SERVICE_NAME" 2>/dev/null || true
        elif [[ "$INIT_SYSTEM" == "openrc" ]]; then
            rc-service "$SERVICE_NAME" stop 2>/dev/null || true
        fi
    fi

    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    if [[ -f "$SCRIPT_DIR/minion.py" ]]; then
        cp "$SCRIPT_DIR/minion.py"        "$INSTALL_DIR/"
        cp "$SCRIPT_DIR/requirements.txt" "$INSTALL_DIR/"
    else
        # Clean up any stale clone from previous run
        rm -rf /tmp/gw-minion-tmp
        ensure_cmd git
        git clone --depth 1 "$REPO_URL" /tmp/gw-minion-tmp
        cp /tmp/gw-minion-tmp/minion.py        "$INSTALL_DIR/"
        cp /tmp/gw-minion-tmp/requirements.txt "$INSTALL_DIR/"
        rm -rf /tmp/gw-minion-tmp
    fi

    # Flush old bytecode cache so Python picks up the new code
    find "$INSTALL_DIR" -name "*.pyc" -delete 2>/dev/null || true
    find "$INSTALL_DIR" -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true

    info "Installed minion.py version: $(grep '^VERSION' "$INSTALL_DIR/minion.py" | head -1)"

    info "Creating venv..."
    # Ensure the venv module is available (may need version-specific package on Debian/Ubuntu)
    if ! python3 -c "import venv" 2>/dev/null && [[ "$PKG_MANAGER" == "apt" ]]; then
        PY_VER=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
        warn "python3-venv not available — installing python${PY_VER}-venv..."
        pkg_update
        pkg_install "python${PY_VER}-venv" || pkg_install python3-venv || true
    fi

    # On upgrade, remove old venv and recreate to avoid stale state
    if [[ "$UPGRADE" == true ]] && [[ -d "$INSTALL_DIR/venv" ]]; then
        info "Rebuilding venv for clean upgrade..."
        rm -rf "$INSTALL_DIR/venv"
    fi

    python3 -m venv "$INSTALL_DIR/venv" || {
        # Some minimal distros need ensurepip — try without pip then bootstrap
        warn "venv creation failed — trying without pip..."
        python3 -m venv --without-pip "$INSTALL_DIR/venv"
        curl -fsSL https://bootstrap.pypa.io/get-pip.py | "$INSTALL_DIR/venv/bin/python"
    }
    "$INSTALL_DIR/venv/bin/pip" install --quiet --upgrade pip
    "$INSTALL_DIR/venv/bin/pip" install --quiet -r "$INSTALL_DIR/requirements.txt"

    # Only write config on fresh install
    if [[ "$UPGRADE" != true ]]; then
        cat > "$INSTALL_DIR/config.json" <<EOF
{
    "server_url": "$SERVER_URL",
    "api_key": "$API_KEY",
    "proxy_port": $PROXY_PORT
}
EOF
        chmod 600 "$INSTALL_DIR/config.json"
    fi
    info "Files installed"
}

# ---------------------------------------------------------------------------
# Firewall
# ---------------------------------------------------------------------------

open_firewall() {
    SOCKS_PORT=$((PROXY_PORT + 1))

    if command -v ufw &>/dev/null; then
        if ufw status | grep -q "Status: active"; then
            info "Opening ports $PROXY_PORT and $SOCKS_PORT in UFW..."
            ufw allow "$PROXY_PORT"/tcp comment "Ghostwire Minion" >/dev/null 2>&1
            ufw allow "$SOCKS_PORT"/tcp comment "Ghostwire Minion SOCKS5" >/dev/null 2>&1
            info "UFW: ports $PROXY_PORT/tcp and $SOCKS_PORT/tcp allowed"
        else
            warn "UFW installed but inactive — skipping firewall rule"
        fi
    elif command -v firewall-cmd &>/dev/null; then
        if systemctl is-active --quiet firewalld; then
            info "Opening ports $PROXY_PORT and $SOCKS_PORT in firewalld..."
            firewall-cmd --permanent --add-port="$PROXY_PORT"/tcp >/dev/null 2>&1
            firewall-cmd --permanent --add-port="$SOCKS_PORT"/tcp >/dev/null 2>&1
            firewall-cmd --reload >/dev/null 2>&1
            info "firewalld: ports $PROXY_PORT/tcp and $SOCKS_PORT/tcp allowed"
        else
            warn "firewalld installed but inactive — skipping firewall rule"
        fi
    elif command -v iptables &>/dev/null; then
        info "Adding iptables rules for ports $PROXY_PORT and $SOCKS_PORT..."
        iptables -C INPUT -p tcp --dport "$PROXY_PORT" -j ACCEPT 2>/dev/null \
            || iptables -A INPUT -p tcp --dport "$PROXY_PORT" -j ACCEPT
        iptables -C INPUT -p tcp --dport "$SOCKS_PORT" -j ACCEPT 2>/dev/null \
            || iptables -A INPUT -p tcp --dport "$SOCKS_PORT" -j ACCEPT
        info "iptables: ports $PROXY_PORT/tcp and $SOCKS_PORT/tcp allowed"
    else
        warn "No firewall detected — make sure ports $PROXY_PORT and $SOCKS_PORT are accessible"
    fi
}

# ---------------------------------------------------------------------------
# Service — systemd
# ---------------------------------------------------------------------------

install_service_systemd() {
    info "Creating systemd service..."

    cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=Ghostwire Minion
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/venv/bin/python $INSTALL_DIR/minion.py
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=$INSTALL_DIR
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"
    systemctl start  "$SERVICE_NAME"
    info "systemd service started & enabled on boot"
}

# ---------------------------------------------------------------------------
# Service — OpenRC (Alpine)
# ---------------------------------------------------------------------------

install_service_openrc() {
    info "Creating OpenRC service..."

    cat > "/etc/init.d/${SERVICE_NAME}" <<'INITEOF'
#!/sbin/openrc-run

name="Ghostwire Minion"
description="Ghostwire Minion proxy agent"

INSTALL_DIR="/opt/ghostwire-minion"

command="$INSTALL_DIR/venv/bin/python"
command_args="$INSTALL_DIR/minion.py"
command_background=true
pidfile="/run/${RC_SVCNAME}.pid"
output_log="/var/log/${RC_SVCNAME}.log"
error_log="/var/log/${RC_SVCNAME}.log"
directory="$INSTALL_DIR"

depend() {
    need net
    after firewall
}

start_pre() {
    checkpath --file --owner root:root --mode 0644 "$output_log"
}
INITEOF

    chmod +x "/etc/init.d/${SERVICE_NAME}"
    rc-update add "$SERVICE_NAME" default
    rc-service "$SERVICE_NAME" start
    info "OpenRC service started & enabled on boot"
}

install_service() {
    case "$INIT_SYSTEM" in
        systemd) install_service_systemd ;;
        openrc)  install_service_openrc ;;
    esac
}

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------

verify() {
    echo ""
    sleep 3

    case "$INIT_SYSTEM" in
        systemd)
            if systemctl is-active --quiet "$SERVICE_NAME"; then
                info "Service is running"
            else
                warn "Still starting — check: journalctl -u $SERVICE_NAME -f"
            fi
            ;;
        openrc)
            if rc-service "$SERVICE_NAME" status 2>/dev/null | grep -q "started"; then
                info "Service is running"
            else
                warn "Still starting — check: tail -f /var/log/${SERVICE_NAME}.log"
            fi
            ;;
    esac

    if curl -sf "http://localhost:${PROXY_PORT}/health" >/dev/null 2>&1; then
        info "Health check OK on port $PROXY_PORT"
    else
        warn "Health check not responding yet"
    fi

    echo ""
    echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  Minion installed!${NC}"
    echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
    echo ""

    case "$INIT_SYSTEM" in
        systemd)
            echo "  Status:   sudo systemctl status $SERVICE_NAME"
            echo "  Logs:     sudo journalctl -u $SERVICE_NAME -f"
            echo "  Restart:  sudo systemctl restart $SERVICE_NAME"
            ;;
        openrc)
            echo "  Status:   sudo rc-service $SERVICE_NAME status"
            echo "  Logs:     sudo tail -f /var/log/${SERVICE_NAME}.log"
            echo "  Restart:  sudo rc-service $SERVICE_NAME restart"
            ;;
    esac

    echo "  Config:   sudo cat $INSTALL_DIR/config.json"
    echo ""
    echo "  This minion should now appear in your Ghostwire"
    echo "  dashboard under Worker Nodes."
    echo ""
}

# ---------------------------------------------------------------------------
# Go
# ---------------------------------------------------------------------------

banner
check_root
detect_system
check_python
ensure_cmd curl
detect_existing
configure
install_files
open_firewall
install_service
verify
