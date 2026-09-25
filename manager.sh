#!/usr/bin/env bash
# Interactive and command-line management for IBSng database backups.
set -Eeuo pipefail
umask 077
VERSION=1.2.1
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
  uninstall                    Remove service and settings; keep backup files
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
uninstall_tools() (
  local state archive
  state="$(systemctl show "$SERVICE.service" -p ActiveState --value)" || return 1
  case "$state" in active|activating|deactivating) fail 'A backup is running; retry after it finishes.'; return 1 ;; esac
  echo 'This removes the backup commands, timer and settings, including saved configuration copies.'
  echo 'Database backup files are kept. Telegram credentials must be entered again after reinstalling.'
  confirm UNINSTALL || return 1
  exec 9>"$LOCK_FILE"
  flock -n 9 || { fail 'Another backup or restore is running.'; return 1; }
  systemctl disable --now "$SERVICE.timer" || return 1
  # Remove only this installer's configuration copies, never database backups.
  for archive in "$SNAPSHOT_ROOT"/ibsng-backup-{installer,uninstall}-*; do
    [[ -d "$archive" && ! -L "$archive" ]] || continue
    rm -f -- "$archive$CONFIG" || return 1
  done
  rm -f -- "$CONFIG" "$WORKER" "$MANAGER" "$INSTALLER" "$UNITS/$SERVICE.service" "$UNITS/$SERVICE.timer" || return 1
  systemctl daemon-reload || return 1
  echo "Service and settings removed. Database backup files kept in: $BACKUP_DIR"
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
 13) Uninstall service and settings (keep backup files)
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
