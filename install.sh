#!/usr/bin/env bash
# =============================================================================
# Ghostwire Minion — Installer
#
# Quick install:
#   curl -fsSL https://raw.githubusercontent.com/garethcheyne/ghostwire-minion/main/install.sh | sudo bash
# =============================================================================

set -e

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
    echo "  ║              v1.0.0                      ║"
    echo "  ╚══════════════════════════════════════════╝"
    echo -e "${NC}"
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
    if   command -v apt-get &>/dev/null; then apt-get update -qq && apt-get install -y -qq python3 python3-venv python3-pip
    elif command -v dnf     &>/dev/null; then dnf install -y -q python3 python3-pip
    elif command -v yum     &>/dev/null; then yum install -y -q python3 python3-pip
    elif command -v pacman  &>/dev/null; then pacman -Sy --noconfirm python python-pip
    else error "Install Python >= 3.10 manually"; fi
    info "Python installed"
}

ensure_cmd() {
    command -v "$1" &>/dev/null && return
    warn "$1 not found — installing..."
    if   command -v apt-get &>/dev/null; then apt-get install -y -qq "$1"
    elif command -v dnf     &>/dev/null; then dnf install -y -q "$1"
    elif command -v yum     &>/dev/null; then yum install -y -q "$1"
    fi
}

# ---------------------------------------------------------------------------
# Setup questions
# ---------------------------------------------------------------------------

configure() {
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
    [[ "$OK" =~ ^[Nn] ]] && error "Cancelled"
}

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------

install_files() {
    info "Installing to $INSTALL_DIR ..."
    mkdir -p "$INSTALL_DIR"

    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    if [[ -f "$SCRIPT_DIR/minion.py" ]]; then
        cp "$SCRIPT_DIR/minion.py"        "$INSTALL_DIR/"
        cp "$SCRIPT_DIR/requirements.txt" "$INSTALL_DIR/"
    else
        ensure_cmd git
        git clone --depth 1 "$REPO_URL" /tmp/gw-minion-tmp
        cp /tmp/gw-minion-tmp/minion.py        "$INSTALL_DIR/"
        cp /tmp/gw-minion-tmp/requirements.txt "$INSTALL_DIR/"
        rm -rf /tmp/gw-minion-tmp
    fi

    info "Creating venv..."
    python3 -m venv "$INSTALL_DIR/venv"
    "$INSTALL_DIR/venv/bin/pip" install --quiet --upgrade pip
    "$INSTALL_DIR/venv/bin/pip" install --quiet -r "$INSTALL_DIR/requirements.txt"

    cat > "$INSTALL_DIR/config.json" <<EOF
{
    "server_url": "$SERVER_URL",
    "api_key": "$API_KEY",
    "proxy_port": $PROXY_PORT
}
EOF
    chmod 600 "$INSTALL_DIR/config.json"
    info "Files installed"
}

open_firewall() {
    if command -v ufw &>/dev/null; then
        if ufw status | grep -q "Status: active"; then
            info "Opening port $PROXY_PORT in UFW..."
            ufw allow "$PROXY_PORT"/tcp comment "Ghostwire Minion" >/dev/null 2>&1
            info "UFW: port $PROXY_PORT/tcp allowed"
        else
            warn "UFW installed but inactive — skipping firewall rule"
        fi
    elif command -v firewall-cmd &>/dev/null; then
        if systemctl is-active --quiet firewalld; then
            info "Opening port $PROXY_PORT in firewalld..."
            firewall-cmd --permanent --add-port="$PROXY_PORT"/tcp >/dev/null 2>&1
            firewall-cmd --reload >/dev/null 2>&1
            info "firewalld: port $PROXY_PORT/tcp allowed"
        else
            warn "firewalld installed but inactive — skipping firewall rule"
        fi
    elif command -v iptables &>/dev/null; then
        info "Adding iptables rule for port $PROXY_PORT..."
        iptables -C INPUT -p tcp --dport "$PROXY_PORT" -j ACCEPT 2>/dev/null \
            || iptables -A INPUT -p tcp --dport "$PROXY_PORT" -j ACCEPT
        info "iptables: port $PROXY_PORT/tcp allowed"
    else
        warn "No firewall detected — make sure port $PROXY_PORT is accessible"
    fi
}

install_service() {
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
    info "Service started & enabled on boot"
}

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------

verify() {
    echo ""
    sleep 3
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        info "Service is running"
    else
        warn "Still starting — check: journalctl -u $SERVICE_NAME -f"
    fi

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
    echo "  Status:   sudo systemctl status $SERVICE_NAME"
    echo "  Logs:     sudo journalctl -u $SERVICE_NAME -f"
    echo "  Restart:  sudo systemctl restart $SERVICE_NAME"
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
check_python
ensure_cmd curl
configure
install_files
open_firewall
install_service
verify
