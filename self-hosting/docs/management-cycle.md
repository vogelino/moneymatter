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

This adds an idempotent cron entry at 03:15 server time. The newest 14 backups
are kept by default. Change the location and retention in the server's
`self-hosting/.env`:

```dotenv
BACKUP_DIR=/var/backups/moneymatter
BACKUP_KEEP=30
```

Each backup is a directory containing:

- a compressed Postgres dump;
- local transaction attachments (skipped when S3 attachment storage is used);
- checksums and deployment metadata;
- a private copy of the production environment, needed to recover encrypted
  credentials and authentication sessions.

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

Restore verifies checksums, requires typing `RESTORE`, creates a `pre-restore`
safety backup, replaces Postgres and local attachments, then starts the complete
stack and waits for health checks. The saved `production.env` is not applied
automatically, so a routine data restore cannot silently replace current
secrets. In a complete server-loss recovery, inspect it and copy it back to
`self-hosting/.env` before restoring the data.

## Useful configuration

These optional settings live only in the server's `self-hosting/.env`:

| Setting                        | Default                | Meaning                                           |
| ------------------------------ | ---------------------- | ------------------------------------------------- |
| `BACKUP_DIR`                   | `self-hosting/backups` | Backup storage directory                          |
| `BACKUP_KEEP`                  | `14`                   | Number of newest backups to retain                |
| `MANAGEMENT_HEALTH_TIMEOUT`    | `180`                  | Seconds to wait for healthy containers            |
| `MANAGEMENT_BUILD_FROM_SOURCE` | `false`                | Build this checkout instead of pulling app images |
| `MANAGEMENT_USE_TRAEFIK`       | `false`                | Include the bundled Traefik Compose overlay       |
