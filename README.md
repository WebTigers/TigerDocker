# Tiger in Docker

Run Tiger on your desktop to try it out. One command, no hosting account.

```bash
docker run -p 8080:80 webtigerscom/tiger
```

Then open **http://localhost:8080**. The admin sign-in and a generated password are printed in the
container's output on first run.

## This container holds your site

There is no volume. The container is the disk.

| Command | What happens |
|---|---|
| `docker stop` / `docker start` | Safe — your site is preserved |
| `docker rm` | **Destructive** — the site, its database and uploads are deleted |

That is Docker working as documented, and it is a deliberate choice: this is an evaluation image,
not a place to keep anything you care about.

## What you get

A stock Tiger install — the same bundle, the same install engine (`tiger-headless`) and the same
result as installing on a VPS or a cPanel host. Nothing about this image is a special edition.

**Not for production.** No TLS, no mail transport, no backups, no upgrade path. Anything needing
outbound email will not complete.

## Options

| Variable | Default | |
|---|---|---|
| `TIGER_SITE_URL` | `http://localhost:8080` | match it if you publish a different port |
| `TIGER_ADMIN_EMAIL` | `admin@example.com` | |
| `TIGER_ADMIN_PASSWORD` | generated | printed once on first run |
| `TIGER_SITE_NAME` | `Tiger` | |
| `TIGER_LOCALE` | `en` | `es`, `pt`, `fr`, `de`, `hi` |

```bash
docker run -p 3000:80 \
  -e TIGER_SITE_URL=http://localhost:3000 \
  -e TIGER_ADMIN_EMAIL=you@example.com \
  -e TIGER_ADMIN_PASSWORD=choose-your-own \
  webtigerscom/tiger
```

## Licence

Tiger core is BSD-3-Clause. Tiger™ and WebTigers™ are trademarks of WebTigers.
