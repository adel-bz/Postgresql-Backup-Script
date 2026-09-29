#!/usr/bin/env bash
set -Eeuo pipefail

# Run on the Docker host. Settings are loaded from a root-owned .env file.
umask 077

env_file="${BACKUP_ENV_FILE:-/etc/postgresql-backup/.env}"
if [[ ! -f "$env_file" || ! -r "$env_file" ]]; then
  echo "Cannot read backup settings: $env_file" >&2
  exit 1
fi
if [[ "$EUID" -ne 0 || ! -O "$env_file" ]]; then
  echo "Run as root with a root-owned .env file: $env_file" >&2
  exit 1
fi
env_mode="$(stat -c %a "$env_file")"
if (( (8#$env_mode & 077) != 0 )); then
  echo "The .env file must not be readable or writable by group or others" >&2
  exit 1
fi

set -a
# shellcheck source=/dev/null
source "$env_file"
set +a

# Discord is optional. Notification failures never change the backup result.
backup_start_seconds="$SECONDS"
backup_stage="configuration"
workdir=""

send_discord_status() {
  local result="$1" duration="$2"
  if [[ "${DISCORD_ALERT_ENABLED:-false}" != "true" || -z "${DISCORD_WEBHOOK_URL:-}" ]]; then
    return 0
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "Discord notification skipped: python3 is not installed" >&2
    return 0
  fi

  python3 - "$result" "$duration" "$backup_stage" "${DATABASE_NAME:-unknown}" \
    "${S3_BUCKET:-unknown}" "${key:-}" "${local_size:-0}" <<'PY'
import datetime
import json
import os
import re
import socket
import sys
import urllib.error
import urllib.parse
import urllib.request

result, duration, stage, database, bucket, key, size = sys.argv[1:]
try:
    url = urllib.parse.urlsplit(os.environ["DISCORD_WEBHOOK_URL"])
    hosts = {"discord.com", "discordapp.com", "canary.discord.com", "ptb.discord.com"}
    if (url.scheme != "https" or url.netloc not in hosts
            or not re.fullmatch(r"/api(?:/v[0-9]+)?/webhooks/[0-9]+/[A-Za-z0-9._-]+/?", url.path)):
        raise ValueError("Invalid Discord webhook")
    query = [(k, v) for k, v in urllib.parse.parse_qsl(url.query) if k != "wait"]
    query.append(("wait", "true"))
    endpoint = urllib.parse.urlunsplit(url._replace(query=urllib.parse.urlencode(query), fragment=""))
    succeeded = result == "0"
    lines = [
        "PostgreSQL backup " + ("SUCCEEDED" if succeeded else "FAILED"),
        "Host: " + socket.gethostname(),
        "Database: " + database,
        "Completed (UTC): " + datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "Duration: " + duration + " seconds",
    ]
    if succeeded:
        lines.extend(["Object: s3://" + bucket + "/" + key, "Size: " + size + " bytes"])
    else:
        lines.extend(["Stage: " + stage, "Exit status: " + result,
                      "Details: journalctl -u postgresql-backup.service"])
    payload = json.dumps({
        "content": "\n".join(lines)[:2000],
        "allowed_mentions": {"parse": []},
    }).encode("utf-8")
    request = urllib.request.Request(endpoint, data=payload, method="POST", headers={
        "Content-Type": "application/json",
        "User-Agent": "PostgreSQLBackup/1.0",
    })
    with urllib.request.urlopen(request, timeout=10) as response:
        response.read()
    print("Discord notification sent")
except urllib.error.HTTPError as error:
    print("Discord notification failed (HTTP " + str(error.code) + "); backup result unchanged", file=sys.stderr)
    sys.exit(1)
except Exception:
    # Do not print exception details: they can contain the secret webhook URL.
    print("Discord notification failed; backup result unchanged", file=sys.stderr)
    sys.exit(1)
PY
}

finish_backup() {
  local result="$?"
  trap - EXIT
  if [[ -n "$workdir" ]]; then
    rm -rf -- "$workdir" || echo "Could not remove temporary backup directory" >&2
  fi
  send_discord_status "$result" "$((SECONDS - backup_start_seconds))" || true
  exit "$result"
}

trap finish_backup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

: "${S3_BUCKET:?Set S3_BUCKET in the .env file}"
: "${AWS_REGION:?Set AWS_REGION in the .env file}"
: "${CONTAINER_NAME:?Set CONTAINER_NAME in the .env file}"
: "${DATABASE_NAME:?Set DATABASE_NAME in the .env file}"
: "${LOCK_FILE:?Set LOCK_FILE in the .env file}"
: "${BACKUP_TMPDIR:?Set BACKUP_TMPDIR in the .env file}"
: "${NICE_LEVEL:?Set NICE_LEVEL in the .env file}"
if [[ ! "$NICE_LEVEL" =~ ^([0-9]|1[0-9])$ ]]; then
  echo "NICE_LEVEL must be an integer from 0 to 19" >&2
  exit 1
fi

backup_stage="prerequisites"
for program in docker aws flock mktemp stat sha256sum renice; do
  if ! command -v "$program" >/dev/null 2>&1; then
    echo "Missing required command: $program" >&2
    exit 1
  fi
done

# Set the host script and its child commands to the requested CPU priority.
backup_stage="CPU priority"
renice --priority "$NICE_LEVEL" --pid "$$" >/dev/null

backup_stage="backup lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "A PostgreSQL backup is already running" >&2
  exit 1
fi

backup_stage="container check"
if [[ "$(docker inspect --format '{{.State.Running}}' "$CONTAINER_NAME")" != "true" ]]; then
  echo "Database container is not running: $CONTAINER_NAME" >&2
  exit 1
fi

backup_stage="PostgreSQL readiness"
docker exec --user postgres "$CONTAINER_NAME" pg_isready -U postgres -d "$DATABASE_NAME" >/dev/null
backup_stage="AWS authentication"
if ! aws --region "$AWS_REGION" sts get-caller-identity --query Account --output text >/dev/null; then
  echo "AWS authentication failed; check the credentials loaded from $env_file" >&2
  exit 1
fi

backup_stage="temporary directory"
workdir="$(mktemp -d "$BACKUP_TMPDIR/postgresql-backup.XXXXXXXX")"

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
filename="postgresql_${timestamp}_$$.dump"
archive="$workdir/$filename"
# One object per UTC calendar day, named year-day-month.
key="database/${timestamp:0:4}-${timestamp:6:2}-${timestamp:4:2}.dump"

echo "Creating PostgreSQL backup: $filename"
backup_stage="database dump"
docker exec --user postgres "$CONTAINER_NAME" \
  nice -n "$NICE_LEVEL" pg_dump --username postgres --dbname "$DATABASE_NAME" --format custom \
  --no-owner --no-acl >"$archive"

if [[ ! -s "$archive" ]]; then
  echo "Backup file is empty" >&2
  exit 1
fi

# Confirm that PostgreSQL can read the archive directory before upload.
backup_stage="archive validation"
docker exec --interactive --user postgres "$CONTAINER_NAME" \
  pg_restore --list <"$archive" >/dev/null

local_size="$(stat -c %s "$archive")"
local_sha256="$(sha256sum "$archive")"
local_sha256="${local_sha256%% *}"

echo "Uploading to s3://$S3_BUCKET/$key"
backup_stage="S3 upload"
aws --region "$AWS_REGION" s3 cp "$archive" "s3://$S3_BUCKET/$key" \
  --only-show-errors --sse AES256 --metadata "sha256=$local_sha256"

backup_stage="S3 metadata verification"
remote_size="$(aws --region "$AWS_REGION" s3api head-object \
  --bucket "$S3_BUCKET" --key "$key" --query ContentLength --output text)"
remote_sha256="$(aws --region "$AWS_REGION" s3api head-object \
  --bucket "$S3_BUCKET" --key "$key" --query 'Metadata.sha256' --output text)"

if [[ "$remote_size" != "$local_size" || "$remote_sha256" != "$local_sha256" ]]; then
  echo "Uploaded object metadata does not match local backup" >&2
  exit 1
fi

# Hash the retrieved bytes; user-supplied metadata alone does not prove integrity.
backup_stage="S3 content verification"
downloaded_archive="$workdir/verified.dump"
aws --region "$AWS_REGION" s3api get-object \
  --bucket "$S3_BUCKET" --key "$key" "$downloaded_archive" >/dev/null
downloaded_size="$(stat -c %s "$downloaded_archive")"
downloaded_sha256="$(sha256sum "$downloaded_archive")"
downloaded_sha256="${downloaded_sha256%% *}"

if [[ "$downloaded_size" != "$local_size" || "$downloaded_sha256" != "$local_sha256" ]]; then
  echo "Downloaded S3 object content does not match local backup" >&2
  exit 1
fi

echo "Backup complete: s3://$S3_BUCKET/$key ($local_size bytes)"
