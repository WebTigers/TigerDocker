# AGENTS.md — you are inside the Tiger evaluation container

Notes for an AI assistant working on this container. The facts here are the ones you cannot infer
from the filesystem.

## This container carries its own data

There is **no volume and no bind mount**. The container *is* the disk.

- `docker stop` / `docker start` — safe, the site is preserved.
- `docker rm`, `docker compose down`, `docker run` with a fresh name — **destructive**. The site,
  its database and its uploads are gone. Removing a container is usually routine cleanup; for this
  one it is not. Ask before you do it.

## What this is

An **evaluation** image: Apache + PHP 8.3 + MariaDB + an ordinary Tiger install in one container.
No TLS, no mail transport, no backups, no upgrade path. Anything depending on outbound email —
signup verification, password reset — will not complete. That is expected; wire up a transport
yourself if you need it.

## Layout

| Path | What |
|---|---|
| `/var/www/tiger` | application root |
| `/var/www/tiger/public` | document root (Apache `DocumentRoot`) |
| `/var/www/tiger/application/configs/local.ini` | db credentials, `tiger.crypto.key`, `security.pepper` |
| `/var/www/tiger/storage/media` | private uploads · `public/_media` public ones |
| `/opt/tiger-headless` | the install engine |

**Do not rotate `tiger.crypto.key` or `security.pepper`.** Existing encrypted data becomes
unreadable, silently and with no error at the moment it happens.

## Running things

Run as the web user, not root, or you will leave root-owned files in the tree:

```bash
runuser -u www-data -- php /var/www/tiger/vendor/bin/tiger migrate:status
runuser -u www-data -- php /opt/tiger-headless/bin/tiger-headless status --app-root=/var/www/tiger
```

`tiger-headless` emits JSON on stdout and nothing else — it is meant to be parsed.

## Conventions

This is a stock Tiger install. The codebase conventions live in the tree: read
`vendor/webtigers/tiger-core/AGENTS.md` before changing code, and `CAPABILITIES.md` before building
anything — core probably already does it.
