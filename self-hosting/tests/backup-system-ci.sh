#!/usr/bin/env bash
# End-to-end validation of the production self-host backup lifecycle.

set -Eeuo pipefail

SELF_HOST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SELF_HOST_DIR"

COMPOSE=(docker compose -f docker-compose.yml -f docker-compose.traefik.yml)
BACKUP_DIR="${BACKUP_DIR:?BACKUP_DIR must be exported by the CI workflow}"

cleanup() {
  local status=$?
  if [[ "$status" -ne 0 ]]; then
    echo "Backup-system test failed. Recent container logs:" >&2
    "${COMPOSE[@]}" ps >&2 || true
    "${COMPOSE[@]}" logs --tail 150 backend db frontend traefik >&2 || true
  fi
  "${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
  rm -rf -- "$BACKUP_DIR"
  exit "$status"
}
trap cleanup EXIT INT TERM

echo "Starting the production-style stack..."
"${COMPOSE[@]}" config --quiet
"${COMPOSE[@]}" up -d --wait --wait-timeout 240

echo "Seeding database and attachment probes..."
"${COMPOSE[@]}" exec -T db sh -c \
  'psql --set ON_ERROR_STOP=on -U "$POSTGRES_USER" -d "$POSTGRES_DB"' <<'SQL'
CREATE TABLE ci_backup_probe (id integer PRIMARY KEY, marker text NOT NULL);
INSERT INTO ci_backup_probe (id, marker) VALUES (1, 'before-backup');
SQL
"${COMPOSE[@]}" exec -T backend sh -c \
  'printf %s before-backup > /app/packages/backend/data/attachments/ci-backup-probe.txt'

echo "Creating and internally validating a backup..."
bash manage.sh backup ci
backup_name="$(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -name '20????????????-ci' -printf '%f\n')"
[[ -n "$backup_name" ]] || { echo "No CI backup was created" >&2; exit 1; }
grep -qx 'validation=sha256,gzip,tar-list,database-restore' "$BACKUP_DIR/$backup_name/metadata.txt"

echo "Mutating production data, then restoring the backup..."
"${COMPOSE[@]}" exec -T db sh -c \
  'psql --set ON_ERROR_STOP=on -U "$POSTGRES_USER" -d "$POSTGRES_DB"' <<'SQL'
UPDATE ci_backup_probe SET marker = 'after-backup' WHERE id = 1;
SQL
"${COMPOSE[@]}" exec -T backend sh -c \
  'printf %s after-backup > /app/packages/backend/data/attachments/ci-backup-probe.txt'

printf 'RESTORE\n' | bash manage.sh restore "$backup_name"
database_marker="$("${COMPOSE[@]}" exec -T db sh -c \
  'psql --tuples-only --no-align -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT marker FROM ci_backup_probe WHERE id = 1"')"
[[ "$database_marker" == "before-backup" ]] || { echo "Database restore probe failed: $database_marker" >&2; exit 1; }
attachment_marker="$("${COMPOSE[@]}" exec -T backend cat /app/packages/backend/data/attachments/ci-backup-probe.txt)"
[[ "$attachment_marker" == "before-backup" ]] || { echo "Attachment restore probe failed: $attachment_marker" >&2; exit 1; }

echo "Proving a corrupt but re-checksummed dump is rejected before restore..."
corrupt_name="20990101000000-corrupt"
cp -a "$BACKUP_DIR/$backup_name" "$BACKUP_DIR/$corrupt_name"
gunzip "$BACKUP_DIR/$corrupt_name/database.sql.gz"
printf '\nTHIS IS DELIBERATELY INVALID SQL;\n' >> "$BACKUP_DIR/$corrupt_name/database.sql"
gzip -9 "$BACKUP_DIR/$corrupt_name/database.sql"
(
  cd "$BACKUP_DIR/$corrupt_name"
  sha256sum database.sql.gz production.env metadata.txt attachments* > SHA256SUMS
)
if printf 'RESTORE\n' | bash manage.sh restore "$corrupt_name"; then
  echo "Corrupt backup was accepted" >&2
  exit 1
fi
database_marker="$("${COMPOSE[@]}" exec -T db sh -c \
  'psql --tuples-only --no-align -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT marker FROM ci_backup_probe WHERE id = 1"')"
[[ "$database_marker" == "before-backup" ]] || { echo "Corrupt restore changed production data" >&2; exit 1; }

echo "Testing one-backup-per-unit tiered retention..."
retention_dir="$(mktemp -d)"
retention_names=(
  20261010040000-newest
  20261010031500-same-day
  20261009031500-daily
  20261008031500-daily
  20261001031500-weekly
  20260924031500-weekly-monthly
  20260917031500-weekly
  20260915031500-same-week
  20260815031500-monthly
  20260715031500-monthly
  20260615031500-monthly
  20260515031500-monthly
  20260415031500-monthly
  20260315031500-monthly
  20260215031500-monthly
  20260115031500-monthly
  20251215031500-monthly
  20251115031500-monthly
  20251015031500-expired
)
for name in "${retention_names[@]}"; do
  mkdir "$retention_dir/$name"
done

(
  set -- help
  # Load the actual retention function without performing a management action.
  # shellcheck disable=SC1091
  source "$SELF_HOST_DIR/manage.sh" >/dev/null
  BACKUP_DIR="$retention_dir"
  BACKUP_RETENTION_MODE=tiered
  BACKUP_KEEP_DAILY=3
  BACKUP_KEEP_WEEKLY=4
  BACKUP_KEEP_MONTHLY=12
  prune_backups
)

expected_names=(
  20261010040000-newest
  20261009031500-daily
  20261008031500-daily
  20261001031500-weekly
  20260924031500-weekly-monthly
  20260917031500-weekly
  20260815031500-monthly
  20260715031500-monthly
  20260615031500-monthly
  20260515031500-monthly
  20260415031500-monthly
  20260315031500-monthly
  20260215031500-monthly
  20260115031500-monthly
  20251215031500-monthly
  20251115031500-monthly
)
actual_names="$(find "$retention_dir" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)"
expected_sorted="$(printf '%s\n' "${expected_names[@]}" | sort)"
[[ "$actual_names" == "$expected_sorted" ]] || {
  echo "Tiered retention produced an unexpected set" >&2
  diff -u <(printf '%s\n' "$expected_sorted") <(printf '%s\n' "$actual_names") || true
  exit 1
}
rm -rf -- "$retention_dir"

echo "Backup creation, validation, restore, corruption rejection, and retention all passed."
