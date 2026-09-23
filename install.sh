#!/usr/bin/env bash
# Standalone installer. The backup program is embedded below.
set -Eeuo pipefail
umask 077
VERSION=1.1.0
CONFIG=/etc/ibsng-backup-telegram.env
SERVICE=ibsng-backup-telegram
BIN=/usr/local/sbin/ibsng-backup-telegram
UNITS=/etc/systemd/system
NONINTERACTIVE=false
RECONFIGURE=false
SKIP_TEST=false
CHECK=false
DETECT_ONLY=false
CONTAINER_OVERRIDE=''
DATABASE_OVERRIDE=''
EXTRACT=''
while (($#)); do
  case "$1" in
    --non-interactive) NONINTERACTIVE=true ;;
    --reconfigure) RECONFIGURE=true ;;
    --skip-test) SKIP_TEST=true ;;
    --check) CHECK=true ;;
    --detect) DETECT_ONLY=true ;;
    --container) shift; CONTAINER_OVERRIDE="${1:?Specify container name}" ;;
    --database) shift; DATABASE_OVERRIDE="${1:?Specify database name}" ;;
    --extract) shift; EXTRACT="${1:?Specify extraction directory}" ;;
    --help|-h) echo 'Usage: bash install.sh [--non-interactive] [--reconfigure] [--skip-test] [--check] [--detect] [--container NAME] [--database NAME] [--extract DIR]'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done
fail() { echo "ERROR: $*" >&2; exit 1; }
STAGE="$(mktemp -d)"
trap 'rm -rf -- "$STAGE"' EXIT
write_worker() {
cat > "$1" <<'IBSNG_WORKER_EOF'
#!/usr/bin/env bash
# IBSng Docker PostgreSQL backup and Telegram delivery.
set -Eeuo pipefail
umask 077
CONFIG_FILE="${CONFIG_FILE:-/etc/ibsng-backup-telegram.env}"
[[ -f "$CONFIG_FILE" ]] || { echo "Config missing: $CONFIG_FILE" >&2; exit 2; }
# This is a root-owned shell configuration, generated with printf %q.
source "$CONFIG_FILE"
IBSNG_CONTAINER="${IBSNG_CONTAINER:-ibsng}"
IBSNG_DB="${IBSNG_DB:-IBSng}"
BACKUP_DIR="${BACKUP_DIR:-/opt/ibsng/backups/telegram}"
RETENTION_HOURS="${RETENTION_HOURS:-72}"
TELEGRAM_API_BASE="${TELEGRAM_API_BASE:-https://api.telegram.org}"
LOCK_FILE="${LOCK_FILE:-/run/ibsng-backup-telegram.lock}"
HOST_LABEL="${HOST_LABEL:-$(hostname)}"
TELEGRAM_SEND="${TELEGRAM_SEND:-true}"
[[ "$IBSNG_DB" =~ ^[a-zA-Z0-9_]+$ ]] || { echo 'Invalid database name' >&2; exit 2; }
[[ "$RETENTION_HOURS" =~ ^[0-9]{1,6}$ ]] || { echo 'Invalid retention hours' >&2; exit 2; }
[[ "$BACKUP_DIR" == /* && "$BACKUP_DIR" != / ]] || { echo 'Backup directory must be an absolute non-root path' >&2; exit 2; }
[[ "$TELEGRAM_SEND" == true || "$TELEGRAM_SEND" == false ]] || { echo 'Invalid TELEGRAM_SEND' >&2; exit 2; }
if [[ "$TELEGRAM_SEND" == true ]]; then
  [[ "${TELEGRAM_BOT_TOKEN:-}" =~ ^[0-9]+:[A-Za-z0-9_-]+$ && -n "${TELEGRAM_CHAT_ID:-}" ]] || { echo 'Telegram token or chat ID missing/invalid' >&2; exit 2; }
  [[ "$TELEGRAM_API_BASE" =~ ^https://[a-zA-Z0-9.:-]+$ ]] || { echo 'Invalid HTTPS Telegram API address' >&2; exit 2; }
fi
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
exec 9>"$LOCK_FILE"
flock -n 9 || { echo 'Another backup is running; skipped.'; exit 0; }
docker inspect -f '{{.State.Running}}' "$IBSNG_CONTAINER" 2>/dev/null | grep -qx true || { echo 'IBSng container is not running' >&2; exit 3; }
SAFE_HOST="$(printf '%s' "$HOST_LABEL" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-80)"
TS_UTC="$(date -u +%Y%m%d-%H%M%S)"
OUT="$BACKUP_DIR/${IBSNG_DB}_${SAFE_HOST}_${TS_UTC}.sql.gz"
[[ ! -e "$OUT" ]] || { echo 'Backup filename already exists; retry later' >&2; exit 3; }
TMP="$(mktemp "$BACKUP_DIR/.ibsng-dump.XXXXXX")"
RESPONSE=""
cleanup() { rm -f -- "$TMP"; [[ -z "$RESPONSE" ]] || rm -f -- "$RESPONSE"; }
trap cleanup EXIT
echo "[$(date -Is)] Starting full pg_dump of $IBSNG_DB"
docker exec -u postgres "$IBSNG_CONTAINER" pg_dump "$IBSNG_DB" | gzip -9 > "$TMP"
gzip -t "$TMP"
[[ "$(gzip -dc "$TMP" | wc -c)" -gt 0 ]] || { echo 'Empty database dump' >&2; exit 3; }
mv -- "$TMP" "$OUT"
SHA256="$(sha256sum "$OUT" | awk '{print $1}')"
SIZE_BYTES="$(stat -c '%s' "$OUT")"
COUNTS="$(docker exec -u postgres "$IBSNG_CONTAINER" psql -d "$IBSNG_DB" -Atc "select 'users=' || count(*) from users union all select 'ras=' || count(*) from ras union all select 'admins=' || count(*) from admins;" 2>/dev/null | tr '\n' ' ' || true)"
cat > "$OUT.meta" <<EOF
created_utc=$TS_UTC
host=$HOST_LABEL
container=$IBSNG_CONTAINER
database=$IBSNG_DB
file=$OUT
size_bytes=$SIZE_BYTES
sha256=$SHA256
$COUNTS
EOF
CAPTION="📦 IBSng database backup
🌐 Server: ${HOST_LABEL:0:100}
📁 File: $(basename "$OUT")
📏 Size: $SIZE_BYTES bytes
⏰ UTC: $TS_UTC
👥 ${COUNTS:0:160}
🔐 SHA256: $SHA256"
if [[ "$TELEGRAM_SEND" == true ]]; then
  RESPONSE="$(mktemp "$BACKUP_DIR/.telegram-response.XXXXXX")"
  # Pass the bot URL through stdin so the token is absent from curl's argv.
  if ! HTTP_CODE="$(printf 'url = "%s/bot%s/sendDocument"\n' "$TELEGRAM_API_BASE" "$TELEGRAM_BOT_TOKEN" |
    curl --config - --silent --show-error --connect-timeout 20 --max-time 600 \
      --output "$RESPONSE" --write-out '%{http_code}' \
      --form-string "chat_id=$TELEGRAM_CHAT_ID" \
      --form "document=@\"$OUT\"" \
      --form-string "caption=$CAPTION" \
      --form-string "disable_notification=${TELEGRAM_DISABLE_NOTIFICATION:-false}")"; then
    echo "Telegram network error; local backup retained: $OUT" >&2; exit 4
  fi
  if [[ "$HTTP_CODE" != 200 ]] || ! python3 -c 'import json,sys
try:
    response = json.load(open(sys.argv[1]))
    valid = isinstance(response, dict) and response.get("ok") is True
except (ValueError, OSError):
    valid = False
sys.exit(0 if valid else 1)' "$RESPONSE"; then
    echo "Telegram delivery failed (HTTP $HTTP_CODE); local backup retained: $OUT" >&2; exit 4
  fi
  echo "[$(date -Is)] Telegram delivery confirmed"
else
  echo 'Telegram disabled; local backup only'
fi
# Only this database/host's files; never unrelated backups. Run only after success.
if (( 10#$RETENTION_HOURS > 0 )); then
  find "$BACKUP_DIR" -maxdepth 1 -type f \
    \( -name "${IBSNG_DB}_${SAFE_HOST}_????????-??????.sql.gz" -o -name "${IBSNG_DB}_${SAFE_HOST}_????????-??????.sql.gz.meta" \) \
    -mmin "+$((10#$RETENTION_HOURS * 60))" -delete
fi
echo "[$(date -Is)] Complete: $OUT"
IBSNG_WORKER_EOF
}
write_worker "$STAGE/backup.sh"
bash -n "$STAGE/backup.sh"
if [[ -n "$EXTRACT" ]]; then
  mkdir -p "$EXTRACT"
  install -m 700 "$STAGE/backup.sh" "$EXTRACT/backup.sh"
  echo "Backup program extracted to $EXTRACT/backup.sh"
  exit 0
fi
[[ "$EUID" -eq 0 ]] || fail 'Run as root (sudo bash install.sh).'
command -v systemctl >/dev/null && [[ -d /run/systemd/system ]] || fail 'Requires Linux with systemd.'
command -v docker >/dev/null || fail 'Install and start your Docker-based IBSng first.'
docker info >/dev/null 2>&1 || fail 'Docker is unavailable.'
if [[ -f "$CONFIG" && "$RECONFIGURE" == false && "$DETECT_ONLY" == false && -z "$CONTAINER_OVERRIDE" && -z "$DATABASE_OVERRIDE" ]]; then
  source "$CONFIG"
  echo 'Keeping existing configuration.'
  KEEP_CONFIG=true
else
  KEEP_CONFIG=false
  if [[ -f "$CONFIG" && "$DETECT_ONLY" == false ]]; then source "$CONFIG"; fi
fi
[[ -z "$CONTAINER_OVERRIDE" ]] || IBSNG_CONTAINER="$CONTAINER_OVERRIDE"
[[ -z "$DATABASE_OVERRIDE" ]] || IBSNG_DB="$DATABASE_OVERRIDE"
# When moving to another container, rediscover its database unless specified.
if [[ -n "$CONTAINER_OVERRIDE" && -z "$DATABASE_OVERRIDE" ]]; then unset IBSNG_DB; fi
IBSNG_CONTAINER="${IBSNG_CONTAINER:-}"
IBSNG_DB="${IBSNG_DB:-}"
BACKUP_DIR="${BACKUP_DIR:-/opt/ibsng/backups/telegram}"
RETENTION_HOURS="${RETENTION_HOURS:-72}"
INTERVAL_HOURS="${INTERVAL_HOURS:-1}"
HOST_LABEL="${HOST_LABEL:-$(hostname)}"
TELEGRAM_SEND="${TELEGRAM_SEND:-true}"
prompt() {
  local variable="$1" label="$2" value
  printf '%s [%s]: ' "$label" "${!variable:-}" >/dev/tty
  IFS= read -r value </dev/tty || fail 'Could not read input.'
  [[ -z "$value" ]] || printf -v "$variable" '%s' "$value"
}
# Read catalog metadata only. Do not guess from container or database names.
discover_targets() {
  local container database databases catalog
  local -a containers=()
  FOUND_CONTAINERS=()
  FOUND_DATABASES=()
  command -v timeout >/dev/null || fail 'Automatic detection requires coreutils (timeout).'
  if [[ -n "$IBSNG_CONTAINER" ]]; then
    containers=("$IBSNG_CONTAINER")
  else
    mapfile -t containers < <(docker ps --format '{{.Names}}')
  fi
  for container in "${containers[@]}"; do
    [[ "$container" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || continue
    if [[ -n "$IBSNG_DB" ]]; then
      databases="$IBSNG_DB"
    else
      databases=''
      for catalog in postgres template1; do
        if databases="$(timeout 8 docker exec -u postgres "$container" psql -X -w -d "$catalog" -Atc 'SELECT datname FROM pg_database WHERE datallowconn AND NOT datistemplate ORDER BY datname;' 2>/dev/null)"; then break; fi
      done
    fi
    while IFS= read -r database; do
      [[ "$database" =~ ^[a-zA-Z0-9_]+$ ]] || continue
      if timeout 8 docker exec -u postgres "$container" psql -X -w -d "$database" -Atc "SELECT count(*) FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind='r' AND c.relname IN ('users','ras','admins');" 2>/dev/null | grep -qx 3; then
        FOUND_CONTAINERS+=("$container")
        FOUND_DATABASES+=("$database")
      fi
    done <<< "$databases"
  done
}
if [[ -z "$IBSNG_CONTAINER" || -z "$IBSNG_DB" || "$DETECT_ONLY" == true ]]; then
  echo 'Detecting IBSng containers and databases...'
  discover_targets
  if [[ "${#FOUND_CONTAINERS[@]}" -eq 1 ]]; then
    IBSNG_CONTAINER="${FOUND_CONTAINERS[0]}"
    IBSNG_DB="${FOUND_DATABASES[0]}"
    echo "Auto-detected container: $IBSNG_CONTAINER; database: $IBSNG_DB"
  elif [[ "${#FOUND_CONTAINERS[@]}" -gt 1 ]]; then
    echo 'Multiple IBSng database candidates found:'
    for index in "${!FOUND_CONTAINERS[@]}"; do
      printf '  %d) %s / %s\n' "$((index + 1))" "${FOUND_CONTAINERS[$index]}" "${FOUND_DATABASES[$index]}"
    done
    [[ "$NONINTERACTIVE" == false && "$CHECK" == false && "$DETECT_ONLY" == false ]] || fail 'Select a target with --container NAME --database NAME.'
    printf 'Select a number: ' >/dev/tty
    IFS= read -r selection </dev/tty || fail 'Could not read selection.'
    [[ "$selection" =~ ^[1-9][0-9]{0,3}$ ]] && (( selection <= ${#FOUND_CONTAINERS[@]} )) || fail 'Invalid selection.'
    IBSNG_CONTAINER="${FOUND_CONTAINERS[$((selection - 1))]}"
    IBSNG_DB="${FOUND_DATABASES[$((selection - 1))]}"
  else
    echo 'No compatible IBSng database could be detected.'
    [[ "$NONINTERACTIVE" == false && "$CHECK" == false && "$DETECT_ONLY" == false ]] || fail 'Specify --container NAME --database NAME after checking PostgreSQL access.'
    prompt IBSNG_CONTAINER 'Docker container'
    prompt IBSNG_DB 'Database'
  fi
else
  echo "Using configured container: $IBSNG_CONTAINER; database: $IBSNG_DB"
fi
if [[ "$DETECT_ONLY" == true ]]; then
  echo 'Read-only detection completed; no installation or backup performed.'
  exit 0
fi
if [[ "$KEEP_CONFIG" == false && "$NONINTERACTIVE" == false && "$CHECK" == false ]]; then
  [[ -r /dev/tty ]] || fail 'No terminal; use --non-interactive with environment variables.'
  echo 'IBSng automatic backup'
  prompt HOST_LABEL 'Server label'
  prompt BACKUP_DIR 'Local backup directory'
  prompt INTERVAL_HOURS 'Backup interval in hours'
  prompt RETENTION_HOURS 'Local retention hours (0=unlimited)'
  prompt TELEGRAM_SEND 'Send to Telegram (true/false)'
  if [[ "$TELEGRAM_SEND" == true ]]; then
  printf 'Telegram bot token (hidden; Enter keeps existing): ' >/dev/tty
  IFS= read -rs token </dev/tty || fail 'Could not read token.'
  printf '\n' >/dev/tty
  [[ -z "$token" ]] || TELEGRAM_BOT_TOKEN="$token"
  unset token
  prompt TELEGRAM_CHAT_ID 'Telegram chat ID'
  TELEGRAM_DISABLE_NOTIFICATION="${TELEGRAM_DISABLE_NOTIFICATION:-false}"
  prompt TELEGRAM_DISABLE_NOTIFICATION 'Silent Telegram delivery (true/false)'
  fi
fi
[[ "$IBSNG_CONTAINER" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || fail 'Invalid container name.'
[[ "$IBSNG_DB" =~ ^[a-zA-Z0-9_]+$ ]] || fail 'Invalid database name.'
[[ "$INTERVAL_HOURS" =~ ^[1-9][0-9]{0,3}$ ]] || fail 'Interval must be 1 to 9999 hours.'
[[ "$RETENTION_HOURS" =~ ^[0-9]{1,6}$ ]] || fail 'Retention must be 0 to 999999 hours.'
[[ "$BACKUP_DIR" == /* && "$BACKUP_DIR" != / && "$BACKUP_DIR" != *$'\n'* && "$BACKUP_DIR" != *'"'* && "$BACKUP_DIR" != *'\\'* ]] || fail 'Invalid absolute backup directory.'
[[ "$TELEGRAM_SEND" == true || "$TELEGRAM_SEND" == false ]] || fail 'Invalid TELEGRAM_SEND.'
if [[ "$TELEGRAM_SEND" == true ]]; then
  [[ "${TELEGRAM_BOT_TOKEN:-}" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]] || fail 'Set TELEGRAM_BOT_TOKEN.'
  [[ "${TELEGRAM_CHAT_ID:-}" =~ ^(-?[0-9]+|@[a-zA-Z0-9_]+)$ ]] || fail 'Set a numeric Telegram chat ID or @channel.'
fi
docker inspect -f '{{.State.Running}}' "$IBSNG_CONTAINER" | grep -qx true || fail 'IBSng container is not running.'
docker exec -u postgres "$IBSNG_CONTAINER" pg_dump --version
docker exec -u postgres "$IBSNG_CONTAINER" psql -d "$IBSNG_DB" -Atc 'SELECT 1' | grep -qx 1 || fail 'Database connection failed.'
if [[ "$CHECK" == true ]]; then
  echo 'Read-only preflight passed; no backup sent and no service changed.'
  exit 0
fi
missing=false
for dependency in curl gzip flock python3; do command -v "$dependency" >/dev/null || missing=true; done
if [[ "$missing" == true ]]; then
  if command -v apt-get >/dev/null; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates gzip util-linux python3
  elif command -v dnf >/dev/null; then
    dnf install -y curl ca-certificates gzip util-linux python3
  elif command -v yum >/dev/null; then
    yum install -y curl ca-certificates gzip util-linux python3
  else fail 'Install curl, CA certificates, gzip, util-linux and python3 first.'; fi
fi
if [[ "$KEEP_CONFIG" == true ]]; then
  cp -p "$CONFIG" "$STAGE/config.env"
else
  for variable in IBSNG_CONTAINER IBSNG_DB BACKUP_DIR RETENTION_HOURS INTERVAL_HOURS HOST_LABEL TELEGRAM_SEND TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID TELEGRAM_API_BASE TELEGRAM_DISABLE_NOTIFICATION LOCK_FILE; do
    [[ ! -v "$variable" ]] || printf '%s=%q\n' "$variable" "${!variable}" >> "$STAGE/config.env"
  done
fi
cat > "$STAGE/$SERVICE.service" <<EOF
[Unit]
Description=Full IBSng database backup and Telegram delivery
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=root
Group=root
Environment=CONFIG_FILE=$CONFIG
ExecStart=$BIN
UMask=0077
TimeoutStartSec=1h
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
EOF
# Preserve the exact previous schedule on normal upgrades.
if [[ "$KEEP_CONFIG" == true && -f "$UNITS/$SERVICE.timer" ]]; then
  cp -p "$UNITS/$SERVICE.timer" "$STAGE/$SERVICE.timer"
else
  if [[ "$INTERVAL_HOURS" == 1 ]]; then
    SCHEDULE=$'OnCalendar=hourly\nPersistent=true\nAccuracySec=1min'
  else
    SCHEDULE="OnBootSec=5min
OnUnitActiveSec=${INTERVAL_HOURS}h
AccuracySec=1min"
  fi
  cat > "$STAGE/$SERVICE.timer" <<EOF
[Unit]
Description=Automatic IBSng Telegram backup
[Timer]
$SCHEDULE
Unit=$SERVICE.service
[Install]
WantedBy=timers.target
EOF
fi
# Back up every file before replacing anything. Keep backups root-only.
SNAPSHOT="$(mktemp -d /var/backups/ibsng-backup-installer-XXXXXXXX)"
chmod 700 "$SNAPSHOT"
for original in "$CONFIG" "$BIN" "$UNITS/$SERVICE.service" "$UNITS/$SERVICE.timer"; do
  [[ ! -e "$original" ]] || cp -a --parents "$original" "$SNAPSHOT/"
done
echo "Previous installation saved to $SNAPSHOT"
WAS_ACTIVE=false
WAS_ENABLED=false
systemctl is-active --quiet "$SERVICE.timer" && WAS_ACTIVE=true
systemctl is-enabled --quiet "$SERVICE.timer" && WAS_ENABLED=true
MUTATING=false
rollback() {
  local status=$?
  trap - ERR
  if [[ "$MUTATING" == true ]]; then
    echo 'Installation failed; restoring previous files and timer state.' >&2
    systemctl stop "$SERVICE.timer" || true
    for original in "$CONFIG" "$BIN" "$UNITS/$SERVICE.service" "$UNITS/$SERVICE.timer"; do
      if [[ -e "$SNAPSHOT$original" ]]; then cp -a "$SNAPSHOT$original" "$original"; else rm -f -- "$original"; fi
    done
    systemctl daemon-reload || true
    if [[ "$WAS_ENABLED" == true ]]; then systemctl enable "$SERVICE.timer" || true; else systemctl disable "$SERVICE.timer" || true; fi
    [[ "$WAS_ACTIVE" == false ]] || systemctl start "$SERVICE.timer" || true
  fi
  exit "$status"
}
trap rollback ERR
# Do not interrupt a running database backup.
case "$(systemctl show "$SERVICE.service" -p ActiveState --value 2>/dev/null || true)" in
  activating|active|deactivating) fail 'A backup is running; retry after it finishes.' ;;
esac
MUTATING=true
if [[ -f "$UNITS/$SERVICE.timer" || "$WAS_ACTIVE" == true ]]; then systemctl stop "$SERVICE.timer"; fi
install -m 600 "$STAGE/config.env" "$CONFIG"
install -m 700 "$STAGE/backup.sh" "$BIN"
install -m 644 "$STAGE/$SERVICE.service" "$UNITS/$SERVICE.service"
install -m 644 "$STAGE/$SERVICE.timer" "$UNITS/$SERVICE.timer"
systemctl daemon-reload
if [[ "$SKIP_TEST" == false ]]; then
  echo 'Creating the first backup (and sending it to Telegram if enabled)...'
  systemctl start "$SERVICE.service"
fi
systemctl enable --now "$SERVICE.timer"
systemctl is-active --quiet "$SERVICE.timer"
trap - ERR
echo "Installed IBSng backup $VERSION successfully."
echo "Status: systemctl status $SERVICE.timer"
echo "Run now: systemctl start $SERVICE.service"
echo "Logs: journalctl -u $SERVICE.service -n 50 --no-pager"
