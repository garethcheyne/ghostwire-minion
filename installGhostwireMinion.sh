#!/usr/bin/env bash
# Ghostwire Minion: install it on a host, as root. Supports Alpine (OpenRC), Debian/Ubuntu,
# RHEL/Fedora and Arch (systemd).
#
#   curl -fsSL https://raw.githubusercontent.com/garethcheyne/ghostwire-minion/main/installGhostwireMinion.sh | sudo bash
#   curl -fsSL ... | sudo bash -s -- --parent https://ghostwire.example.com --key gw-node-xxxx
#   sudo ./installGhostwireMinion.sh --parent https://ghostwire.example.com --key gw-node-xxxx [--port 1080]
#
#   --parent, -p URL   the Ghostwire server it reports to
#   --key, -k KEY      its API key (gw-node-..., from Worker Nodes on that server)
#   --port PORT        the HTTP API's port (default 1080; SOCKS5 listens on the next one up)
#   --yes              don't ask (implied by --parent with --key)
#   --check            say what an install would do; change nothing
#   --settings-only    write config.json and stop
#
# Every Ghostwire app has one of these at its root, with the same options and steps:
#   1 Pre-flight  2 Settings  3 Build  4 Start  5 Health check  6 Admin account  7 Done
# It copies the code to /opt/ghostwire-minion with its own Python environment, writes config.json
# and starts the ghostwire-minion service. On a host that already has a minion it upgrades the
# code in place and keeps config.json: upgradeGhostwireMinion.sh (installed beside it) runs it that
# way. install.sh only forwards here, for one-liners and older minions that still call it. The log
# of each run goes in /opt/ghostwire-minion/backups/. The "This app" part below is what differs
# between apps; the "Common" part is the same in all. The minion is a system service, not Docker,
# so it overrides most hooks.

set -Eeuo pipefail

# ═══════════════════════════════════════════════════════════════════════════════════════════════
#  This app
# ═══════════════════════════════════════════════════════════════════════════════════════════════

app_settings() {
  APP_NAME="Ghostwire Minion"
  INSTALLER=installGhostwireMinion.sh
  UPGRADER=upgradeGhostwireMinion.sh
  REPO_URL="https://github.com/garethcheyne/ghostwire-minion.git"
  INSTALL_DIR=/opt/ghostwire-minion
  SERVICE=ghostwire-minion
  BACKUP_DIR=$INSTALL_DIR/backups
  UPGRADE_CMD="sudo $INSTALL_DIR/$UPGRADER"
  SETTINGS_FILE=$INSTALL_DIR/config.json
  MIN_FREE_GB=1
  GW_PARENT=${GW_PARENT:-} GW_KEY=${GW_KEY:-} GW_PORT=${GW_PORT:-}
  MODE=new INIT="" PKG="" SRC="" WORK=""
}

app_option() {
  case "$1" in
    -p | --parent | -k | --key | --port)
      [ $# -ge 2 ] && [ -n "$2" ] || fail "$1 needs a value (see --help)."
      case "$1" in
        -p | --parent) GW_PARENT=$2 ;;
        -k | --key) GW_KEY=$2 ;;
        --port) GW_PORT=$2 ;;
      esac
      OPTION_ARGS=2
      # Both given: nothing left to ask, as before.
      if [ -n "$GW_PARENT" ] && [ -n "$GW_KEY" ]; then YES=true; fi
      ;;
  esac
}

# The code comes from beside this script (a clone, or the release the upgrade downloaded), or is
# downloaded in Build when this was piped from curl.
app_bootstrap() {
  if [ -n "$PROJECT_DIR" ] && [ -f "$PROJECT_DIR/minion.py" ]; then SRC=$PROJECT_DIR; fi
  PROJECT_DIR=""
}

pkg_install() {
  case "$PKG" in
    apk) apk add --quiet "$@" ;;
    apt) apt-get install -y -qq "$@" ;;
    dnf) dnf install -y -q "$@" ;;
    yum) yum install -y -q "$@" ;;
    pacman) pacman -Sy --noconfirm "$@" ;;
  esac
}

pkg_update() {
  case "$PKG" in
    apk) apk update --quiet ;;
    apt) apt-get update -qq ;;
    *) ;; # dnf, yum and pacman refresh their index on install
  esac
}

# need COMMAND [PACKAGE]: installs what's missing (--check only says so).
need() {
  command -v "$1" > /dev/null && return 0
  if [ "$CHECK" = true ]; then warn "$1 isn't installed; it would be."; return 0; fi
  info "Installing ${2:-$1}..."
  pkg_update
  pkg_install "${2:-$1}" || true
  command -v "$1" > /dev/null || fail "Couldn't install ${2:-$1}; install it by hand and run this again."
}

python_ok() { python3 -c 'import sys; sys.exit(sys.version_info < (3, 10))' 2> /dev/null; }

# Debian and Ubuntu split venv (and ensurepip) into a package named after the Python version.
python_venv() {
  local version
  python3 -c 'import ensurepip, venv' 2> /dev/null && return 0
  [ "$PKG" = apt ] || return 0
  [ "$CHECK" = true ] && { warn "python3-venv isn't installed; it would be."; return 0; }
  version=$(python3 -c 'import sys; print(f"{sys.version_info[0]}.{sys.version_info[1]}")')
  info "Installing python$version-venv..."
  pkg_update
  pkg_install "python$version-venv" 2> /dev/null || pkg_install python3-venv 2> /dev/null || {
    warn "python$version-venv isn't in the package lists; adding the deadsnakes PPA..."
    pkg_install software-properties-common
    add-apt-repository -y ppa:deadsnakes/ppa > /dev/null 2>&1 || true
    pkg_update
    pkg_install "python$version-venv" || true
  }
}

app_requirements() {
  [ "$(id -u)" = 0 ] || fail "Run this as root (sudo)."
  if command -v apk > /dev/null; then PKG=apk
  elif command -v apt-get > /dev/null; then PKG=apt
  elif command -v dnf > /dev/null; then PKG=dnf
  elif command -v yum > /dev/null; then PKG=yum
  elif command -v pacman > /dev/null; then PKG=pacman
  else fail "No supported package manager here (apk, apt, dnf, yum or pacman)."; fi
  if command -v systemctl > /dev/null && systemctl --version > /dev/null 2>&1; then INIT=systemd
  elif command -v rc-service > /dev/null; then INIT=openrc
  else fail "No systemd or OpenRC here."; fi
  ok "Packages: $PKG. Services: $INIT."
  if ! python_ok && [ "$CHECK" = true ]; then
    warn "Python 3.10 or newer isn't installed; it would be."
  elif ! python_ok; then
    info "Installing Python..."
    pkg_update
    case "$PKG" in
      apk) pkg_install python3 py3-pip ;;
      apt) pkg_install python3 python3-venv python3-pip ;;
      pacman) pkg_install python python-pip ;;
      *) pkg_install python3 python3-pip ;;
    esac
    python_ok || fail "Couldn't install Python 3.10 or newer; install it by hand and run this again."
  fi
  python_ok && ok "Python $(python3 -c 'import platform; print(platform.python_version())')."
  python_venv
  need curl
  [ -n "$SRC" ] || need git
}

# A minion already here is upgraded in place (its config.json kept); upgradeGhostwireMinion.sh
# relies on that. config.json alone is from a run that stopped part way: carry on with it.
app_existing() {
  if [ -f "$INSTALL_DIR/config.json" ] && [ -f "$INSTALL_DIR/minion.py" ]; then
    MODE=upgrade YES=true # nothing to ask: config.json has it all
    ok "A minion is already installed here: this upgrades its code and keeps $INSTALL_DIR/config.json."
  elif [ -f "$INSTALL_DIR/config.json" ]; then
    RESUME=true YES=true
    ok "An earlier run didn't finish; this one carries on with its config.json."
  else
    ok "No minion is installed here yet."
  fi
}

config_value() {
  python3 -c 'import json, sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], sys.argv[3]))' \
    "$INSTALL_DIR/config.json" "$1" "$2" 2> /dev/null || printf '%s' "$2"
}

check_parent() {
  [[ "$1" =~ ^https?://[^[:space:]\"\\]+$ ]] || echo "Give the server's address, starting http:// or https:// (no spaces or quotes)."
}
check_key() { [[ "$1" =~ ^gw-node-[A-Za-z0-9_-]+$ ]] || echo "The key starts gw-node- (Worker Nodes on the server makes one)."; }
check_minion_port() {
  if ! [[ "$1" =~ ^[0-9]{1,5}$ ]] || [ "$((10#$1))" -lt 1 ] || [ "$((10#$1))" -gt 65534 ]; then
    echo "Give a port from 1 to 65534 (SOCKS5 takes the next one up)."
  fi
}

app_questions() {
  if [ "$MODE" = upgrade ] || [ "$RESUME" = true ]; then
    GW_PORT=$(config_value proxy_port 1080)
    return 0
  fi
  ask GW_PARENT "The Ghostwire server it reports to (https://...)" "" check_parent
  GW_PARENT=${GW_PARENT%/}
  if [ -z "$GW_KEY" ] && [ "$YES" = false ] && [ "$CHECK" = false ]; then
    [ -n "$TTY" ] || fail "No terminal to ask on: pass --parent and --key (see --help)."
    read -r -s -p "  Its API key, from Worker Nodes (not shown): " GW_KEY < "$TTY" || GW_KEY=""
    echo
  fi
  ask GW_KEY "Its API key" "" check_key
  ask GW_PORT "Port for its HTTP API (SOCKS5 takes the next one up)" 1080 check_minion_port
  GW_PORT=$((10#$GW_PORT))
}

app_summary() {
  if [ "$MODE" = upgrade ]; then
    summary_line "Upgrade" "$(tr -d '[:space:]' < "$INSTALL_DIR/VERSION" 2> /dev/null || echo unknown) → the code being installed"
    return 0
  fi
  summary_line "Parent" "$GW_PARENT"
  summary_line "API key" "${GW_KEY:0:12}..."
  summary_line "Ports" "$GW_PORT (HTTP API), $((GW_PORT + 1)) (SOCKS5)"
  case "$GW_PARENT" in https://*) ;; *) warn "The parent is plain http: the API key would cross the network unencrypted." ;; esac
}

# config.json, private from the moment it exists; json.dump does the quoting.
app_write() {
  if [ "$CHECK" = true ]; then
    ok "It would write $INSTALL_DIR/config.json (readable only by root)."
    return 0
  fi
  [ "$MODE" = upgrade ] && { ok "Keeping $INSTALL_DIR/config.json."; return 0; }
  mkdir -p "$INSTALL_DIR"
  (
    umask 077
    GW_PARENT="$GW_PARENT" GW_KEY="$GW_KEY" GW_PORT="$GW_PORT" python3 -c '
import json, os, sys
config = {"server_url": os.environ["GW_PARENT"], "api_key": os.environ["GW_KEY"], "proxy_port": int(os.environ["GW_PORT"])}
with open(sys.argv[1], "w") as f:
    json.dump(config, f, indent=4)
    f.write("\n")
' "$INSTALL_DIR/config.json.new"
    mv -f "$INSTALL_DIR/config.json.new" "$INSTALL_DIR/config.json"
  ) || fail "Couldn't write $INSTALL_DIR/config.json."
  ok "Wrote $INSTALL_DIR/config.json (readable only by root)."
}

app_ready() { HEALTH_URLS="http://localhost:$GW_PORT/health"; }

minion_service() {
  case "$INIT" in
    systemd) systemctl "$1" "$SERVICE" ;;
    openrc) rc-service "$SERVICE" "$1" ;;
  esac
}

minion_running() {
  case "$INIT" in
    systemd) systemctl is-active --quiet "$SERVICE" ;;
    openrc) rc-service "$SERVICE" status 2> /dev/null | grep -q started ;;
  esac
}

# put SOURCE DEST MODE: written beside and moved into place, so a script that is running (the
# upgrade script runs this installer) keeps reading the file it started with.
put() {
  mkdir -p "$(dirname "$2")"
  cp "$1" "$2.new"
  chmod "$3" "$2.new"
  mv -f "$2.new" "$2"
}

# Copies the code in and builds its Python environment.
app_build() {
  local name
  if [ -z "$SRC" ]; then
    WORK=$(mktemp -d)
    info "Downloading $REPO_URL..."
    git clone --quiet --depth 1 "$REPO_URL" "$WORK/src" || fail "Couldn't download $REPO_URL."
    SRC=$WORK/src
  fi
  if [ "$MODE" = upgrade ]; then
    info "Stopping the service for the upgrade..."
    minion_service stop 2> /dev/null || true
  fi
  mkdir -p "$INSTALL_DIR"
  for name in minion.py requirements.txt VERSION; do
    [ -f "$SRC/$name" ] && put "$SRC/$name" "$INSTALL_DIR/$name" 644
  done
  # The upgrade script, and scripts/upgrade.sh forwarding to it for anything that calls the old path.
  put "$SRC/$UPGRADER" "$INSTALL_DIR/$UPGRADER" 755
  put "$SRC/scripts/upgrade.sh" "$INSTALL_DIR/scripts/upgrade.sh" 755
  find "$INSTALL_DIR" -name '__pycache__' -type d -prune -exec rm -rf {} + 2> /dev/null || true
  ok "Code: v$(tr -d '[:space:]' < "$INSTALL_DIR/VERSION" 2> /dev/null || echo unknown) in $INSTALL_DIR."

  rm -rf "$INSTALL_DIR/venv"
  if ! python3 -m venv "$INSTALL_DIR/venv" 2> /dev/null; then
    warn "venv couldn't add pip; trying without it..."
    python3 -m venv --without-pip "$INSTALL_DIR/venv" || fail "Couldn't make the Python environment."
    curl -fsSL https://bootstrap.pypa.io/get-pip.py | "$INSTALL_DIR/venv/bin/python" > /dev/null || fail "Couldn't install pip."
  fi
  "$INSTALL_DIR/venv/bin/pip" install --quiet --upgrade pip || warn "Couldn't upgrade pip; carrying on with the one it has."
  "$INSTALL_DIR/venv/bin/pip" install --quiet -r "$INSTALL_DIR/requirements.txt" || fail "Couldn't install the Python packages."
  ok "Python environment: $INSTALL_DIR/venv."
}

open_firewall() {
  local socks=$((GW_PORT + 1))
  if command -v ufw > /dev/null; then
    if ufw status | grep -q "Status: active"; then
      ufw allow "$GW_PORT/tcp" comment "Ghostwire Minion" > /dev/null 2>&1 || true
      ufw allow "$socks/tcp" comment "Ghostwire Minion SOCKS5" > /dev/null 2>&1 || true
      ok "UFW: ports $GW_PORT and $socks are open."
    else
      info "UFW is installed but off; no rule added."
    fi
  elif command -v firewall-cmd > /dev/null; then
    if systemctl is-active --quiet firewalld 2> /dev/null; then
      firewall-cmd --permanent --add-port="$GW_PORT/tcp" > /dev/null 2>&1 || true
      firewall-cmd --permanent --add-port="$socks/tcp" > /dev/null 2>&1 || true
      firewall-cmd --reload > /dev/null 2>&1 || true
      ok "firewalld: ports $GW_PORT and $socks are open."
    else
      info "firewalld is installed but off; no rule added."
    fi
  elif command -v iptables > /dev/null; then
    iptables -C INPUT -p tcp --dport "$GW_PORT" -j ACCEPT 2> /dev/null || iptables -A INPUT -p tcp --dport "$GW_PORT" -j ACCEPT
    iptables -C INPUT -p tcp --dport "$socks" -j ACCEPT 2> /dev/null || iptables -A INPUT -p tcp --dport "$socks" -j ACCEPT
    ok "iptables: ports $GW_PORT and $socks are open."
  else
    warn "No firewall found: make sure ports $GW_PORT and $socks can be reached."
  fi
}

install_systemd() {
  cat > "/etc/systemd/system/$SERVICE.service" << EOF
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
TimeoutStopSec=30
StandardOutput=journal
StandardError=journal
# Sandbox. The minion only needs the network and its own folder; /upgrade and /destroy run their
# work outside this sandbox through systemd-run. Older systemd ignores settings it doesn't know.
UMask=0077
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=$INSTALL_DIR
PrivateTmp=true
PrivateDevices=true
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true
ProtectClock=true
ProtectHostname=true
RestrictSUIDSGID=true
RestrictRealtime=true
RestrictNamespaces=true
LockPersonality=true
SystemCallArchitectures=native
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
CapabilityBoundingSet=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --quiet "$SERVICE"
  systemctl restart "$SERVICE"
}

install_openrc() {
  cat > "/etc/init.d/$SERVICE" << 'EOF'
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
EOF
  chmod +x "/etc/init.d/$SERVICE"
  rc-update add "$SERVICE" default > /dev/null
  rc-service "$SERVICE" restart > /dev/null 2>&1 || rc-service "$SERVICE" start
}

app_start() {
  open_firewall
  case "$INIT" in
    systemd) install_systemd ;;
    openrc) install_openrc ;;
  esac
  ok "The $SERVICE service is started, and starts on boot."
}

# On an upgrade the upgrade script checks health itself (and offers to roll back), so a slow start
# here is only a warning.
app_health() {
  local socks=$((GW_PORT + 1)) i
  for i in $(seq 1 12); do minion_running && break; sleep 5; done
  if minion_running; then ok "The $SERVICE service is running."
  else warn "The $SERVICE service isn't running."; [ "$MODE" = upgrade ] || return 1; fi
  if ! check_urls; then
    info "The minion only listens once its parent accepts it: check the parent's address and the key."
    [ "$MODE" = upgrade ] || return 1
  fi
  for i in $(seq 1 10); do (echo > "/dev/tcp/127.0.0.1/$socks") 2> /dev/null && break; sleep 2; done
  if (echo > "/dev/tcp/127.0.0.1/$socks") 2> /dev/null; then ok "SOCKS5 is listening on $socks."
  else warn "SOCKS5 isn't listening on $socks."; [ "$MODE" = upgrade ] || return 1; fi
}

app_logs() {
  case "$INIT" in
    systemd) journalctl -u "$SERVICE" -n 30 --no-pager 2>&1 | sed 's/^/    /' || true ;;
    openrc) tail -n 30 "/var/log/$SERVICE.log" 2>&1 | sed 's/^/    /' || true ;;
  esac
}

app_admin() { ok "The minion has no accounts: it registers with its parent, under Worker Nodes there."; }

app_finish() { :; }

app_done() {
  case "$INIT" in
    systemd) summary_line "Status" "systemctl status $SERVICE   (logs: journalctl -u $SERVICE -f)" ;;
    openrc) summary_line "Status" "rc-service $SERVICE status   (logs: /var/log/$SERVICE.log)" ;;
  esac
  summary_line "Parent" "$(config_value server_url unknown)"
}

app_cleanup() { [ -z "${WORK:-}" ] || rm -rf "$WORK"; }

# ═══════════════════════════════════════════════════════════════════════════════════════════════
#  Common: the same in every Ghostwire app's installGhostwire<App>.sh. Change it in all of them together.
#  A hook the app section above doesn't define uses the default here.
# ═══════════════════════════════════════════════════════════════════════════════════════════════

if [ -t 1 ]; then
  B=$'\033[1m' G=$'\033[32m' Y=$'\033[33m' R=$'\033[31m' N=$'\033[0m'
else
  B="" G="" Y="" R="" N=""
fi

# ── Output ──────────────────────────────────────────────────────────────────────────────────────
step() { printf '\n%s[%s/%s] %s%s\n' "$B" "$1" "$STEPS" "$2" "$N"; }
info() { printf '  %s\n' "$*"; }
ok()   { printf '  %s✓%s %s\n' "$G" "$N" "$*"; }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$*"; }
fail() { printf '\n  %s✗ %s%s\n' "$R" "$*" "$N" >&2; exit 1; }
summary_line() { printf '  %-12s %s\n' "$1" "$2"; }

# ── Questions ───────────────────────────────────────────────────────────────────────────────────
# Questions are read from the terminal, not stdin, so the script can be piped from curl.

# confirm "question": --yes answers yes; with no terminal to ask on, the run stops.
confirm() {
  local answer=""
  [ "$YES" = true ] && return 0
  [ -n "$TTY" ] || fail "No terminal to ask on. Run with --yes (answers from the GW_* variables)."
  read -r -p "  $1 [Y/n] " answer < "$TTY" || answer=""
  [[ ! "$answer" =~ ^[Nn] ]]
}

# ask VAR "question" [default] [check]: VAR keeps a value it already has (a GW_* variable).
# Otherwise --yes (and --check) take the default, and the terminal is asked. check is a function
# that prints what's wrong with an answer, or nothing.
ask() {
  local var=$1 question=$2 default=${3:-} check=${4:-} answer problem preset=false
  [ -n "${!var:-}" ] && preset=true
  while :; do
    if [ "$preset" = true ]; then
      answer=${!var}
    elif [ "$YES" = true ] || [ "$CHECK" = true ]; then
      answer=$default
    else
      [ -n "$TTY" ] || fail "No terminal to ask on. Set $var, or run with --yes for the defaults."
      if [ -n "$default" ]; then
        read -r -p "  $question [$default]: " answer < "$TTY" || answer=""
      else
        read -r -p "  $question: " answer < "$TTY" || answer=""
      fi
      answer=${answer:-$default}
    fi
    problem=""
    [ -z "$check" ] || problem=$("$check" "$answer")
    if [ -z "$problem" ]; then
      printf -v "$var" '%s' "$answer"
      return 0
    fi
    if [ "$CHECK" = true ] && [ "$preset" = false ]; then
      warn "$var: $problem (it would be asked)"
      printf -v "$var" '%s' "$answer"
      return 0
    fi
    [ "$preset" = false ] && [ "$YES" = false ] || fail "$var: $problem"
    warn "$problem"
  done
}

# ask_password VAR "question": typed twice and never shown; Enter (or --yes) makes a random one,
# which is shown once at the very end.
ask_password() {
  local var=$1 question=$2 first second problem
  if [ -n "${!var:-}" ]; then
    problem=$(check_password "${!var}")
    [ -z "$problem" ] || fail "$var: $problem"
    PASSWORD_SOURCE=given
    return 0
  fi
  if [ "$YES" = true ] || [ "$CHECK" = true ]; then
    GENERATED_PASSWORD=$(random_secret 24)
    printf -v "$var" '%s' "$GENERATED_PASSWORD"
    PASSWORD_SOURCE=random
    return 0
  fi
  [ -n "$TTY" ] || fail "No terminal to ask on. Set $var, or run with --yes for a random one."
  while :; do
    read -r -s -p "  $question (Enter for a random one): " first < "$TTY" || first=""
    echo
    if [ -z "$first" ]; then
      GENERATED_PASSWORD=$(random_secret 24)
      printf -v "$var" '%s' "$GENERATED_PASSWORD"
      PASSWORD_SOURCE=random
      return 0
    fi
    problem=$(check_password "$first")
    if [ -n "$problem" ]; then warn "$problem"; continue; fi
    read -r -s -p "  Type it again: " second < "$TTY" || second=""
    echo
    if [ "$first" = "$second" ]; then
      printf -v "$var" '%s' "$first"
      PASSWORD_SOURCE=typed
      return 0
    fi
    warn "They didn't match; try again."
  done
}

# ── Checks for answers (print the problem, or nothing) ──────────────────────────────────────────
check_required() { [ -n "$1" ] || echo "This can't be empty."; }
check_url() {
  local url
  url=$(as_url "$1")
  [[ "$url" =~ ^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?$ ]] \
    || echo "Give an address like https://app.example.com (or app.example.com)."
}
check_email() {
  [[ "$1" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]] || echo "Give an email address like you@example.com."
}
check_password() {
  if [ ${#1} -lt 12 ]; then echo "The password needs at least 12 characters."
  elif [ ${#1} -gt 128 ]; then echo "The password can have at most 128 characters."
  elif [[ "$1" == *"'"* ]] || [[ "$1" =~ [[:cntrl:]] ]]; then echo "The password can't hold a ' or control characters."
  fi
}
check_port() {
  if ! [[ "$1" =~ ^[0-9]{1,5}$ ]] || [ "$1" -lt 1 ] || [ "$1" -gt 65535 ]; then echo "Give a port number (1-65535)."
  elif [ "$RESUME" = false ] && port_in_use "$1"; then echo "Port $1 is already in use on this server."
  fi
}
check_yes_no() { [[ "$1" =~ ^([Yy](es)?|[Nn]o?)$ ]] || echo "Answer yes or no."; }

# as_url "app.example.com" → https://app.example.com (no trailing slash).
as_url() {
  local url=${1%/}
  case "$url" in http://* | https://* | "") ;; *) url="https://$url" ;; esac
  printf '%s' "$url"
}
url_host() { local host=${1#*://}; host=${host%%/*}; printf '%s' "${host%%:*}"; }
url_origin() { local rest=${1#*://}; printf '%s://%s' "${1%%://*}" "${rest%%/*}"; }
is_yes() { [[ "$1" =~ ^([Yy](es)?|true|1)$ ]]; }

# An address this server can be reached at, for defaults (the first of its own addresses).
server_address() {
  local address
  address=$(hostname -I 2> /dev/null | awk '{ print $1 }') || true
  printf '%s' "${address:-localhost}"
}

# admin@<domain> when the address has a domain, else nothing (so it is asked).
default_admin_email() {
  local host
  host=$(url_host "$1")
  [[ "$host" == *.* ]] && ! [[ "$host" =~ ^[0-9.]+$ ]] && printf 'admin@%s' "$host"
  return 0
}

# ── Settings ────────────────────────────────────────────────────────────────────────────────────
# env_value KEY [default]: one value from .env, without running the file (values may hold $ or #).
env_value() {
  local value=""
  if [ -f "$PROJECT_DIR/.env" ]; then
    value=$(grep -E "^[[:space:]]*(export[[:space:]]+)?$1=" "$PROJECT_DIR/.env" | tail -n1 | cut -d= -f2- \
      | sed -e 's/[[:space:]]*$//' -e "s/^'\(.*\)'\$/\1/" -e 's/^"\(.*\)"$/\1/') || true
  fi
  printf '%s' "${value:-${2:-}}"
}

# random_secret LENGTH: letters and digits only, so it is safe in .env, a URL and SQL as it is.
random_secret() {
  local secret
  secret=$(openssl rand -base64 $(($1 * 2)) 2> /dev/null | tr -dc 'A-Za-z0-9' | head -c "$1") || true
  [ ${#secret} -eq "$1" ] || secret=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$1") || true
  [ ${#secret} -eq "$1" ] || fail "Couldn't make a random secret (no openssl or /dev/urandom)."
  printf '%s' "$secret"
}

# random_hex BYTES: 2 × BYTES hex digits.
random_hex() {
  local hex
  hex=$(openssl rand -hex "$1" 2> /dev/null) || true
  [ ${#hex} -eq $(($1 * 2)) ] || hex=$(LC_ALL=C tr -dc '0-9a-f' < /dev/urandom | head -c $(($1 * 2))) || true
  [ ${#hex} -eq $(($1 * 2)) ] || fail "Couldn't make a random secret (no openssl or /dev/urandom)."
  printf '%s' "$hex"
}

sha256_of() {
  if command -v sha256sum > /dev/null; then printf '%s' "$1" | sha256sum | cut -c1-64
  else printf '%s' "$1" | shasum -a 256 | cut -c1-64; fi
}

# What the app section puts in .env: env_set KEY VALUE, env_secret KEY LENGTH, env_hex KEY BYTES,
# env_drop KEY (comments out a line .env.example has that this install doesn't use).
ENV_KEYS=() ENV_VALUES=() ENV_SECRETS="" ENV_DROPS=" "
env_set() {
  local i
  for i in "${!ENV_KEYS[@]}"; do
    if [ "${ENV_KEYS[$i]}" = "$1" ]; then ENV_VALUES[i]=$2; return 0; fi
  done
  ENV_KEYS+=("$1")
  ENV_VALUES+=("$2")
}
env_secret() { env_set "$1" "$(random_secret "$2")"; ENV_SECRETS="$ENV_SECRETS $1"; }
env_hex() { env_set "$1" "$(random_hex "$2")"; ENV_SECRETS="$ENV_SECRETS $1"; }
env_drop() { ENV_DROPS="$ENV_DROPS$1 "; }

# A value as .env holds it: as it is when that's safe, otherwise in single quotes, which docker
# compose reads literally ($ and # included). A value can't hold a single quote.
env_quote() {
  if [[ "$1" =~ ^[A-Za-z0-9_.,:/@+=-]*$ ]]; then printf '%s' "$1"; else printf "'%s'" "$1"; fi
}

# render_env FILE: .env.example with the values set above; keys it doesn't have go at the end.
# Placeholders .env.example ships with (change-this, your-..., xxxx, example.com) must not survive.
ENV_MARKER_UNFINISHED="(install not finished)"
render_env() {
  local out=$1 line key rest value i done_keys=" " live_keys left="" placeholders=""
  [ -f "$PROJECT_DIR/.env.example" ] || fail ".env.example is missing from $PROJECT_DIR."
  live_keys=" $(grep -oE '^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=' "$PROJECT_DIR/.env.example" \
    | sed -E 's/^[[:space:]]*(export[[:space:]]+)?//; s/=$//' | tr '\n' ' ' || true)"
  {
    printf '# Written by %s on %s %s\n' "$INSTALLER" "$(date '+%Y-%m-%d %H:%M')" "$ENV_MARKER_UNFINISHED"
    printf '# Secrets were made at random. Keep this file private (only its owner can read it) and back it\n'
    printf '# up with the data: the database password has to match the database for as long as it exists.\n\n'
    while IFS= read -r line || [ -n "$line" ]; do
      line=${line%$'\r'}
      key="" rest=""
      if [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
        key=${BASH_REMATCH[2]} rest=${BASH_REMATCH[3]}
        if [[ "$ENV_DROPS" == *" $key "* ]]; then
          printf '# %s\n' "$line"
          continue
        fi
        for i in "${!ENV_KEYS[@]}"; do
          if [ "${ENV_KEYS[$i]}" = "$key" ]; then
            printf '%s=%s\n' "$key" "$(env_quote "${ENV_VALUES[$i]}")"
            done_keys="$done_keys$key "
            continue 2
          fi
        done
        value=${rest%%[[:space:]]#*}
        if [[ "$value" =~ change-this|change_me|changeme|your-|yourdomain|xxxx|generate-a|example\.com ]]; then
          placeholders="$placeholders $key"
        fi
      elif [[ "$line" =~ ^#[[:space:]]?([A-Za-z_][A-Za-z0-9_]*)= ]]; then
        key=${BASH_REMATCH[1]}
        if [[ "$live_keys" != *" $key "* ]] && [[ "$done_keys" != *" $key "* ]]; then
          for i in "${!ENV_KEYS[@]}"; do
            if [ "${ENV_KEYS[$i]}" = "$key" ]; then
              printf '%s=%s\n' "$key" "$(env_quote "${ENV_VALUES[$i]}")"
              done_keys="$done_keys$key "
              continue 2
            fi
          done
        fi
      fi
      printf '%s\n' "$line"
    done < "$PROJECT_DIR/.env.example"
    for i in "${!ENV_KEYS[@]}"; do
      [[ "$done_keys" == *" ${ENV_KEYS[$i]} "* ]] && continue
      [ -n "$left" ] || { left=yes; printf '\n# Set by %s (not in .env.example)\n' "$INSTALLER"; }
      printf '%s=%s\n' "${ENV_KEYS[$i]}" "$(env_quote "${ENV_VALUES[$i]}")"
    done
  } > "$out"
  [ -z "$placeholders" ] || { rm -f "$out"; fail "These would keep a placeholder from .env.example:$placeholders (a bug in $INSTALLER)."; }
}

# Writes .env (mode 600 from the moment it exists), or with --check says what it would hold.
write_env() {
  local tmp
  tmp=$(umask 077 && mktemp "$PROJECT_DIR/.env.XXXXXX") || fail "Can't write in $PROJECT_DIR."
  render_env "$tmp"
  if [ "$CHECK" = true ]; then
    rm -f "$tmp"
    ok "It would write .env from .env.example (readable only by its owner)."
    info "  Random secrets:$ENV_SECRETS"
    info "  From the answers:$(for key in "${ENV_KEYS[@]}"; do [[ " $ENV_SECRETS " == *" $key "* ]] || printf ' %s' "$key"; done)"
    return 0
  fi
  chmod 600 "$tmp"
  mv -f "$tmp" "$PROJECT_DIR/.env"
  ok "Wrote .env (readable only by its owner; random secrets:$ENV_SECRETS)."
}

# The .env this script wrote, from a run that didn't finish (so the same secrets are used again).
unfinished_env() {
  [ -f "$PROJECT_DIR/.env" ] && head -n1 "$PROJECT_DIR/.env" | grep -qF "# Written by $INSTALLER" \
    && head -n1 "$PROJECT_DIR/.env" | grep -qF "$ENV_MARKER_UNFINISHED"
}

# The first line of .env says the install finished; a later run then leaves it alone.
mark_env_installed() {
  local tmp
  [ -f "$PROJECT_DIR/.env" ] || return 0
  tmp=$(mktemp)
  awk -v marker=" $ENV_MARKER_UNFINISHED" -v done_at="; installed $(date '+%Y-%m-%d %H:%M')" \
    'NR == 1 { i = index($0, marker); if (i) $0 = substr($0, 1, i - 1) done_at } { print }' \
    "$PROJECT_DIR/.env" > "$tmp"
  cat "$tmp" > "$PROJECT_DIR/.env"
  rm -f "$tmp"
}

# ── Server ──────────────────────────────────────────────────────────────────────────────────────
# Whether something on this server already listens on a TCP port (or a container publishes it).
port_in_use() {
  if command -v ss > /dev/null && ss -Htln 2> /dev/null | awk '{ print $4 }' | grep -qE "[:.]$1\$"; then return 0; fi
  if docker ps -a --format '{{.Ports}}' 2> /dev/null | grep -qE "[:.]$1->"; then return 0; fi
  (exec 3<> "/dev/tcp/127.0.0.1/$1") 2> /dev/null && return 0
  return 1
}

# The first free port from $1 upwards.
free_port() {
  local port=$1
  while port_in_use "$port"; do port=$((port + 1)); done
  printf '%s' "$port"
}

check_ports() {
  local port busy=""
  [ -n "$1" ] || return 0
  for port in $1; do port_in_use "$port" && busy="$busy $port"; done
  [ -z "$busy" ] || fail "$APP_NAME needs these ports, which are already in use on this server:$busy"
  # shellcheck disable=SC2086
  ok "Ports$(printf ' %s' $1) are free."
}

check_disk() {
  local free_kb
  free_kb=$(df -Pk "${PROJECT_DIR:-/}" 2> /dev/null | awk 'NR == 2 { print $4 }')
  if [ -n "$free_kb" ] && [ "$free_kb" -lt $((MIN_FREE_GB * 1024 * 1024)) ]; then
    fail "Only $((free_kb / 1024 / 1024)) GB free; $APP_NAME needs about ${MIN_FREE_GB} GB (docker system prune can free some)."
  fi
  ok "Disk space is fine (${MIN_FREE_GB} GB needed)."
}

check_memory() {
  local total_kb
  total_kb=$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo 2> /dev/null) || true
  [ -n "$total_kb" ] || return 0
  if [ "$total_kb" -lt $((MIN_MEMORY_GB * 1000 * 1000)) ]; then
    warn "This server has $((total_kb / 1024 / 1024)) GB of memory; $APP_NAME wants at least ${MIN_MEMORY_GB} GB."
  else
    ok "Memory is fine (${MIN_MEMORY_GB} GB wanted)."
  fi
}

# ── Docker ──────────────────────────────────────────────────────────────────────────────────────
# docker compose config, with stand-ins for anything it insists on before .env exists.
compose_config() {
  # shellcheck disable=SC2086
  env $PREFLIGHT_ENV docker compose config 2> /dev/null
}

docker_requirements() {
  local tool
  for tool in git curl openssl; do
    command -v "$tool" > /dev/null || fail "$tool isn't installed."
  done
  command -v docker > /dev/null || fail "Docker isn't installed (https://docs.docker.com/engine/install/)."
  docker compose version > /dev/null 2>&1 || fail "Docker Compose v2 isn't available (docker compose)."
  docker info > /dev/null 2>&1 || fail "Can't talk to Docker (is it running? does this user need sudo, or the docker group?)."
  git -C "$PROJECT_DIR" rev-parse --git-dir > /dev/null 2>&1 \
    || fail "$PROJECT_DIR isn't a git checkout: clone the repository and run $INSTALLER from it."
  compose_config > /dev/null || fail "docker-compose.yml doesn't parse: run docker compose config to see why."
  ok "Docker $(docker version --format '{{.Server.Version}}' 2> /dev/null), Compose $(docker compose version --short 2> /dev/null), git, curl and openssl are here."
}

# Refuses a server that already runs the app: its containers, a container with one of its names,
# or its data volumes. An unfinished run of this script carries on instead.
docker_existing() {
  local config project found="" name ids dir
  if unfinished_env; then
    RESUME=true
    ok "An earlier run of $INSTALLER didn't finish; this one carries on with the .env it wrote."
    return 0
  fi
  [ -f "$PROJECT_DIR/.env" ] && fail "$APP_NAME is already set up here (.env exists). Upgrade it with $UPGRADE_CMD instead."
  config=$(compose_config) || true
  project=$(awk '/^name:/ { print $2; exit }' <<< "$config")
  # shellcheck disable=SC2086
  ids=$(env $PREFLIGHT_ENV docker compose ps -a -q 2> /dev/null) || true
  if [ -n "$ids" ]; then
    # Compose labels each container with the folder it was started from.
    dir=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "${ids%%[[:space:]]*}" 2> /dev/null) || true
    if [ -n "$dir" ] && [ "$dir" != "$PROJECT_DIR" ]; then
      fail "$APP_NAME is already installed on this server, in $dir (compose project $project). Upgrade it there with ./$UPGRADER."
    fi
    fail "The $project containers already exist. Upgrade with $UPGRADE_CMD, or remove them first (docker compose down)."
  fi
  # shellcheck disable=SC2013 # names hold no spaces
  for name in $(awk '/^    container_name:/ { print $2 }' <<< "$config"); do
    docker container inspect "$name" > /dev/null 2>&1 && found="$found $name"
  done
  [ -z "$found" ] || fail "Containers with $APP_NAME's names already exist:$found. Is it installed somewhere else on this server?"
  # shellcheck disable=SC2013
  for name in $(awk '/^volumes:/ { v = 1; next } /^[^ ]/ { v = 0 } v && /^    name:/ { print $2 }' <<< "$config"); do
    docker volume inspect "$name" > /dev/null 2>&1 && found="$found $name"
  done
  [ -z "$found" ] || fail "Data from an earlier install is still here (volumes:$found). Upgrade it with $UPGRADE_CMD, or delete the volumes to start again (docker volume rm, which deletes that data)."
  ok "Nothing of $APP_NAME is installed on this server yet."
}

build_images() {
  local out
  out=$(mktemp)
  BUILD_VERSION=$(tr -d '[:space:]' < "$PROJECT_DIR/VERSION" 2> /dev/null || true)
  BUILD_VERSION=${BUILD_VERSION:-$(git -C "$PROJECT_DIR" rev-parse --short HEAD)}
  export BUILD_VERSION
  info "Building $BUILD_VERSION (several minutes the first time)..."
  if docker compose build > "$out" 2>&1; then
    [ -n "${LOG:-}" ] && cat "$out" >> "$LOG.build"
    rm -f "$out"
    ok "Built."
  else
    tail -n 40 "$out" | sed 's/^/    /'
    [ -n "${LOG:-}" ] && cat "$out" >> "$LOG.build"
    rm -f "$out"
    fail "The build failed, so nothing was started. Fix it and run $INSTALLER again: it keeps the .env."
  fi
}

# Waits until every container is running (and healthy, where it has a healthcheck).
wait_for_containers() {
  local deadline=$((SECONDS + HEALTH_TIMEOUT)) pending id name state health code
  info "Waiting for the containers (up to ${HEALTH_TIMEOUT}s)..."
  while :; do
    pending=""
    for id in $(docker compose ps -a -q 2> /dev/null); do
      read -r name state health code < <(docker inspect -f \
        '{{.Name}} {{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} {{.State.ExitCode}}' \
        "$id" 2> /dev/null) || continue
      name=${name#/}
      case "$state/$health" in
        running/healthy | running/none) ;;
        exited/*) [ "$code" = 0 ] || pending="$pending $name(exited $code)" ;;
        running/*) pending="$pending $name($health)" ;;
        *) pending="$pending $name($state)" ;;
      esac
    done
    if [ -z "$pending" ]; then
      ok "Every container is up and healthy."
      return 0
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
      warn "Not healthy after ${HEALTH_TIMEOUT}s:$pending"
      UNHEALTHY=$pending
      return 1
    fi
    sleep 5
  done
}

# wait_for_url URL [seconds]
wait_for_url() {
  local deadline=$((SECONDS + ${2:-60}))
  until curl -fsS -o /dev/null -m 10 "$1" 2> /dev/null; do
    [ "$SECONDS" -ge "$deadline" ] && return 1
    sleep 3
  done
}

check_urls() {
  local url failed=""
  for url in $HEALTH_URLS; do
    if wait_for_url "$url" 60; then ok "Answering: $url"; else failed="$failed $url"; fi
  done
  [ -z "$failed" ] || { warn "Not answering:$failed"; return 1; }
}

compose_logs() {
  local name
  if [ -n "${UNHEALTHY:-}" ]; then
    for name in $UNHEALTHY; do
      name=${name%%(*}
      info "Last lines from $name:"
      docker logs --tail 25 "$name" 2>&1 | sed 's/^/    /' || true
    done
  else
    docker compose logs --tail 25 2>&1 | sed 's/^/    /' || true
  fi
}

# Clones the repository and runs this script from it, for `curl ... | sudo bash`.
bootstrap_clone() {
  local dir=${GW_DIR:-$DEFAULT_DIR}
  [ -n "$PROJECT_DIR" ] && [ -f "$PROJECT_DIR/docker-compose.yml" ] && return 0
  [ -n "$REPO_URL" ] || fail "Run $INSTALLER from a clone of the repository."
  command -v git > /dev/null || fail "git isn't installed."
  if [ -d "$dir/.git" ]; then
    [ -f "$dir/$INSTALLER" ] || fail "$dir already holds an older install: upgrade it with $dir/scripts/upgrade.sh."
    info "$dir already holds a clone; running its installer."
  elif [ -e "$dir" ] && [ -n "$(ls -A "$dir" 2> /dev/null)" ]; then
    fail "$dir already exists and isn't a clone of $REPO_URL (set GW_DIR to install somewhere else)."
  else
    info "Downloading $REPO_URL into $dir..."
    git clone --quiet --branch "$BRANCH" "$REPO_URL" "$dir" || fail "Couldn't clone $REPO_URL into $dir."
  fi
  [ -f "$dir/$INSTALLER" ] || fail "$dir has no $INSTALLER."
  exec bash "$dir/$INSTALLER" "$@"
}

# ── Default hooks ───────────────────────────────────────────────────────────────────────────────
declare -F app_option        > /dev/null || app_option()        { OPTION_ARGS=0; }
declare -F app_bootstrap     > /dev/null || app_bootstrap()     { bootstrap_clone "$@"; }
declare -F app_requirements  > /dev/null || app_requirements()  { docker_requirements; }
declare -F app_existing      > /dev/null || app_existing()      { docker_existing; }
declare -F app_preflight     > /dev/null || app_preflight()     { :; }
declare -F app_questions     > /dev/null || app_questions()     { :; }
declare -F app_summary       > /dev/null || app_summary()       { :; }
declare -F app_env           > /dev/null || app_env()           { :; }
declare -F app_write         > /dev/null || app_write()         { write_env; }
declare -F app_ready         > /dev/null || app_ready()         { :; }
declare -F app_build         > /dev/null || app_build()         { build_images; }
declare -F app_start         > /dev/null || app_start()         { docker compose up -d --remove-orphans; }
declare -F app_health        > /dev/null || app_health()        { wait_for_containers && check_urls; }
declare -F app_logs          > /dev/null || app_logs()          { compose_logs; }
declare -F app_admin         > /dev/null || app_admin()         { info "Open $APP_URL and create the first account there."; }
declare -F app_finish        > /dev/null || app_finish()        { mark_env_installed; }
declare -F app_done          > /dev/null || app_done()          { :; }
declare -F app_cleanup       > /dev/null || app_cleanup()       { :; }

# ── Run ─────────────────────────────────────────────────────────────────────────────────────────
usage() {
  if [ -f "${BASH_SOURCE[0]:-}" ]; then
    awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"
  else
    echo "Run $INSTALLER --help from a clone of the repository for the details."
  fi
}

on_error() { printf '\n  %s✗ Stopped at line %s: %s%s\n' "$R" "$1" "$2" "$N" >&2; }

on_exit() {
  local code=$?
  app_cleanup || true
  if [ "$code" -ne 0 ] && [ "$CHECK" = false ] && [ "${WROTE_SETTINGS:-false}" = true ]; then
    echo ""
    info "Fix what's above, then run $INSTALLER again: it carries on with the same settings."
  fi
  [ -n "${LOG:-}" ] && [ "$code" -ne 0 ] && info "Log: $LOG"
  return 0
}

# Shows the random admin password once, on the terminal only (never in the log).
show_password() {
  [ -n "$GENERATED_PASSWORD" ] || return 0
  if [ -n "${LOG:-}" ]; then
    exec 1>&3 2>&4
    wait "$LOG_PID" 2> /dev/null || sleep 1
  fi
  printf '\n  ┌──────────────────────────────────────────────────────────────\n'
  printf '  │ The admin password (random; shown only now, not in the log):\n'
  printf '  │   %s%s%s\n' "$B" "$GENERATED_PASSWORD" "$N"
  printf '  └──────────────────────────────────────────────────────────────\n\n'
}

main() {
  YES=false CHECK=false SETTINGS_ONLY=false
  APP_NAME="" INSTALLER="" UPGRADER="" UPGRADE_CMD="" REPO_URL="" BRANCH=main DEFAULT_DIR=""
  BACKUP_DIR=backups MIN_FREE_GB=3 MIN_MEMORY_GB=1 HEALTH_TIMEOUT=300 HEALTH_URLS="" APP_URL=""
  FIXED_PORTS="" PREFLIGHT_ENV="" SETTINGS_FILE=""
  RESUME=false GENERATED_PASSWORD="" PASSWORD_SOURCE="" ADMIN_LOGIN="" PASSWORD_NOTE="" WROTE_SETTINGS=false
  LOG="" LOG_PID=""
  app_settings

  local args=("$@")
  while [ $# -gt 0 ]; do
    case "$1" in
      -y | --yes) YES=true ;;
      --check) CHECK=true ;;
      --settings-only) SETTINGS_ONLY=true ;;
      -h | --help) usage; exit 0 ;;
      *)
        OPTION_ARGS=0
        app_option "$@"
        [ "$OPTION_ARGS" -gt 0 ] || fail "Unknown option $1 (see --help)."
        shift $((OPTION_ARGS - 1))
        ;;
    esac
    shift
  done

  PROJECT_DIR=""
  if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  fi
  app_bootstrap "${args[@]}"
  [ -z "$PROJECT_DIR" ] || cd "$PROJECT_DIR" || fail "Can't open $PROJECT_DIR."
  UPGRADE_CMD=${UPGRADE_CMD:-cd $PROJECT_DIR && ./$UPGRADER}
  SETTINGS_FILE=${SETTINGS_FILE:-$PROJECT_DIR/.env}
  TTY=""
  if (exec < /dev/tty) 2> /dev/null; then TTY=/dev/tty; fi

  case "$BACKUP_DIR" in /*) ;; *) BACKUP_DIR="$PROJECT_DIR/$BACKUP_DIR" ;; esac
  STAMP=$(date +%Y%m%d-%H%M%S)
  exec 3>&1 4>&2
  if [ "$CHECK" = false ] && mkdir -p "$BACKUP_DIR" 2> /dev/null && [ -w "$BACKUP_DIR" ]; then
    LOG="$BACKUP_DIR/install-$STAMP.log"
    exec > >(tee -a "$LOG") 2>&1
    LOG_PID=$!
  fi
  trap on_exit EXIT
  trap 'on_error $LINENO "$BASH_COMMAND"' ERR

  printf '%s%s install%s  %s, %s\n' "$B" "$APP_NAME" "$N" "$(hostname)" "$(date '+%Y-%m-%d %H:%M')"

  STEPS=7
  step 1 "Pre-flight"
  app_requirements
  check_disk
  check_memory
  app_existing
  [ "$RESUME" = true ] || check_ports "$FIXED_PORTS"
  app_preflight

  step 2 "Settings"
  if [ "$RESUME" = true ]; then
    app_questions
    ok "Settings: the .env from the earlier run."
  else
    [ "$YES" = true ] || [ "$CHECK" = true ] || info "Press Enter to take the answer in [brackets]."
    app_questions
    echo ""
    app_summary
    echo ""
    if [ "$CHECK" = false ]; then
      confirm "Install $APP_NAME with these settings?" || fail "Stopped. Nothing has changed."
    fi
    app_env
    app_write
  fi
  if [ "$CHECK" = true ]; then
    ok "That's what an install would do (--check changes nothing)."
    return 0
  fi
  WROTE_SETTINGS=true
  app_ready
  if [ "$SETTINGS_ONLY" = true ]; then
    ok "Stopped after the settings (--settings-only). Change them if you like, then run $INSTALLER again."
    return 0
  fi

  step 3 "Build"
  app_build

  step 4 "Start"
  app_start

  step 5 "Health check"
  if ! app_health; then
    app_logs
    fail "$APP_NAME isn't healthy (see above)."
  fi

  step 6 "Admin account"
  app_admin

  step 7 "Done"
  app_finish
  ok "$APP_NAME is installed."
  echo ""
  [ -n "$APP_URL" ] && summary_line "Open" "$APP_URL"
  [ -n "$ADMIN_LOGIN" ] && summary_line "Sign in" "$ADMIN_LOGIN"
  case "$PASSWORD_SOURCE" in
    random) summary_line "Password" "random, shown below once${PASSWORD_NOTE:+ (also $PASSWORD_NOTE)}" ;;
    typed | given) summary_line "Password" "the one you gave${PASSWORD_NOTE:+ (also $PASSWORD_NOTE)}" ;;
    *) [ -z "$PASSWORD_NOTE" ] || summary_line "Password" "$PASSWORD_NOTE" ;;
  esac
  app_done
  summary_line "Settings" "$SETTINGS_FILE (holds the secrets: keep it private)"
  [ -n "$LOG" ] && summary_line "Log" "$LOG"
  summary_line "Upgrade" "$UPGRADE_CMD"
  show_password
}

main "$@"
