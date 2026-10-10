# Management cycle

The repository includes one short command surface for routine work. Run these
commands from the repository root on your own computer; they connect to the
server over SSH when needed.

## One-time setup

Your server should have the repository checked out and a working
`self-hosting/.env`, as in the setup guide. On your computer:

```bash
cp .deploy.env.example .deploy.env
```

Edit only these two values:

```dotenv
DEPLOY_HOST=moneymatter-server
DEPLOY_PATH=/opt/moneymatter
```

`DEPLOY_HOST` can be a normal `user@server-ip` value or, preferably, a short
alias configured in `~/.ssh/config`. Application secrets do not belong in this
file; they remain in `self-hosting/.env` on the server.

Check the setup:

```bash
./manage doctor
```

## Normal development and deployment

```bash
./manage dev       # local app; rebuilds changed development images
./manage logs      # local logs; Ctrl-C stops following, not the app
./manage stop      # stop local development when finished

./manage deploy    # on the server: git pull, backup, update, health-check
./manage status    # show production health and container state
```

Commit and push the version you intend to deploy before `./manage deploy`.
The server checkout is updated with `git pull --ff-only`, so deployment stops
instead of guessing if the server has local code changes or divergent history.
Set `DEPLOY_UPDATE_CODE=false` in `.deploy.env` only when another process keeps
the checkout updated.

By default deployment pulls published images. If this installation builds your
fork on the server, set this in the server's `self-hosting/.env`:

```dotenv
MANAGEMENT_BUILD_FROM_SOURCE=true
```

If the installation uses the bundled Traefik overlay, also set:

```dotenv
MANAGEMENT_USE_TRAEFIK=true
```

Every deploy creates a `pre-deploy` backup before changing containers. Compose
waits until all health checks pass. On failure, recent backend/frontend logs
are printed and the command exits unsuccessfully. Database migrations can make
an image-only rollback unsafe, so use the just-created backup if recovery is
needed instead of automatically starting an older image against a newer schema.

## Restart and logs

```bash
./manage restart
./manage server-logs
./manage server-logs backend
```

A restart also waits for health checks. Use it for a stuck process; use deploy
when updating code, images, Compose configuration, or environment values.

## Backups

Create and list backups at any time:

```bash
./manage backup
./manage backups
```

Install the daily schedule once:

```bash
./manage schedule-backups
```

This adds an idempotent cron entry at 03:15 server time. Retention uses UTC
calendar buckets and keeps only the newest successful backup in each bucket.
One backup can satisfy several tiers, so a month-opening backup may count as
the daily, weekly, and monthly copy without being duplicated. Configure it in
the server's `self-hosting/.env`:

```dotenv
BACKUP_DIR=/var/backups/moneymatter
BACKUP_KEEP_DAILY=3
BACKUP_KEEP_WEEKLY=4
BACKUP_KEEP_MONTHLY=12
```

This retains one backup for each of the newest 3 represented days, 4 ISO weeks,
and 12 calendar months. `BACKUP_KEEP=14` remains available as a legacy
newest-N policy, but is ignored when any tier setting is present.

Each backup is a directory containing:

- a compressed Postgres dump;
- local transaction attachments (skipped when S3 attachment storage is used);
- checksums and deployment metadata;
- a private copy of the production environment, needed to recover encrypted
  credentials and authentication sessions.

A backup is published under its final directory name only after all validation
passes. The script checks gzip streams, lists the complete attachment archive,
verifies SHA-256 checksums, and restores the database dump into a temporary
database with SQL errors treated as fatal. Failed or interrupted backups remain
temporary and are deleted automatically, so they are never retained or synced
as valid backups.

The backup script uses restrictive permissions, but backups contain secrets.
Do not commit or share them. A backup stored only on the Hetzner server does not
protect against loss of that server: copy `BACKUP_DIR` to a second encrypted
location using Hetzner Storage Box, Restic, Borg, or another system you trust.
The management script intentionally does not invent cloud credentials or a
remote destination for you.

## Restore

List backups, then restore by its exact name:

```bash
./manage backups
./manage restore 20261010011500-scheduled
```

Restore repeats the checksum, archive, and temporary-database restore checks,
requires typing `RESTORE`, creates a `pre-restore` safety backup, replaces
Postgres and local attachments, then starts the complete stack and waits for
health checks. The saved `production.env` is not applied automatically, so a
routine data restore cannot silently replace current secrets. In a complete
server-loss recovery, inspect it and copy it back to `self-hosting/.env` before
restoring the data.

## Useful configuration

These optional settings live only in the server's `self-hosting/.env`:

| Setting                         | Default                | Meaning                                           |
| ------------------------------- | ---------------------- | ------------------------------------------------- |
| `BACKUP_DIR`                    | `self-hosting/backups` | Backup storage directory                          |
| `BACKUP_KEEP_DAILY`             | `3`                    | Daily UTC buckets to retain                       |
| `BACKUP_KEEP_WEEKLY`            | `4`                    | ISO-week buckets to retain                        |
| `BACKUP_KEEP_MONTHLY`           | `12`                   | Calendar-month buckets to retain                  |
| `BACKUP_KEEP`                   | unset                  | Legacy newest-N retention                         |
| `MANAGEMENT_HEALTH_TIMEOUT`     | `180`                  | Seconds to wait for healthy containers            |
| `MANAGEMENT_BUILD_FROM_SOURCE`  | `false`                | Build this checkout instead of pulling app images |
| `MANAGEMENT_USE_TRAEFIK`        | `false`                | Include the bundled Traefik Compose overlay       |
| `MANAGEMENT_EXTRA_COMPOSE_FILE` | unset                  | Add one local `docker-compose.*.yml` overlay      |

## Continuous verification

The `Self-host backup system` GitHub Actions workflow runs on every push to
`dev` and can also be started manually. It boots the production Compose stack
with the Traefik overlay and published images on an Ubuntu runner, then verifies
database and attachment backup/restore, internal backup validation, rejection
of a deliberately corrupted dump, and the exact 3-daily/4-weekly/12-monthly
one-per-unit retention set. All credentials, volumes, and backups are disposable
and are removed when the job finishes. A final CI-only Compose overlay keeps the
same Traefik TLS routing but disables ACME: public certificate authorities
cannot issue a certificate for the reserved `moneymatter.test` domain, so the
runner uses Traefik's generated self-signed certificate instead.
The workflow also gives that overlay to `manage.sh`, ensuring backup restores
and health checks reconstruct the same Compose stack that the test started.
