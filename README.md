# PostgreSQL backup script

![PostgreSQL backup workflow: Docker database, custom dump, S3 upload, and downloaded SHA-256 verification](assets/backup-flow.svg)

This example creates a PostgreSQL custom-format dump from a running Docker
container, validates it, uploads it to Amazon S3, and verifies the bytes that
were downloaded from S3. A systemd timer can run it once per day. CPU priority
is set to nice 10 for the service, the script, and `pg_dump`.

The backup object is stored as:

```text
s3://BUCKET/database/YYYY-DD-MM.dump
```

For example, a backup created on 27 September 2026 is stored at
`s3://example-postgres-backups/database/2026-27-09.dump`. A second successful
run on the same UTC date replaces that day's object.

The archive contains the selected database's schema and data. It does not
contain PostgreSQL cluster roles, Docker configuration, container secrets, or
files outside the database. Test a restore separately before relying on a
backup for disaster recovery.

## Requirements

The Docker host needs:

- Docker and a running PostgreSQL container.
- AWS CLI credentials available to root for unattended use.
- `flock`, `mktemp`, GNU `stat`, `sha256sum`, and `renice`.
- Python 3 only if Discord notifications are enabled.
- Enough free space for the dump and a second copy used for S3 verification.

The database container must provide `pg_dump`, `pg_restore`, and `pg_isready`,
and the `postgres` database user must be able to read the selected database.

## Set up on the Docker host

Clone the repository and enter its directory:

```bash
git clone https://github.com/adel-bz/Postgresql-Backup-Script.git
cd Postgresql-Backup-Script
```

Create the private settings directory, then copy the files to the paths used
by the script and systemd:

```bash
sudo mkdir -p /etc/postgresql-backup /usr/local/sbin /etc/systemd/system
sudo chown root:root /etc/postgresql-backup
sudo chmod 0700 /etc/postgresql-backup

sudo cp env.example /etc/postgresql-backup/.env
sudo cp backup-postgresql.sh /usr/local/sbin/backup-postgresql.sh
sudo cp postgresql-backup.service /etc/systemd/system/postgresql-backup.service
sudo cp postgresql-backup.timer /etc/systemd/system/postgresql-backup.timer

sudo chown root:root /etc/postgresql-backup/.env /usr/local/sbin/backup-postgresql.sh
sudo chmod 0600 /etc/postgresql-backup/.env
sudo chmod 0700 /usr/local/sbin/backup-postgresql.sh
sudo chown root:root /etc/systemd/system/postgresql-backup.service /etc/systemd/system/postgresql-backup.timer
sudo chmod 0644 /etc/systemd/system/postgresql-backup.service /etc/systemd/system/postgresql-backup.timer
```

Edit the private settings file and set `S3_BUCKET`, `AWS_REGION`,
`CONTAINER_NAME`, and `DATABASE_NAME`:

```bash
sudoedit /etc/postgresql-backup/.env
```

If the host has no IAM role or AWS profile, uncomment `AWS_ACCESS_KEY_ID` and
`AWS_SECRET_ACCESS_KEY` in the private server copy and set their values. Also
set `AWS_SESSION_TOKEN` when using temporary credentials. Never add credential
values to `env.example`, commit them, or paste them into an issue.

Create the S3 bucket in the region named by `AWS_REGION`. The sample policy
uses placeholder account, user, bucket, and `IP_ADDRESS` values; replace all
four with your own values before applying it. Keep the IAM policy and bucket
policy aligned. The bucket policy allows only the named IAM principal from
the specified public IP and applies to objects under the bucket. Add an S3
lifecycle rule that expires objects after seven days if that retention period
is desired. Lifecycle rules are configured on the bucket, not by this script.

## Run the backup

Run one manual backup before enabling the timer:

```bash
sudo systemctl daemon-reload
sudo systemctl start postgresql-backup.service
sudo systemctl status postgresql-backup.service --no-pager
sudo journalctl -u postgresql-backup.service -n 50 --no-pager
```

After confirming the object exists in S3, enable the daily timer:

```bash
sudo systemctl enable --now postgresql-backup.timer
sudo systemctl list-timers postgresql-backup.timer
```

The timer runs at 02:00 UTC and catches up once after a missed run. A oneshot
service may show `inactive (dead)` after a successful run; check
`Result=success` and `ExecMainStatus=0`, or read the journal.

## Discord notifications

Set `DISCORD_ALERT_ENABLED=true` and put a webhook URL in the root-only server
`.env` file. The URL is accepted only over HTTPS for an official Discord
webhook host. Notifications are sent after all local and S3 content checks
pass, or after a failure. Notification errors do not change the backup result.
Leave the setting `false` or leave the URL empty to disable notifications.

## Security notes

- The script uses a root-owned, mode `0600` settings file and a private
  temporary directory. Temporary files are removed on exit.
- It uses `--sse AES256` for S3 server-side encryption and stores a SHA-256
  value as object metadata, then independently downloads and hashes the object.
- The script does not print AWS credentials or the Discord webhook URL.
- Keep the repository's `env.example` as a template. Copy it to the server as
  `/etc/postgresql-backup/.env`, then edit the values for your environment.
  Do not rename a real server `.env` to `env.example` or commit it.
