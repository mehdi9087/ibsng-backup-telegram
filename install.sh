#!/usr/bin/env bash
# Standalone installer. The backup program is embedded below.
set -Eeuo pipefail
umask 077
VERSION=1.2.2
CONFIG=/etc/ibsng-backup-telegram.env
SERVICE=ibsng-backup-telegram
BIN=/usr/local/sbin/ibsng-backup-telegram
MANAGER=/usr/local/bin/ibsng-backup
OFFLINE_INSTALLER=/usr/local/lib/ibsng-backup/install.sh
UNITS=/etc/systemd/system
NONINTERACTIVE=false
RECONFIGURE=false
SKIP_TEST=false
CHECK=false
DETECT_ONLY=false
CONTAINER_OVERRIDE=''
DATABASE_OVERRIDE=''
INTERVAL_OVERRIDE=''
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
    --interval) shift; INTERVAL_OVERRIDE="${1:?Specify interval such as 30m or 1h}" ;;
    --extract) shift; EXTRACT="${1:?Specify extraction directory}" ;;
    --help|-h) echo 'Usage: bash install.sh [--non-interactive] [--reconfigure] [--skip-test] [--check] [--detect] [--container NAME] [--database NAME] [--interval 30m|1h|1d] [--extract DIR]'; exit 0 ;;
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
case "${1:-}" in
  '') ;;
  --local) TELEGRAM_SEND=false; RETENTION_HOURS=0 ;;
  *) echo 'Usage: ibsng-backup-telegram [--local]' >&2; exit 2 ;;
esac
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
flock -n 9 || { echo 'Another backup or restore is running; skipped.'; [[ "${1:-}" != --local ]] || exit 5; exit 0; }
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
write_manager() {
cat > "$1" <<'IBSNG_MANAGER_EOF'
#!/usr/bin/env bash
# Interactive and command-line management for IBSng database backups.
set -Eeuo pipefail
umask 077
VERSION=1.2.2
CONFIG=/etc/ibsng-backup-telegram.env
WORKER=/usr/local/sbin/ibsng-backup-telegram
INSTALLER=/usr/local/lib/ibsng-backup/install.sh
MANAGER=/usr/local/bin/ibsng-backup
SERVICE=ibsng-backup-telegram
UNITS=/etc/systemd/system
SNAPSHOT_ROOT=/var/backups
fail() { echo "ERROR: $*" >&2; return 1; }
usage() {
  cat <<'EOF'
Usage: ibsng-backup [COMMAND]
  menu                         Open the interactive management menu
  status                       Show settings, last result and next run
  backup                       Run a backup with configured Telegram delivery
  local                        Make a local backup without sending or pruning
  list                         List saved database backups
  verify FILE.sql.gz            Check gzip, dump marker and optional SHA256
  restore FILE.sql.gz NEW_DB    Import a trusted backup into a NEW database
  configure | backup-service   Change settings using the offline installer
  schedule 30m|1h|1d           Set the automatic backup interval
  enable | disable             Enable or disable automatic backups
  logs [LINES]                 Show recent service logs (default: 50)
  update                       Download and install the latest manager version
  uninstall                    Remove service, settings and local backup files
  version                      Print the installed version
  help                         Show this help
EOF
}
case "${1:-menu}" in
  help|--help|-h) usage; exit 0 ;;
  version|--version) echo "ibsng-backup $VERSION"; exit 0 ;;
esac
[[ "$EUID" -eq 0 ]] || { echo 'Run as root: sudo ibsng-backup' >&2; exit 1; }
[[ -f "$CONFIG" ]] || { echo "Configuration missing: $CONFIG. Run the installer first." >&2; exit 1; }
source "$CONFIG"
IBSNG_CONTAINER="${IBSNG_CONTAINER:-ibsng}"
IBSNG_DB="${IBSNG_DB:-IBSng}"
BACKUP_DIR="${BACKUP_DIR:-/opt/ibsng/backups/telegram}"
LOCK_FILE="${LOCK_FILE:-/run/ibsng-backup-telegram.lock}"
read_input() {
  local target="$1" label="$2" input_value
  printf '%s: ' "$label" >/dev/tty || return 1
  IFS= read -r input_value </dev/tty || return 1
  printf -v "$target" '%s' "$input_value"
}
confirm() {
  local answer
  read_input answer "Type $1 to confirm" || return 1
  [[ "$answer" == "$1" ]] || { echo 'Cancelled.'; return 1; }
}
show_status() {
  printf 'IBSng Backup Manager %s\nContainer: %s\nDatabase: %s\nDirectory: %s\n' "$VERSION" "$IBSNG_CONTAINER" "$IBSNG_DB" "$BACKUP_DIR"
  printf 'Interval: %s\nRetention: %s hours\nTelegram: %s\n' "${BACKUP_INTERVAL:-${INTERVAL_HOURS:-1}h}" "${RETENTION_HOURS:-72}" "${TELEGRAM_SEND:-true}"
  printf 'Bot token: %s\n' "${TELEGRAM_BOT_TOKEN:+configured (hidden)}"
  systemctl show "$SERVICE.service" -p Result -p ExecMainStatus -p ExecMainExitTimestamp
  systemctl list-timers --all "$SERVICE.timer" --no-pager
  printf 'Timer enabled: '; systemctl is-enabled "$SERVICE.timer" || true
  printf 'Timer active: '; systemctl is-active "$SERVICE.timer" || true
}
list_backups() {
  [[ -d "$BACKUP_DIR" ]] || { echo 'No backup directory yet.'; return 0; }
  python3 - "$BACKUP_DIR" <<'PY'
import datetime, pathlib, sys
files = sorted(pathlib.Path(sys.argv[1]).glob('*.sql.gz'), key=lambda p: p.stat().st_mtime, reverse=True)
if not files:
    print('No database backups found.')
for p in files:
    s = p.stat()
    print(f'{datetime.datetime.fromtimestamp(s.st_mtime):%Y-%m-%d %H:%M:%S}  {s.st_size / 1048576:8.2f} MiB  {p}')
PY
}
verify_backup() {
  local file="$1" expected actual
  [[ -f "$file" && "$file" == *.sql.gz ]] || { fail 'Select an existing .sql.gz database backup.'; return 1; }
  gzip -t -- "$file" || { fail 'Invalid or truncated gzip file.'; return 1; }
  # Read the full stream to avoid SIGPIPE hiding a decompression failure.
  gzip -dc -- "$file" | awk '/^-- PostgreSQL database dump complete/{ok=1} END{exit !ok}' || { fail 'PostgreSQL dump completion marker is missing.'; return 1; }
  actual="$(sha256sum -- "$file" | awk '{print $1}')"
  if [[ -f "$file.meta" ]]; then
    expected="$(sed -n 's/^sha256=//p' "$file.meta")"
    [[ "$expected" =~ ^[a-fA-F0-9]{64}$ && "${expected,,}" == "$actual" ]] || { fail 'SHA256 metadata mismatch.'; return 1; }
    echo 'Integrity and SHA256 metadata checks passed.'
  else
    echo 'Integrity checks passed; no sidecar metadata available for comparison.'
  fi
  printf 'SHA256: %s\n' "$actual"
}
restore_database() (
  # A subshell releases the maintenance lock on every exit path.
  local file target exists
  file="$(readlink -f -- "$1")" || exit 1
  target="$2"
  [[ "$target" =~ ^[a-zA-Z][a-zA-Z0-9_]{0,62}$ && "$target" != "$IBSNG_DB" && "$target" != postgres && "$target" != template0 && "$target" != template1 ]] || { fail 'Choose a new database name, different from the configured database.'; exit 1; }
  verify_backup "$file" || exit 1
  exists="$(docker exec -u postgres "$IBSNG_CONTAINER" psql -X -w -d "$IBSNG_DB" -Atc "SELECT count(*) FROM pg_database WHERE datname='$target';")" || exit 1
  [[ "$exists" == 0 ]] || { fail 'The destination database already exists; it will not be overwritten.'; exit 1; }
  printf 'Import into NEW database: %s\nExisting configured database: %s\n' "$target" "$IBSNG_DB"
  echo 'SQL backups can execute SQL and psql commands. Import only your own trusted backups.'
  confirm "RESTORE $target" || exit 1
  # Keep a safety copy of the configured database before any import.
  CONFIG_FILE="$CONFIG" "$WORKER" --local || exit 1
  exec 9>"$LOCK_FILE"
  flock -n 9 || { fail 'Another backup or restore is running.'; exit 1; }
  docker exec -u postgres "$IBSNG_CONTAINER" createdb -T template0 "$target" || exit 1
  if ! gzip -dc -- "$file" | docker exec -i -u postgres "$IBSNG_CONTAINER" psql -X -w -v ON_ERROR_STOP=1 -d "$target" > /dev/null; then
    fail "Import failed. Database '$target' was retained for inspection; configuration was not switched."
    exit 1
  fi
  if ! docker exec -u postgres "$IBSNG_CONTAINER" psql -X -w -d "$target" -Atc "SELECT count(*) FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind='r' AND c.relname IN ('users','ras','admins');" | grep -qx 3; then
    fail "Import finished but IBSng schema checks failed in '$target'. Configuration was not switched."
    exit 1
  fi
  echo "Restore completed into '$target'. The configured application database remains '$IBSNG_DB'."
  echo 'Review the restored data before manually changing the IBSng application configuration.'
)
purge_backup_files() {
  python3 - "$BACKUP_DIR" "$1" <<'PY'
import pathlib, sys
directory = pathlib.Path(sys.argv[1])
if not directory.is_absolute() or directory.resolve() == pathlib.Path('/') or directory.is_symlink():
    sys.exit('ERROR: Refusing unsafe or symlinked backup directory.')
if not directory.exists():
    print('No local backup directory to remove.')
    sys.exit(0)
if not directory.is_dir():
    sys.exit('ERROR: Backup path is not a directory.')
files = [p for p in directory.iterdir()
         if (p.is_file() or p.is_symlink()) and
         (p.name.endswith(('.sql.gz', '.sql.gz.meta')) or
          p.name.startswith(('.ibsng-dump.', '.telegram-response.')))]
if sys.argv[2] == 'preview':
    print(f'Permanently delete {len(files)} local backup/metadata files in: {directory}')
else:
    for path in files:
        path.unlink()
    if not any(directory.iterdir()):
        directory.rmdir()
    print(f'Deleted {len(files)} local backup/metadata files. Unrelated files were preserved.')
PY
}
uninstall_tools() (
  local state archive
  state="$(systemctl show "$SERVICE.service" -p ActiveState --value)" || return 1
  case "$state" in active|activating|deactivating) fail 'A backup is running; retry after it finishes.'; return 1 ;; esac
  echo 'This removes the backup commands, timer and settings, including saved configuration copies.'
  purge_backup_files preview || return 1
  echo 'Local backups will be permanently deleted. The live IBSng database and Telegram messages are not deleted.'
  confirm UNINSTALL || return 1
  exec 9>"$LOCK_FILE"
  flock -n 9 || { fail 'Another backup or restore is running.'; return 1; }
  systemctl disable --now "$SERVICE.timer" || return 1
  purge_backup_files delete || return 1
  # Remove this installer's saved configuration copies as well.
  for archive in "$SNAPSHOT_ROOT"/ibsng-backup-{installer,uninstall}-*; do
    [[ -d "$archive" && ! -L "$archive" ]] || continue
    rm -f -- "$archive$CONFIG" || return 1
  done
  rm -f -- "$CONFIG" "$WORKER" "$MANAGER" "$INSTALLER" "$UNITS/$SERVICE.service" "$UNITS/$SERVICE.timer" || return 1
  systemctl daemon-reload || return 1
  echo 'Service, settings and local backup files removed. The live IBSng database was not changed.'
)
update_tools() (
  local temporary
  temporary="$(mktemp)" || exit 1
  trap 'rm -f -- "$temporary"' EXIT
  curl -fsSL --connect-timeout 20 --max-time 120 https://raw.githubusercontent.com/mehdi9087/ibsng-backup-telegram/main/install.sh -o "$temporary" || exit 1
  bash -n "$temporary" || exit 1
  bash "$temporary" --non-interactive --skip-test
)
dispatch() {
  local command="${1:-menu}" value
  shift || true
  case "$command" in
    status) show_status ;;
    backup) systemctl start "$SERVICE.service" && echo 'Backup completed. Use ibsng-backup logs for details.' ;;
    local) CONFIG_FILE="$CONFIG" "$WORKER" --local ;;
    list) list_backups ;;
    verify) [[ $# -eq 1 ]] || { fail 'Usage: ibsng-backup verify FILE.sql.gz'; return 1; }; verify_backup "$1" ;;
    restore) [[ $# -eq 2 ]] || { fail 'Usage: ibsng-backup restore FILE.sql.gz NEW_DATABASE'; return 1; }; restore_database "$1" "$2" ;;
    configure|backup-service) bash "$INSTALLER" --reconfigure ;;
    schedule)
      value="${1:-}"
      [[ -n "$value" ]] || read_input value 'Interval (e.g. 30m, 1h, 1d)' || return 1
      [[ "$value" =~ ^[1-9][0-9]{0,4}[mhd]$ ]] || { fail 'Use an interval such as 30m, 1h, or 1d.'; return 1; }
      bash "$INSTALLER" --non-interactive --skip-test --interval "$value"
      ;;
    enable) systemctl enable --now "$SERVICE.timer" ;;
    disable) systemctl disable --now "$SERVICE.timer" ;;
    logs)
      value="${1:-50}"
      [[ "$value" =~ ^[1-9][0-9]{0,3}$ ]] || { fail 'Log line count must be 1 to 9999.'; return 1; }
      journalctl -u "$SERVICE.service" -n "$value" --no-pager
      ;;
    update) update_tools ;;
    uninstall) uninstall_tools ;;
    help) usage ;;
    *) fail "Unknown command: $command" ;;
  esac
}
if [[ "${1:-menu}" != menu ]]; then dispatch "$@"; exit $?; fi
[[ -t 0 ]] || { usage; exit 0; }
while true; do
  cat <<'EOF'

IBSng Backup Manager
  1) Status and schedule
  2) Back up now (configured Telegram delivery)
  3) Create a local backup only
  4) Configure backup service and Telegram
  5) Change backup interval
  6) List local backups
  7) Verify a backup file
  8) Restore a backup into a NEW database
  9) Enable automatic backups
 10) Disable automatic backups
 11) View recent logs
 12) Update backup tools
 13) Uninstall service, settings and local backups
  0) Exit
EOF
  read_input choice 'Select an option' || exit 1
  case "$choice" in
    1) action=(status) ;; 2) action=(backup) ;; 3) action=(local) ;;
    4) action=(configure) ;; 5) action=(schedule) ;; 6) action=(list) ;;
    7) read_input file 'Backup file path' || continue; action=(verify "$file") ;;
    8) read_input file 'Trusted backup file path' || continue; read_input database 'New database name' || continue; action=(restore "$file" "$database") ;;
    9) action=(enable) ;; 10) action=(disable) ;; 11) action=(logs) ;;
    12) action=(update) ;; 13) dispatch uninstall && exit 0; continue ;;
    0) exit 0 ;; *) echo 'Invalid selection.'; continue ;;
  esac
  # Run actions in a child shell so errors cannot close the menu and settings refresh.
  if ! bash "$MANAGER" "${action[@]}"; then echo 'Action failed. Check the message above.'; fi
done
IBSNG_MANAGER_EOF
}
write_worker "$STAGE/backup.sh"
bash -n "$STAGE/backup.sh"
write_manager "$STAGE/manager.sh"
bash -n "$STAGE/manager.sh"
if [[ -n "$EXTRACT" ]]; then
  mkdir -p "$EXTRACT"
  install -m 700 "$STAGE/backup.sh" "$EXTRACT/backup.sh"
  install -m 700 "$STAGE/manager.sh" "$EXTRACT/manager.sh"
  echo "Backup and management programs extracted to $EXTRACT"
  exit 0
fi
[[ "$EUID" -eq 0 ]] || fail 'Run as root (sudo bash install.sh).'
command -v systemctl >/dev/null && [[ -d /run/systemd/system ]] || fail 'Requires Linux with systemd.'
command -v docker >/dev/null || fail 'Install and start your Docker-based IBSng first.'
docker info >/dev/null 2>&1 || fail 'Docker is unavailable.'
if [[ -f "$CONFIG" && "$RECONFIGURE" == false && "$DETECT_ONLY" == false && -z "$CONTAINER_OVERRIDE" && -z "$DATABASE_OVERRIDE" && -z "$INTERVAL_OVERRIDE" ]]; then
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
BACKUP_INTERVAL="${BACKUP_INTERVAL:-${INTERVAL_HOURS}h}"
[[ -z "$INTERVAL_OVERRIDE" ]] || BACKUP_INTERVAL="$INTERVAL_OVERRIDE"
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
  prompt BACKUP_INTERVAL 'Backup interval (e.g. 30m, 1h, 1d)'
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
[[ "$BACKUP_INTERVAL" =~ ^[1-9][0-9]{0,4}[mhd]$ ]] || fail 'Interval must be a positive number followed by m, h, or d (e.g. 30m, 1h, 1d).'
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
  for variable in IBSNG_CONTAINER IBSNG_DB BACKUP_DIR RETENTION_HOURS INTERVAL_HOURS BACKUP_INTERVAL HOST_LABEL TELEGRAM_SEND TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID TELEGRAM_API_BASE TELEGRAM_DISABLE_NOTIFICATION LOCK_FILE; do
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
  if [[ "$BACKUP_INTERVAL" == 1h ]]; then
    SCHEDULE=$'OnCalendar=hourly\nPersistent=true\nAccuracySec=1min'
  else
    SCHEDULE="OnBootSec=5min
OnUnitActiveSec=$BACKUP_INTERVAL
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
[[ -f "${BASH_SOURCE[0]}" ]] || fail 'Download install.sh to a file before running it.'
cp -- "${BASH_SOURCE[0]}" "$STAGE/install.sh"
# Back up every file before replacing anything. Keep backups root-only.
SNAPSHOT="$(mktemp -d /var/backups/ibsng-backup-installer-XXXXXXXX)"
chmod 700 "$SNAPSHOT"
for original in "$CONFIG" "$BIN" "$MANAGER" "$OFFLINE_INSTALLER" "$UNITS/$SERVICE.service" "$UNITS/$SERVICE.timer"; do
  [[ ! -e "$original" ]] || cp -a --parents "$original" "$SNAPSHOT/"
done
echo "Previous installation saved to $SNAPSHOT"
WAS_ACTIVE=false
WAS_ENABLED=false
EXISTING_INSTALL=false
[[ ! -f "$UNITS/$SERVICE.timer" ]] || EXISTING_INSTALL=true
systemctl is-active --quiet "$SERVICE.timer" && WAS_ACTIVE=true
systemctl is-enabled --quiet "$SERVICE.timer" && WAS_ENABLED=true
MUTATING=false
rollback() {
  local status=$?
  trap - ERR
  if [[ "$MUTATING" == true ]]; then
    echo 'Installation failed; restoring previous files and timer state.' >&2
    systemctl stop "$SERVICE.timer" || true
    for original in "$CONFIG" "$BIN" "$MANAGER" "$OFFLINE_INSTALLER" "$UNITS/$SERVICE.service" "$UNITS/$SERVICE.timer"; do
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
install -D -m 700 "$STAGE/manager.sh" "$MANAGER"
install -D -m 700 "$STAGE/install.sh" "$OFFLINE_INSTALLER"
install -m 644 "$STAGE/$SERVICE.service" "$UNITS/$SERVICE.service"
install -m 644 "$STAGE/$SERVICE.timer" "$UNITS/$SERVICE.timer"
systemctl daemon-reload
if [[ "$SKIP_TEST" == false ]]; then
  echo 'Creating the first backup (and sending it to Telegram if enabled)...'
  systemctl start "$SERVICE.service"
fi
if [[ "$EXISTING_INSTALL" == true ]]; then
  if [[ "$WAS_ENABLED" == true ]]; then systemctl enable "$SERVICE.timer"; else systemctl disable "$SERVICE.timer"; fi
  if [[ "$WAS_ACTIVE" == true ]]; then systemctl start "$SERVICE.timer"; else systemctl stop "$SERVICE.timer"; fi
else
  systemctl enable --now "$SERVICE.timer"
  systemctl is-active --quiet "$SERVICE.timer"
fi
trap - ERR
echo "Installed IBSng backup $VERSION successfully."
echo 'Management menu: ibsng-backup'
echo "Status: systemctl status $SERVICE.timer"
echo "Run now: systemctl start $SERVICE.service"
echo "Logs: journalctl -u $SERVICE.service -n 50 --no-pager"
