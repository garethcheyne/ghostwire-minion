#!/usr/bin/env bash
# Ghostwire Minion: upgrade this install to a new version. Run it on the minion, as root:
#   sudo /opt/ghostwire-minion/scripts/upgrade.sh
#
#   scripts/upgrade.sh               upgrade to the latest release (asks first)
#   scripts/upgrade.sh <version>     go to that tag or branch instead
#   scripts/upgrade.sh --check       say what an upgrade would do; change nothing
#   scripts/upgrade.sh --yes         don't ask (for cron and installers)
#   scripts/upgrade.sh --force       reinstall and restart even when already up to date
#   scripts/upgrade.sh --rollback    go back to what ran before the last upgrade
#
# Every Ghostwire app has this script at scripts/upgrade.sh, with the same options and steps:
#   1 Pre-flight  2 Plan  3 Back up  4 Update code  5 Build  6 Deploy  7 Health check  8 Done
# Backups (config and code), a log of each run and the record --rollback uses go in backups/.
# The "This app" part below is what differs between apps; the "Common" part is the same in all.
# The minion is a system service, not Docker, so it overrides most hooks.

set -Eeuo pipefail

# ═══════════════════════════════════════════════════════════════════════════════════════════════
#  This app
# ═══════════════════════════════════════════════════════════════════════════════════════════════

app_settings() {
  APP_NAME="Ghostwire Minion"
  REPO_URL="https://github.com/garethcheyne/ghostwire-minion.git"
  SERVICE=ghostwire-minion
  MIN_FREE_GB=1
  PORT=$(python3 -c "import json; print(json.load(open('$PROJECT_DIR/config.json')).get('proxy_port', 1080))" 2> /dev/null || echo 1080)
  HEALTH_URLS="http://localhost:$PORT/health"
  WORK=""
  INIT=""
}

app_requirements() {
  [ "$(id -u)" = 0 ] || fail "Run this as root (sudo $0)."
  [ -f "$PROJECT_DIR/config.json" ] && [ -f "$PROJECT_DIR/minion.py" ] \
    || fail "$PROJECT_DIR isn't an installed minion. Install one with install.sh first."
  command -v python3 > /dev/null || fail "python3 isn't installed."
  command -v git > /dev/null || fail "git isn't installed."
  command -v curl > /dev/null || fail "curl isn't installed."
  if command -v systemctl > /dev/null && systemctl --version > /dev/null 2>&1; then INIT=systemd
  elif command -v rc-service > /dev/null; then INIT=openrc
  else fail "No systemd or OpenRC here."; fi
}

minion_service() {
  case "$INIT" in
    systemd) systemctl "$1" "$SERVICE" ;;
    openrc) rc-service "$SERVICE" "$1" ;;
  esac
}

app_is_running() {
  case "$INIT" in
    systemd) systemctl is-active --quiet "$SERVICE" ;;
    openrc) rc-service "$SERVICE" status 2> /dev/null | grep -q started ;;
  esac
}

installed_version() { tr -d '[:space:]' < "$1/VERSION" 2> /dev/null || echo unknown; }

# Downloads the version to install; the minion itself is a copy of the code, not a git checkout.
app_plan() {
  WORK=$(mktemp -d)
  git clone --quiet --depth 1 --branch "${REF:-$BRANCH}" "$REPO_URL" "$WORK/src" 2> /dev/null \
    || fail "Couldn't download ${REF:-$BRANCH} from $REPO_URL (a tag or branch name)."
  CURRENT_LABEL="v$(installed_version "$PROJECT_DIR")"
  TARGET_LABEL="v$(installed_version "$WORK/src") ($(git -C "$WORK/src" rev-parse --short HEAD))"
  # Like TRACK=release in the other apps: a new version is a new VERSION.
  if [ "$(installed_version "$PROJECT_DIR")" = "$(installed_version "$WORK/src")" ]; then
    UP_TO_DATE=true
  else
    UP_TO_DATE=false
    info "Latest change: $(git -C "$WORK/src" log -1 --format='%s (%cr)')"
  fi
}

app_backup() {
  BACKUP_FILE="$BACKUP_DIR/upgrade-$STAMP.tar.gz"
  (umask 077; tar czf "$BACKUP_FILE" -C "$PROJECT_DIR" config.json minion.py requirements.txt $(cd "$PROJECT_DIR" && ls VERSION 2> /dev/null))
  ok "Config and code: $BACKUP_FILE"
}

# Keeps the running code and its Python environment in .previous, for --rollback.
app_snapshot() {
  rm -rf "$PROJECT_DIR/.previous"
  mkdir -p "$PROJECT_DIR/.previous"
  cp -a "$PROJECT_DIR/minion.py" "$PROJECT_DIR/requirements.txt" "$PROJECT_DIR/venv" "$PROJECT_DIR/.previous/"
  [ -f "$PROJECT_DIR/VERSION" ] && cp -a "$PROJECT_DIR/VERSION" "$PROJECT_DIR/.previous/"
  SNAPSHOT=.previous
  ok "Running version kept in $PROJECT_DIR/.previous for --rollback."
}

app_update() { ok "Downloaded $TARGET_LABEL; install.sh copies it in during Deploy."; }
app_build() { ok "install.sh rebuilds the Python environment during Deploy."; }

# install.sh sees the existing install and upgrades it: it keeps config.json, stops the service,
# copies the code, rebuilds the venv and starts the service again.
app_deploy() { bash "$WORK/src/install.sh" < /dev/null; }

app_health() {
  local socks=$((PORT + 1)) i
  for i in $(seq 1 12); do app_is_running && break; sleep 5; done
  app_is_running || { warn "The $SERVICE service isn't running."; return 1; }
  ok "The $SERVICE service is running."
  check_urls || return 1
  if (echo > "/dev/tcp/127.0.0.1/$socks") 2> /dev/null; then ok "SOCKS5 is listening on $socks."
  else warn "SOCKS5 isn't listening on $socks."; return 1; fi
}

app_logs() {
  case "$INIT" in
    systemd) journalctl -u "$SERVICE" -n 30 --no-pager 2>&1 | sed 's/^/    /' || true ;;
    openrc) tail -n 30 "/var/log/$SERVICE.log" 2>&1 | sed 's/^/    /' || true ;;
  esac
}

app_rollback() {
  [ -d "$PROJECT_DIR/.previous" ] || fail "There's no kept version in $PROJECT_DIR/.previous."
  minion_service stop || true
  rm -rf "$PROJECT_DIR/venv"
  cp -a "$PROJECT_DIR/.previous/." "$PROJECT_DIR/"
  find "$PROJECT_DIR" -name '__pycache__' -type d -prune -exec rm -rf {} + 2> /dev/null || true
  minion_service start
}

app_restore_hint() { echo "tar xzf $1 -C $PROJECT_DIR, then restart the $SERVICE service"; }
app_cleanup() { [ -z "${WORK:-}" ] || rm -rf "$WORK"; }

# ═══════════════════════════════════════════════════════════════════════════════════════════════
#  Common: the same in every Ghostwire app's scripts/upgrade.sh. Change it in all of them together.
#  A hook the app section above doesn't define uses the default here.
# ═══════════════════════════════════════════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

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

# ask "question" → yes or no. --yes answers yes; with no terminal to ask on, the answer is no.
# ask --always "question" asks even with --yes (for "carry on without a backup?").
ask() {
  local always=false answer=""
  [ "$1" = --always ] && { always=true; shift; }
  if [ "$YES" = true ] && [ "$always" = false ]; then return 0; fi
  if [ ! -t 0 ]; then
    warn "No terminal to ask on, so the answer is no."
    [ "$always" = false ] && info "Run with --yes to go ahead without asking."
    return 1
  fi
  read -r -p "  $1 [y/N] " answer || answer=""
  [[ "$answer" =~ ^[Yy] ]]
}

# ── Settings and state ──────────────────────────────────────────────────────────────────────────
# env_value KEY [default]: one value from .env, without running the file (values may hold $ or #).
env_value() {
  local value=""
  if [ -f "$PROJECT_DIR/.env" ]; then
    value=$(grep -E "^[[:space:]]*(export[[:space:]]+)?$1=" "$PROJECT_DIR/.env" | tail -n1 | cut -d= -f2- \
      | sed -e 's/[[:space:]]*$//' -e "s/^'\(.*\)'\$/\1/" -e 's/^"\(.*\)"$/\1/') || true
  fi
  printf '%s' "${value:-${2:-}}"
}

# What the last upgrade replaced, for --rollback.
save_state() {
  {
    echo "PREV_DATE='$(date '+%Y-%m-%d %H:%M')'"
    echo "PREV_COMMIT='${CURRENT_COMMIT:-}'"
    echo "PREV_LABEL='$CURRENT_LABEL'"
    echo "PREV_SNAPSHOT='${SNAPSHOT:-}'"
    echo "PREV_BACKUP='${BACKUP_FILE:-}'"
    printf '%s\n' "${STATE_EXTRA:-}"
  } > "$STATE_FILE"
}

load_state() {
  [ -f "$STATE_FILE" ] || fail "There's no earlier upgrade to go back to ($STATE_FILE is missing)."
  # shellcheck disable=SC1090
  . "$STATE_FILE"
}

notify() {
  local token chat
  [ "$(env_value TELEGRAM_NOTIFICATIONS_ENABLED)" = true ] || return 0
  token=$(env_value TELEGRAM_BOT_TOKEN)
  chat=$(env_value TELEGRAM_CHAT_ID)
  [ -n "$token" ] && [ -n "$chat" ] || return 0
  curl -s -m 10 "https://api.telegram.org/bot$token/sendMessage" \
    --data-urlencode "chat_id=$chat" --data-urlencode "text=$APP_NAME on $(hostname): $1" \
    > /dev/null 2>&1 || true
}

# ── Versions (git) ──────────────────────────────────────────────────────────────────────────────
version_file() { git show "$1:VERSION" 2>/dev/null | tr -d '[:space:]' || true; }

version_at() {
  local version short
  version=$(version_file "$1")
  short=$(git rev-parse --short "$1")
  if [ -n "$version" ]; then echo "v$version ($short)"; else echo "$short"; fi
}

plan_git() {
  local count
  git fetch --quiet --tags origin "$BRANCH" || fail "git fetch failed (network or credentials?)"
  CURRENT_COMMIT=$(git rev-parse HEAD)
  if [ -n "$REF" ]; then
    TARGET_COMMIT=$(git rev-parse --verify --quiet "$REF^{commit}" \
      || git rev-parse --verify --quiet "origin/$REF^{commit}") \
      || fail "There's no version called $REF (give a tag, branch or commit)."
  else
    TARGET_COMMIT=$(git rev-parse "origin/$BRANCH")
    # TRACK=release: only move when the VERSION file on $BRANCH changes (a release was cut).
    if [ "$TRACK" = release ] && [ "$(version_file "$TARGET_COMMIT")" = "$(version_file "$CURRENT_COMMIT")" ]; then
      TARGET_COMMIT=$CURRENT_COMMIT
    fi
  fi

  CURRENT_LABEL=$(version_at "$CURRENT_COMMIT")
  TARGET_LABEL=$(version_at "$TARGET_COMMIT")
  BUILD_VERSION=$(version_file "$TARGET_COMMIT")
  BUILD_VERSION=${BUILD_VERSION:-$(git rev-parse --short "$TARGET_COMMIT")}

  if [ "$CURRENT_COMMIT" = "$TARGET_COMMIT" ]; then
    UP_TO_DATE=true
  elif git merge-base --is-ancestor "$TARGET_COMMIT" "$CURRENT_COMMIT"; then
    UP_TO_DATE=false
    warn "This goes back $(git rev-list --count "$TARGET_COMMIT..$CURRENT_COMMIT") commit(s)."
  else
    UP_TO_DATE=false
    count=$(git rev-list --count "$CURRENT_COMMIT..$TARGET_COMMIT")
    info "$count new commit(s):"
    git log --oneline --no-decorate -15 "$CURRENT_COMMIT..$TARGET_COMMIT" | sed 's/^/    /'
    [ "$count" -gt 15 ] && info "    …"
  fi
  return 0
}

update_code() {
  if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    git stash push --quiet -m "upgrade.sh $STAMP"
    warn "Local changes to tracked files were stashed (git stash list)."
  fi
  if [ -n "$REF" ]; then
    git checkout --quiet --detach "$TARGET_COMMIT"
  else
    git checkout --quiet "$BRANCH" 2>/dev/null || git checkout --quiet -b "$BRANCH" "origin/$BRANCH"
    git merge --quiet --ff-only "$TARGET_COMMIT" \
      || fail "$BRANCH has commits that aren't on origin/$BRANCH; sort that out by hand. Nothing is restarted."
  fi
  ok "Code is at $(version_at HEAD)."
}

# ── Docker ──────────────────────────────────────────────────────────────────────────────────────
service_container() { docker compose ps -a -q "$1" 2>/dev/null | head -n1; }

# "service image" for every service built from this repo (an image named after the project when
# the compose file doesn't name one).
built_services() {
  docker compose config 2>/dev/null | awk '
    /^name:/                { project = $2 }
    /^[^ ]/                 { in_services = ($0 == "services:"); next }
    !in_services            { next }
    /^  [^ ]/               { flush(); service = $1; sub(/:$/, "", service); image = ""; built = 0; next }
    /^    build:/           { built = 1 }
    /^    image:/           { image = $2 }
    function flush() {
      if (service != "" && built) {
        if (image == "") image = project "-" service
        if (image !~ /:[^\/]+$/) image = image ":latest"
        print service, image
      }
      service = ""
    }
    END                     { flush() }' || true
}

docker_requirements() {
  command -v git > /dev/null || fail "git isn't installed."
  command -v curl > /dev/null || fail "curl isn't installed."
  command -v docker > /dev/null || fail "Docker isn't installed."
  docker compose version > /dev/null 2>&1 || fail "Docker Compose v2 isn't available (docker compose)."
  docker info > /dev/null 2>&1 || fail "Can't talk to Docker (is it running? does this user need sudo?)."
  git rev-parse --git-dir > /dev/null 2>&1 || fail "$PROJECT_DIR isn't a git checkout."
  docker compose config -q > /dev/null 2>&1 || fail "docker-compose.yml doesn't parse: run docker compose config to see why."
}

check_env() {
  local key missing=""
  [ -z "$REQUIRED_ENV" ] && return 0
  [ -f "$PROJECT_DIR/.env" ] || fail ".env is missing; copy .env.example to .env and fill it in first."
  for key in $REQUIRED_ENV; do
    [ -n "$(env_value "$key")" ] || missing="$missing $key"
  done
  [ -z "$missing" ] || fail "Set these in .env first:$missing"
  ok ".env has$(printf ' %s' $REQUIRED_ENV)."
}

# check_auth_secret [NAME]: sign-in needs a long random secret.
check_auth_secret() {
  local name=${1:-BETTER_AUTH_SECRET} secret
  secret=$(env_value "$name")
  [ ${#secret} -ge 32 ] || fail "$name in .env is missing or shorter than 32 characters (make one: openssl rand -base64 48)."
}

check_disk() {
  local free_kb
  free_kb=$(df -Pk "$PROJECT_DIR" 2>/dev/null | awk 'NR == 2 { print $4 }')
  if [ -n "$free_kb" ] && [ "$free_kb" -lt $((MIN_FREE_GB * 1024 * 1024)) ]; then
    warn "Only $((free_kb / 1024 / 1024)) GB free; a build needs about ${MIN_FREE_GB} GB (docker system prune can free some)."
  else
    ok "Disk space is fine."
  fi
}

backup_database() {
  local container
  [ -n "$DB_SERVICE" ] || { info "No database to back up."; return 0; }
  container=$(app_service_container "$DB_SERVICE")
  if [ -z "$container" ] || [ "$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null)" != true ]; then
    info "The database isn't running (a first install?), so there's nothing to back up."
    return 0
  fi
  BACKUP_FILE="$BACKUP_DIR/upgrade-$STAMP.dump"
  if docker exec -e PGPASSWORD="${DB_PASSWORD:-}" "$container" \
      pg_dump -U "$DB_USER" -d "$DB_NAME" -Fc > "$BACKUP_FILE.tmp" 2> "$BACKUP_FILE.err"; then
    mv "$BACKUP_FILE.tmp" "$BACKUP_FILE"
    rm -f "$BACKUP_FILE.err"
    ok "Database: $BACKUP_FILE ($(du -h "$BACKUP_FILE" | cut -f1))"
  else
    warn "The database backup failed:"
    sed 's/^/    /' "$BACKUP_FILE.err"
    rm -f "$BACKUP_FILE.tmp" "$BACKUP_FILE.err"
    BACKUP_FILE=""
    ask --always "Carry on WITHOUT a backup?" || fail "Stopped. Nothing has changed."
  fi
}

backup_env() {
  [ -f "$PROJECT_DIR/.env" ] || return 0
  ENV_BACKUP="$BACKUP_DIR/upgrade-$STAMP.env"
  (umask 077; cp "$PROJECT_DIR/.env" "$ENV_BACKUP")
  ok "Settings: $ENV_BACKUP"
}

# ── Database password ───────────────────────────────────────────────────────────────────────────
# random_secret LENGTH: letters and digits only, so it is safe in .env, a URL and SQL as it is.
random_secret() {
  local secret
  secret=$(openssl rand -base64 $(($1 * 2)) 2> /dev/null | tr -dc 'A-Za-z0-9' | head -c "$1") || true
  [ ${#secret} -eq "$1" ] || secret=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$1") || true
  [ ${#secret} -eq "$1" ] || fail "Couldn't make a random password (no openssl or /dev/urandom)."
  printf '%s' "$secret"
}

sha256_of() {
  if command -v sha256sum > /dev/null; then printf '%s' "$1" | sha256sum | cut -c1-64
  else printf '%s' "$1" | shasum -a 256 | cut -c1-64; fi
}

# A password anyone could know: empty, a compose default, a placeholder from .env.example, or one
# the app lists in WEAK_DB_PASSWORD_HASHES (the sha256 of passwords that were published, in git
# history for example, so the script doesn't publish them again).
weak_db_password() {
  case "$1" in
    "" | ghostwire | postgres | password | admin | *change-this* | *changeme* | *change_me*) return 0 ;;
  esac
  [ -n "$WEAK_DB_PASSWORD_HASHES" ] || return 1
  case " $WEAK_DB_PASSWORD_HASHES " in *" $(sha256_of "$1") "*) return 0 ;; esac
  return 1
}

# Pre-flight: decides whether this run changes the database password (ROTATE_DB).
check_db_password() {
  if [ -z "$DB_SERVICE" ] || [ -z "$DB_PASSWORD_ENV" ]; then
    [ "$ROTATE_DB" = true ] && fail "$APP_NAME has no database password to change."
    return 0
  fi
  if [ "$ROTATE_DB" = true ]; then
    info "The database password will be changed (--rotate-db-password)."
  elif weak_db_password "$DB_PASSWORD"; then
    warn "The database password is a default or a published one, so this run changes it."
    ROTATE_DB=true
  elif [ ${#DB_PASSWORD} -lt 16 ]; then
    warn "The database password is shorter than 16 characters (scripts/upgrade.sh --rotate-db-password changes it)."
  else
    ok "The database password isn't a default or a published one."
  fi
}

# set_role_password CONTAINER CURRENT NEW
set_role_password() {
  local user=${DB_USER//\"/\"\"} password=${3//\'/\'\'}
  printf 'ALTER ROLE "%s" PASSWORD '\''%s'\'';\n' "$user" "$password" \
    | docker exec -i -e PGPASSWORD="$2" "$1" psql -X -q -v ON_ERROR_STOP=1 -U "$DB_USER" -d "$DB_NAME" > /dev/null
}

# write_env_password OLD NEW: the DB_PASSWORD_ENV line (added when .env has none) and :OLD@ in each
# DB_URL_ENV line. Rewritten in place, so .env keeps its owner and mode.
write_env_password() {
  local tmp
  tmp=$(mktemp)
  OLD="$1" NEW="$2" KEY="$DB_PASSWORD_ENV" URLS=" $DB_URL_ENV " awk '
    BEGIN { old = ENVIRON["OLD"]; new = ENVIRON["NEW"]; key = ENVIRON["KEY"]; urls = ENVIRON["URLS"] }
    {
      line = $0; rest = line
      sub(/^[ \t]*(export[ \t]+)?/, "", rest)
      prefix = substr(line, 1, length(line) - length(rest))
      eq = index(rest, "=")
      if (eq > 1) {
        name = substr(rest, 1, eq - 1)
        if (name == key) { print prefix name "=" new; found = 1; next }
        if (index(urls, " " name " ") && (at = index(line, ":" old "@")))
          line = substr(line, 1, at) new substr(line, at + length(old) + 1)
      }
      print line
    }
    END { if (!found) print key "=" new }' "$PROJECT_DIR/.env" > "$tmp"
  cat "$tmp" > "$PROJECT_DIR/.env"
  rm -f "$tmp"
}

# Changes the database password, then puts it in .env. Postgres keeps the sessions already open, so
# the running app carries on until the deploy recreates its containers with the new .env. The new
# password is proved over the network before .env changes; if it doesn't work the old one goes back.
rotate_db_password() {
  local container key value new old=$DB_PASSWORD
  container=$(app_service_container "$DB_SERVICE")
  if [ -z "$container" ] || [ "$(docker inspect -f '{{.State.Running}}' "$container" 2> /dev/null)" != true ]; then
    [ "$ROTATE_ONLY" = true ] && fail "The database isn't running, so its password can't be changed."
    warn "The database isn't running, so its password stays as it is (run --rotate-db-password once it is)."
    ROTATE_DB=false
    return 0
  fi
  [ -f "$PROJECT_DIR/.env" ] || fail ".env is missing, so there's nowhere to put a new password."
  for key in $DB_URL_ENV; do
    value=$(env_value "$key")
    case "$value" in
      "" | *'${'"$DB_PASSWORD_ENV"'}'* | *'$'"$DB_PASSWORD_ENV"* | *":$old@"*) ;;
      *) fail "$key in .env doesn't hold the database password as :password@, so it can't be updated. Nothing has changed." ;;
    esac
  done

  new=$(random_secret 40)
  set_role_password "$container" "$old" "$new" || fail "Couldn't change the database password. Nothing has changed."
  if ! docker exec -e PGPASSWORD="$new" "$container" \
      psql -X -h "$DB_SERVICE" -U "$DB_USER" -d "$DB_NAME" -tAc 'SELECT 1' > /dev/null 2>&1; then
    set_role_password "$container" "$new" "$old" || warn "Couldn't put the old password back either; it's in ${ENV_BACKUP:-.env}."
    fail "The new database password didn't work, so the old one was put back. Nothing else has changed."
  fi
  write_env_password "$old" "$new"
  OLD_DB_PASSWORD=$old
  DB_PASSWORD=$new
  ROTATED_DB=true
  ok "The database password is changed and .env has the new one (the old .env: ${ENV_BACKUP:-none})."
}

# Puts the old password back in the database and the old .env back, then restarts with them.
revert_db_password() {
  local container
  container=$(app_service_container "$DB_SERVICE")
  set_role_password "$container" "$DB_PASSWORD" "$OLD_DB_PASSWORD" || { warn "Couldn't put the old database password back."; return 1; }
  cat "$ENV_BACKUP" > "$PROJECT_DIR/.env"
  DB_PASSWORD=$OLD_DB_PASSWORD
  ROTATED_DB=false
  app_deploy
  ok "The old database password and .env are back."
}

# --rotate-db-password, and an up-to-date install whose password is a default or published one.
# rotate_steps FIRST: Back up, Change the password, Health check, numbered from FIRST.
rotate_steps() {
  step "$1" "Back up"
  BACKUP_FILE=""
  app_backup
  backup_env

  step $(($1 + 1)) "Change the database password"
  rotate_db_password
  app_deploy

  step $(($1 + 2)) "Health check"
  if app_health && app_verify; then
    ok "$APP_NAME is running on the new database password."
    notify "database password changed"
    return 0
  fi
  app_logs
  warn "$APP_NAME isn't healthy on the new database password."
  if [ "$ROTATED_DB" = true ] && ask --always "Put the old database password back?" && revert_db_password && app_health; then
    fail "It wasn't healthy on the new password, so the old one is back."
  fi
  notify "database password changed but it isn't healthy"
  fail "$APP_NAME isn't healthy on the new database password. The old .env is $ENV_BACKUP."
}

rotate_flow() {
  STEPS=4
  step 1 "Pre-flight"
  app_requirements
  check_env
  check_db_password
  if [ "$CHECK" = true ]; then
    ok "That's what it would do (--check changes nothing)."
    return 0
  fi
  ask "Change $APP_NAME's database password now?" || fail "Stopped. Nothing has changed."
  rotate_steps 2
}

# Tags each running image as <image>:previous, for --rollback.
snapshot_images() {
  local service image container id kept=""
  SNAPSHOT=""
  while read -r service image; do
    [ -n "$service" ] || continue
    container=$(app_service_container "$service")
    [ -n "$container" ] || continue
    id=$(docker inspect -f '{{.Image}}' "$container" 2>/dev/null) || continue
    docker tag "$id" "${image%:*}:previous"
    SNAPSHOT="$SNAPSHOT $service=$image"
    kept="$kept $service"
  done < <(built_services)
  if [ -n "$kept" ]; then ok "Images kept for --rollback:$kept"; else info "Nothing running yet, so no images to keep."; fi
}

build_images() {
  local out
  out=$(mktemp)
  export BUILD_VERSION
  info "Building $BUILD_VERSION (a few minutes)..."
  if docker compose build > "$out" 2>&1; then
    [ -n "${LOG:-}" ] && cat "$out" >> "$LOG.build"
    rm -f "$out"
    ok "Built."
  else
    tail -n 40 "$out" | sed 's/^/    /'
    [ -n "${LOG:-}" ] && cat "$out" >> "$LOG.build"
    rm -f "$out"
    fail "The build failed. Nothing was restarted; the old version is still running."
  fi
}

rollback_images() {
  local pair service image services=""
  [ -n "${PREV_SNAPSHOT:-}" ] || fail "The last upgrade kept no images to go back to."
  for pair in $PREV_SNAPSHOT; do
    service=${pair%%=*}
    image=${pair#*=}
    if docker image inspect "${image%:*}:previous" > /dev/null 2>&1; then
      docker tag "${image%:*}:previous" "$image"
      services="$services $service"
    else
      warn "No kept image for $service; it stays as it is."
    fi
  done
  [ -n "$services" ] || fail "None of the kept images are left."
  if [ -n "${PREV_COMMIT:-}" ]; then
    if [ "$(git rev-parse "$BRANCH")" = "$PREV_COMMIT" ]; then
      git checkout --quiet "$BRANCH"
    else
      git checkout --quiet --detach "$PREV_COMMIT"
    fi
    ok "Code is back at $(version_at HEAD)."
  fi
  # shellcheck disable=SC2086
  docker compose up -d --no-build --force-recreate $services
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
        "$id" 2>/dev/null) || continue
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

# check_prisma_migrations: every folder in prisma/migrations is applied.
check_prisma_migrations() {
  local dir="$PROJECT_DIR/prisma/migrations" container applied migration missing="" total=0
  [ -d "$dir" ] || return 0
  container=$(app_service_container "$DB_SERVICE")
  applied=$(docker exec "$container" psql -U "$DB_USER" -d "$DB_NAME" -tAc \
    "SELECT migration_name FROM _prisma_migrations WHERE finished_at IS NOT NULL" 2>/dev/null) \
    || { warn "Couldn't read the migration table."; return 1; }
  for migration in "$dir"/*/; do
    migration=$(basename "$migration")
    total=$((total + 1))
    grep -qx "$migration" <<< "$applied" || missing="$missing $migration"
  done
  [ -z "$missing" ] || { warn "Database migrations not applied:$missing"; return 1; }
  ok "All $total database migrations are applied."
}

# check_alembic_migrations SERVICE: the database is at the newest Alembic revision.
check_alembic_migrations() {
  local container current heads
  container=$(app_service_container "$1")
  current=$(docker exec "$container" alembic current 2> /dev/null | awk '/^[0-9a-f]/ { print $1 }' | sort) || true
  heads=$(docker exec "$container" alembic heads 2> /dev/null | awk '/^[0-9a-f]/ { print $1 }' | sort) || true
  if [ -z "$heads" ]; then warn "Couldn't ask Alembic for the database revision."; return 1; fi
  [ "$current" = "$heads" ] || { warn "The database is at ${current:-nothing}, the code expects $heads."; return 1; }
  ok "The database is at the newest revision ($heads)."
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

# ── Default hooks ───────────────────────────────────────────────────────────────────────────────
declare -F app_requirements  > /dev/null || app_requirements()  { docker_requirements; }
declare -F app_preflight     > /dev/null || app_preflight()     { :; }
declare -F app_is_running    > /dev/null || app_is_running()    { [ -n "$(docker compose ps -q --status running 2>/dev/null)" ]; }
declare -F app_service_container > /dev/null || app_service_container() { service_container "$1"; }
declare -F app_plan          > /dev/null || app_plan()          { plan_git; }
declare -F app_backup        > /dev/null || app_backup()        { backup_database; }
declare -F app_snapshot      > /dev/null || app_snapshot()      { snapshot_images; }
declare -F app_update        > /dev/null || app_update()        { update_code; }
declare -F app_build         > /dev/null || app_build()         { build_images; }
declare -F app_deploy        > /dev/null || app_deploy()        { docker compose up -d --remove-orphans; }
declare -F app_health        > /dev/null || app_health()        { wait_for_containers && check_urls; }
declare -F app_verify        > /dev/null || app_verify()        { :; }
declare -F app_logs          > /dev/null || app_logs()          { compose_logs; }
declare -F app_rollback      > /dev/null || app_rollback()      { rollback_images; }
declare -F app_restore_hint  > /dev/null || app_restore_hint()  {
  echo "docker compose exec -T $DB_SERVICE pg_restore -U $DB_USER -d $DB_NAME --clean --if-exists < $1"
}
declare -F app_cleanup       > /dev/null || app_cleanup()       { :; }

# ── Run ─────────────────────────────────────────────────────────────────────────────────────────
usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }

on_error() { printf '\n  %s✗ Stopped at line %s: %s%s\n' "$R" "$1" "$2" "$N" >&2; }

on_exit() {
  local code=$?
  app_cleanup || true
  if [ "$code" -ne 0 ] && [ "${CHANGED:-false}" = true ]; then
    echo ""
    info "To go back to $CURRENT_LABEL:  scripts/upgrade.sh --rollback"
    [ -n "${BACKUP_FILE:-}" ] && info "Database backup:  $BACKUP_FILE"
    notify "upgrade to ${TARGET_LABEL:-?} FAILED (still on or partly on $CURRENT_LABEL). Log: ${LOG:-none}"
  fi
  [ -n "${LOG:-}" ] && [ "$code" -ne 0 ] && info "Log: $LOG"
  return 0
}

summary_line() { printf '  %-12s %s\n' "$1" "$2"; }

rollback_flow() {
  STEPS=3
  step 1 "Pre-flight"
  app_requirements
  load_state
  info "Goes back to $PREV_LABEL, what ran before the upgrade on $PREV_DATE."
  warn "The database isn't rolled back. Migrations only add, so the older version runs on it."
  [ -n "${PREV_BACKUP:-}" ] && info "To restore the database as it was too: $(app_restore_hint "$PREV_BACKUP")"
  ask "Roll $APP_NAME back to $PREV_LABEL?" || fail "Stopped. Nothing has changed."

  step 2 "Roll back"
  app_rollback

  step 3 "Health check"
  if app_health; then
    ok "Rolled back to $PREV_LABEL."
    notify "rolled back to $PREV_LABEL"
  else
    app_logs
    notify "rolled back to $PREV_LABEL but it isn't healthy"
    fail "Rolled back, but it isn't healthy (see above)."
  fi
}

main() {
  REF="" CHECK=false YES=false FORCE=false ROLLBACK=false ROTATE_ONLY=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --check) CHECK=true ;;
      -y | --yes) YES=true ;;
      -f | --force) FORCE=true ;;
      --rollback) ROLLBACK=true ;;
      --rotate-db-password) ROTATE_ONLY=true ;;
      -h | --help) usage; exit 0 ;;
      -*) fail "Unknown option $1 (see --help)." ;;
      *) [ -z "$REF" ] || fail "Give one version only."; REF=$1 ;;
    esac
    shift
  done

  cd "$PROJECT_DIR"
  BRANCH=main TRACK=branch BACKUP_DIR=backups KEEP_BACKUPS=10 MIN_FREE_GB=3 HEALTH_TIMEOUT=180
  DB_SERVICE="" DB_USER="" DB_NAME="" DB_PASSWORD="" REQUIRED_ENV="" HEALTH_URLS="" APP_URL=""
  DB_PASSWORD_ENV="" DB_URL_ENV="" WEAK_DB_PASSWORD_HASHES=""
  ROTATE_DB=$ROTATE_ONLY ROTATED_DB=false OLD_DB_PASSWORD="" ENV_BACKUP=""
  APP_NAME=$(basename "$PROJECT_DIR")
  CURRENT_COMMIT="" CURRENT_LABEL="" TARGET_LABEL="" CHANGED=false UP_TO_DATE=false
  app_settings
  # A URL built from other .env values (https://${APP_DOMAIN}) can't be shown as it is.
  case "$APP_URL" in *'$'*) APP_URL="" ;; esac

  case "$BACKUP_DIR" in /*) ;; *) BACKUP_DIR="$PROJECT_DIR/$BACKUP_DIR" ;; esac
  mkdir -p "$BACKUP_DIR"
  STATE_FILE="$BACKUP_DIR/last-upgrade"
  STAMP=$(date +%Y%m%d-%H%M%S)
  LOG=""
  if [ "$CHECK" = false ]; then
    LOG="$BACKUP_DIR/upgrade-$STAMP.log"
    exec > >(tee -a "$LOG") 2>&1
  fi
  trap on_exit EXIT
  trap 'on_error $LINENO "$BASH_COMMAND"' ERR

  printf '%s%s upgrade%s  %s, %s\n' "$B" "$APP_NAME" "$N" "$(hostname)" "$(date '+%Y-%m-%d %H:%M')"

  if [ "$ROLLBACK" = true ]; then
    rollback_flow
    return 0
  fi
  if [ "$ROTATE_ONLY" = true ]; then
    rotate_flow
    return 0
  fi

  STEPS=8
  step 1 "Pre-flight"
  app_requirements
  check_disk
  check_env
  app_preflight
  check_db_password

  step 2 "Plan"
  app_plan
  if [ "$UP_TO_DATE" = true ] && [ "$FORCE" = false ] && app_is_running; then
    ok "Already up to date: $CURRENT_LABEL. (--force rebuilds and restarts anyway.)"
    [ "$ROTATE_DB" = true ] || return 0
    if [ "$CHECK" = true ]; then
      ok "It would change the database password (--check changes nothing)."
      return 0
    fi
    ask "Change the database password now?" || fail "Stopped. Nothing has changed."
    STEPS=5
    rotate_steps 3
    return 0
  fi
  if [ "$UP_TO_DATE" = true ]; then
    info "Rebuild and restart $CURRENT_LABEL."
  else
    info "$CURRENT_LABEL → $TARGET_LABEL"
  fi
  [ "$ROTATE_DB" = true ] && info "The database password is changed just before the deploy."
  if [ "$CHECK" = true ]; then
    ok "That's what an upgrade would do (--check changes nothing)."
    return 0
  fi
  ask "Go ahead?" || fail "Stopped. Nothing has changed."

  step 3 "Back up"
  BACKUP_FILE=""
  app_backup
  backup_env
  app_snapshot
  save_state
  # Keep the newest $KEEP_BACKUPS of each kind.
  for kind in dump tar.gz env log log.build; do
    # shellcheck disable=SC2012
    ls -1t "$BACKUP_DIR"/upgrade-*."$kind" 2> /dev/null | tail -n +$((KEEP_BACKUPS + 1)) | xargs -r rm -f || true
  done

  step 4 "Update code"
  CHANGED=true
  app_update

  step 5 "Build"
  app_build

  step 6 "Deploy"
  notify "upgrading $CURRENT_LABEL → $TARGET_LABEL"
  [ "$ROTATE_DB" = true ] && rotate_db_password
  app_deploy

  step 7 "Health check"
  if ! { app_health && app_verify; }; then
    app_logs
    echo ""
    warn "$APP_NAME isn't healthy on $TARGET_LABEL."
    if [ -t 0 ] && ask --always "Roll back to $CURRENT_LABEL now?"; then
      load_state
      app_rollback
      if app_health; then
        CHANGED=false
        notify "upgrade to $TARGET_LABEL failed its health check; rolled back to $CURRENT_LABEL"
        fail "The upgrade failed its health check, so it was rolled back to $CURRENT_LABEL."
      fi
    fi
    fail "The upgrade to $TARGET_LABEL failed its health check."
  fi

  step 8 "Done"
  CHANGED=false
  summary_line "Version" "$CURRENT_LABEL → $TARGET_LABEL"
  [ -n "$BACKUP_FILE" ] && summary_line "Backup" "$BACKUP_FILE"
  [ "$ROTATED_DB" = true ] && summary_line "Database" "new password, in .env (the old .env: $ENV_BACKUP)"
  summary_line "Log" "$LOG"
  [ -n "$APP_URL" ] && summary_line "Open" "$APP_URL"
  summary_line "Roll back" "scripts/upgrade.sh --rollback"
  notify "upgraded $CURRENT_LABEL → $TARGET_LABEL"
}

main "$@"
