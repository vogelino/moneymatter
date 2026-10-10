#!/usr/bin/env bash
# Production lifecycle for a Docker Compose MoneyMatter installation.

set -Eeuo pipefail
umask 077

SELF_HOST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SELF_HOST_DIR"

ENV_FILE="$SELF_HOST_DIR/.env"
[[ -f "$ENV_FILE" ]] || { echo "error: $ENV_FILE is missing" >&2; exit 1; }

# Read the dotenv file as data, not shell code. Compose loads the same file for
# the containers. Management values are deliberately simple, unquoted values.
read_env() {
  grep -E "^$1=" "$ENV_FILE" | tail -1 | cut -d= -f2- || true
}

BACKUP_DIR="$(read_env BACKUP_DIR)"
BACKUP_KEEP="$(read_env BACKUP_KEEP)"
BACKUP_KEEP_DAILY="$(read_env BACKUP_KEEP_DAILY)"
BACKUP_KEEP_WEEKLY="$(read_env BACKUP_KEEP_WEEKLY)"
BACKUP_KEEP_MONTHLY="$(read_env BACKUP_KEEP_MONTHLY)"
MANAGEMENT_HEALTH_TIMEOUT="$(read_env MANAGEMENT_HEALTH_TIMEOUT)"
MANAGEMENT_BUILD_FROM_SOURCE="$(read_env MANAGEMENT_BUILD_FROM_SOURCE)"
MANAGEMENT_USE_TRAEFIK="$(read_env MANAGEMENT_USE_TRAEFIK)"
MANAGEMENT_EXTRA_COMPOSE_FILE="$(read_env MANAGEMENT_EXTRA_COMPOSE_FILE)"

BACKUP_DIR="${BACKUP_DIR:-$SELF_HOST_DIR/backups}"
MANAGEMENT_HEALTH_TIMEOUT="${MANAGEMENT_HEALTH_TIMEOUT:-180}"
MANAGEMENT_BUILD_FROM_SOURCE="${MANAGEMENT_BUILD_FROM_SOURCE:-false}"
MANAGEMENT_USE_TRAEFIK="${MANAGEMENT_USE_TRAEFIK:-false}"

[[ "$BACKUP_DIR" == /* ]] || BACKUP_DIR="$SELF_HOST_DIR/$BACKUP_DIR"
[[ "$BACKUP_DIR" != "/" ]] || { echo "error: BACKUP_DIR cannot be /" >&2; exit 1; }

# Tiered retention is the default. BACKUP_KEEP remains supported for existing
# installations, but the tier settings take precedence when any is present.
if [[ -n "$BACKUP_KEEP_DAILY$BACKUP_KEEP_WEEKLY$BACKUP_KEEP_MONTHLY" || -z "$BACKUP_KEEP" ]]; then
  BACKUP_RETENTION_MODE=tiered
  BACKUP_KEEP_DAILY="${BACKUP_KEEP_DAILY:-3}"
  BACKUP_KEEP_WEEKLY="${BACKUP_KEEP_WEEKLY:-4}"
  BACKUP_KEEP_MONTHLY="${BACKUP_KEEP_MONTHLY:-12}"
  for retention_value in "$BACKUP_KEEP_DAILY" "$BACKUP_KEEP_WEEKLY" "$BACKUP_KEEP_MONTHLY"; do
    [[ "$retention_value" =~ ^[0-9]+$ ]] || { echo "error: tiered backup retention values must be numbers" >&2; exit 1; }
  done
  ((BACKUP_KEEP_DAILY + BACKUP_KEEP_WEEKLY + BACKUP_KEEP_MONTHLY > 0)) || \
    { echo "error: at least one backup retention tier must be greater than zero" >&2; exit 1; }
else
  BACKUP_RETENTION_MODE=count
  [[ "$BACKUP_KEEP" =~ ^[0-9]+$ ]] || { echo "error: BACKUP_KEEP must be a number" >&2; exit 1; }
  ((BACKUP_KEEP > 0)) || { echo "error: BACKUP_KEEP must be greater than zero" >&2; exit 1; }
fi
[[ "$MANAGEMENT_HEALTH_TIMEOUT" =~ ^[0-9]+$ ]] || { echo "error: MANAGEMENT_HEALTH_TIMEOUT must be a number" >&2; exit 1; }
((MANAGEMENT_HEALTH_TIMEOUT > 0)) || { echo "error: MANAGEMENT_HEALTH_TIMEOUT must be greater than zero" >&2; exit 1; }
[[ "$MANAGEMENT_BUILD_FROM_SOURCE" == "true" || "$MANAGEMENT_BUILD_FROM_SOURCE" == "false" ]] || \
  { echo "error: MANAGEMENT_BUILD_FROM_SOURCE must be true or false" >&2; exit 1; }
[[ "$MANAGEMENT_USE_TRAEFIK" == "true" || "$MANAGEMENT_USE_TRAEFIK" == "false" ]] || \
  { echo "error: MANAGEMENT_USE_TRAEFIK must be true or false" >&2; exit 1; }
if [[ -n "$MANAGEMENT_EXTRA_COMPOSE_FILE" ]]; then
  [[ "$MANAGEMENT_EXTRA_COMPOSE_FILE" =~ ^docker-compose\.[a-zA-Z0-9][a-zA-Z0-9._-]*\.ya?ml$ ]] || \
    { echo "error: MANAGEMENT_EXTRA_COMPOSE_FILE must be a docker-compose.*.yml file in self-hosting/" >&2; exit 1; }
  [[ -f "$SELF_HOST_DIR/$MANAGEMENT_EXTRA_COMPOSE_FILE" ]] || \
    { echo "error: management Compose overlay does not exist: $MANAGEMENT_EXTRA_COMPOSE_FILE" >&2; exit 1; }
fi

COMPOSE_ARGS=(-f docker-compose.yml)
[[ "$MANAGEMENT_USE_TRAEFIK" == "true" ]] && COMPOSE_ARGS+=(-f docker-compose.traefik.yml)
[[ "$MANAGEMENT_BUILD_FROM_SOURCE" == "true" ]] && COMPOSE_ARGS+=(-f docker-compose.build.yml)
[[ -n "$MANAGEMENT_EXTRA_COMPOSE_FILE" ]] && COMPOSE_ARGS+=(-f "$MANAGEMENT_EXTRA_COMPOSE_FILE")

compose() {
  docker compose "${COMPOSE_ARGS[@]}" "$@"
}

die() {
  echo "error: $*" >&2
  exit 1
}

require_running_db() {
  compose up -d db >/dev/null
  local attempt
  for attempt in $(seq 1 30); do
    if compose exec -T db sh -c 'pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB"' >/dev/null 2>&1; then
      return
    fi
    sleep 1
  done
  die "Postgres did not become ready"
}

wait_for_stack() {
  if ! compose up -d --remove-orphans --wait --wait-timeout "$MANAGEMENT_HEALTH_TIMEOUT"; then
    echo "Deployment did not become healthy. Recent logs:" >&2
    compose ps >&2 || true
    compose logs --tail 100 backend frontend >&2 || true
    return 1
  fi
}

safe_label() {
  local label="${1:-manual}"
  [[ "$label" =~ ^[a-zA-Z0-9._-]+$ ]] || die "backup label may only contain letters, numbers, dots, underscores, and hyphens"
  printf '%s' "$label"
}

prune_backups() {
  mapfile -t backups < <(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -name '20????????????-*' -print | sort -r)
  local index path name timestamp day month week

  if [[ "$BACKUP_RETENTION_MODE" == "count" ]]; then
    for ((index=BACKUP_KEEP; index<${#backups[@]}; index++)); do
      path="${backups[$index]}"
      [[ "$path" == "$BACKUP_DIR"/20????????????-* ]] || die "refusing to prune unexpected path: $path"
      rm -rf -- "$path"
      echo "Pruned old backup: $(basename "$path")"
    done
    return
  fi

  # Process newest first so each bucket retains exactly its newest backup.
  # A path kept by several tiers is stored once and satisfies all of them.
  declare -A keep=() seen_days=() seen_weeks=() seen_months=()
  local daily_count=0 weekly_count=0 monthly_count=0
  for path in "${backups[@]}"; do
    name="$(basename "$path")"
    timestamp="${name%%-*}"
    day="${timestamp:0:8}"
    month="${timestamp:0:6}"
    week="$(date -u -d "${day:0:4}-${day:4:2}-${day:6:2}" +%G-W%V)"

    if ((daily_count < BACKUP_KEEP_DAILY)) && [[ -z "${seen_days[$day]:-}" ]]; then
      seen_days[$day]=1
      keep[$path]=1
      ((daily_count += 1))
    fi
    if ((weekly_count < BACKUP_KEEP_WEEKLY)) && [[ -z "${seen_weeks[$week]:-}" ]]; then
      seen_weeks[$week]=1
      keep[$path]=1
      ((weekly_count += 1))
    fi
    if ((monthly_count < BACKUP_KEEP_MONTHLY)) && [[ -z "${seen_months[$month]:-}" ]]; then
      seen_months[$month]=1
      keep[$path]=1
      ((monthly_count += 1))
    fi
  done

  for path in "${backups[@]}"; do
    [[ -n "${keep[$path]:-}" ]] && continue
    [[ "$path" == "$BACKUP_DIR"/20????????????-* ]] || die "refusing to prune unexpected path: $path"
    rm -rf -- "$path"
    echo "Pruned backup outside retention tiers: $(basename "$path")"
  done
}

verify_backup_files() {
  local directory="$1"

  echo "Verifying compressed files and checksums..."
  gzip -t "$directory/database.sql.gz"
  if [[ -f "$directory/attachments.tar.gz" ]]; then
    gzip -t "$directory/attachments.tar.gz"
    compose run --rm --no-deps -T --entrypoint sh backend \
      -c 'tar tzf - >/dev/null' < "$directory/attachments.tar.gz"
  fi
  (cd "$directory" && sha256sum --check SHA256SUMS)
}

verify_database_restore() {
  local dump_file="$1" verification_db status
  verification_db="moneymatter_backup_verify_$(date -u +%Y%m%d%H%M%S)_$$"

  echo "Verifying database dump with a temporary restore..."
  compose exec -T db sh -c 'createdb -U "$POSTGRES_USER" "$1"' sh "$verification_db"
  status=0
  gunzip -c "$dump_file" | compose exec -T db \
    sh -c 'psql --quiet --set ON_ERROR_STOP=on -U "$POSTGRES_USER" -d "$1"' sh "$verification_db" || status=$?
  compose exec -T db sh -c 'dropdb --if-exists --force -U "$POSTGRES_USER" "$1"' sh "$verification_db" || true

  [[ "$status" -eq 0 ]] || die "database verification restore failed"
}

create_backup() {
  local label timestamp final_dir temp_dir should_prune image_tag
  label="$(safe_label "${1:-manual}")"
  should_prune="${2:-true}"
  image_tag="$(read_env IMAGE_TAG)"
  timestamp="$(date -u +%Y%m%d%H%M%S)"
  final_dir="$BACKUP_DIR/$timestamp-$label"
  temp_dir="$BACKUP_DIR/.$timestamp-$label.tmp"

  mkdir -p "$BACKUP_DIR"
  [[ ! -e "$final_dir" && ! -e "$temp_dir" ]] || die "backup already exists: $final_dir"
  mkdir "$temp_dir"

  cleanup_incomplete() {
    [[ -d "$temp_dir" ]] && rm -rf -- "$temp_dir"
  }
  trap cleanup_incomplete EXIT INT TERM

  require_running_db
  echo "Backing up Postgres..."
  compose exec -T db sh -c 'pg_dump --clean --if-exists -U "$POSTGRES_USER" "$POSTGRES_DB"' | gzip -9 > "$temp_dir/database.sql.gz"

  if [[ -z "$(read_env ATTACHMENTS_S3_BUCKET)" ]]; then
    echo "Backing up attachments..."
    compose run --rm --no-deps -T --entrypoint sh backend \
      -c 'tar czf - -C /app/packages/backend/data/attachments .' > "$temp_dir/attachments.tar.gz"
  else
    printf '%s\n' "Attachments use S3-compatible storage and are not copied by this server backup." > "$temp_dir/attachments-in-s3.txt"
  fi

  cp "$ENV_FILE" "$temp_dir/production.env"
  {
    echo "created_utc=$timestamp"
    echo "label=$label"
    echo "image_tag=${image_tag:-latest}"
    echo "git_revision=$(git -C "$SELF_HOST_DIR/.." rev-parse HEAD 2>/dev/null || echo unavailable)"
    echo "validation=sha256,gzip,tar-list,database-restore"
  } > "$temp_dir/metadata.txt"

  (cd "$temp_dir" && sha256sum database.sql.gz production.env metadata.txt attachments* > SHA256SUMS)
  verify_backup_files "$temp_dir"
  verify_database_restore "$temp_dir/database.sql.gz"

  # The final directory name only appears after every validation succeeds.
  # Monitoring or sync jobs therefore never see a partially written backup.
  mv "$temp_dir" "$final_dir"
  trap - EXIT INT TERM
  echo "Backup created: $final_dir"
  [[ "$should_prune" == "true" ]] && prune_backups
}

resolve_backup() {
  local name="$1"
  [[ "$name" =~ ^20[0-9]{12}-[a-zA-Z0-9._-]+$ ]] || die "invalid backup name; use a name shown by 'backups'"
  RESTORE_DIR="$BACKUP_DIR/$name"
  [[ -d "$RESTORE_DIR" ]] || die "backup not found: $name"
  [[ -f "$RESTORE_DIR/database.sql.gz" ]] || die "database.sql.gz is missing from $name"
  [[ -f "$RESTORE_DIR/SHA256SUMS" ]] || die "SHA256SUMS is missing from $name"
}

restore_backup() {
  local name="$1" answer
  resolve_backup "$name"
  # Keep the caller's stdin intact for the explicit confirmation below.
  # Commands inside these checks provide their own input where required.
  require_running_db </dev/null
  verify_backup_files "$RESTORE_DIR" </dev/null
  verify_database_restore "$RESTORE_DIR/database.sql.gz" </dev/null

  echo "This replaces the production database and local attachments with: $name"
  if ! read -r -p "Type RESTORE to continue: " answer; then
    die "restore confirmation was not received"
  fi
  [[ "$answer" == "RESTORE" ]] || { echo "Restore cancelled."; return; }

  # Do not prune here: if an intentionally selected old backup is just outside
  # the retention window, creating the safety backup must not delete it before
  # it can be restored.
  create_backup "pre-restore" false
  compose stop backend frontend >/dev/null || true

  echo "Restoring Postgres..."
  compose exec -T db sh -c 'dropdb --if-exists --force -U "$POSTGRES_USER" "$POSTGRES_DB" && createdb -U "$POSTGRES_USER" "$POSTGRES_DB"'
  gunzip -c "$RESTORE_DIR/database.sql.gz" | compose exec -T db \
    sh -c 'psql --quiet --set ON_ERROR_STOP=on -U "$POSTGRES_USER" "$POSTGRES_DB"'

  if [[ -f "$RESTORE_DIR/attachments.tar.gz" ]]; then
    echo "Restoring attachments..."
    compose run --rm --no-deps -T --entrypoint sh backend \
      -c 'find /app/packages/backend/data/attachments -mindepth 1 -delete'
    gunzip -c "$RESTORE_DIR/attachments.tar.gz" | compose run --rm --no-deps -T --entrypoint sh backend \
      -c 'tar xf - -C /app/packages/backend/data/attachments'
  fi

  wait_for_stack
  echo "Restore complete and the stack is healthy."
}

install_backup_cron() {
  command -v crontab >/dev/null || die "crontab is not installed on this server"
  local marker="# moneymatter-managed-backup" current temp
  mkdir -p "$BACKUP_DIR"
  temp="$(mktemp)"
  current="$(crontab -l 2>/dev/null || true)"
  printf '%s\n' "$current" | grep -vF "$marker" > "$temp" || true
  printf '15 3 * * * cd %q && bash manage.sh backup scheduled >> %q 2>&1 %s\n' \
    "$SELF_HOST_DIR" "$BACKUP_DIR/scheduled-backup.log" "$marker" >> "$temp"
  crontab "$temp"
  rm -f "$temp"
  if [[ "$BACKUP_RETENTION_MODE" == "tiered" ]]; then
    echo "Daily backup scheduled for 03:15 server time. Retention: $BACKUP_KEEP_DAILY daily, $BACKUP_KEEP_WEEKLY weekly, $BACKUP_KEEP_MONTHLY monthly."
  else
    echo "Daily backup scheduled for 03:15 server time. Keeping the newest $BACKUP_KEEP backups."
  fi
}

usage() {
  cat <<'EOF'
Usage: bash manage.sh COMMAND

  deploy                 Back up, pull/build images, deploy, health-check
  restart                Restart all containers and health-check
  status                 Show container status
  logs [service]         Follow logs
  backup [label]         Back up database, attachments, env, and metadata
  backups                List backups newest first
  restore <backup-name>  Verify and restore a backup (with safety backup)
  schedule-backups       Install a daily 03:15 cron job
EOF
}

command="${1:-help}"
shift || true

case "$command" in
  deploy)
    [[ "$#" -eq 0 ]] || die "deploy takes no arguments"
    create_backup pre-deploy
    if [[ "$MANAGEMENT_BUILD_FROM_SOURCE" == "true" ]]; then
      compose build --pull
    else
      compose pull
    fi
    wait_for_stack
    echo "Deployment complete and the stack is healthy."
    ;;
  restart)
    [[ "$#" -eq 0 ]] || die "restart takes no arguments"
    compose restart
    wait_for_stack
    echo "Restart complete and the stack is healthy."
    ;;
  status)
    [[ "$#" -eq 0 ]] || die "status takes no arguments"
    compose ps
    ;;
  logs)
    [[ "$#" -le 1 ]] || die "logs accepts at most one service"
    compose logs -f "$@"
    ;;
  backup)
    [[ "$#" -le 1 ]] || die "backup accepts at most one label"
    create_backup "${1:-manual}"
    ;;
  backups)
    [[ "$#" -eq 0 ]] || die "backups takes no arguments"
    if [[ ! -d "$BACKUP_DIR" ]]; then
      echo "No backups yet."
    else
      find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -name '20????????????-*' -print | sort -r | sed 's|.*/||'
    fi
    ;;
  restore)
    [[ "$#" -eq 1 ]] || die "restore requires one backup name"
    restore_backup "$1"
    ;;
  schedule-backups)
    [[ "$#" -eq 0 ]] || die "schedule-backups takes no arguments"
    install_backup_cron
    ;;
  help | -h | --help)
    usage
    ;;
  *)
    usage >&2
    die "unknown command: $command"
    ;;
esac
