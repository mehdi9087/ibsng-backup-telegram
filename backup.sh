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
