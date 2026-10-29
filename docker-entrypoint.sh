#!/bin/bash
# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026 WebTigers. Tiger™ and WebTigers™ are trademarks of WebTigers.
#
# Bring up MariaDB, make sure a Tiger install exists, then hand off to Apache.
#
# Idempotent by design: on every start it asks tiger-headless to install. The engine adopts an
# install that is already live and resumes one that is half-finished, so a restart is a no-op and
# a crashed first run picks up where it stopped. No install logic lives here — that is the engine's
# job, and duplicating any of it here is how the container stops being an ordinary host.
set -euo pipefail

APP_ROOT="${TIGER_APP_ROOT:-/var/www/tiger}"
DOCROOT="${APP_ROOT}/public"
DB_NAME="${TIGER_DB_NAME:-tiger}"
DB_USER="${TIGER_DB_USER:-tiger}"
DB_PASSWORD="${TIGER_DB_PASSWORD:-tiger}"
DATADIR=/var/lib/mysql

log() { printf '[tiger] %s\n' "$*" >&2; }

# ---------------------------------------------------------------- database
if [ ! -d "${DATADIR}/mysql" ]; then
    log "initialising MariaDB"
    mariadb-install-db --user=mysql --datadir="${DATADIR}" --auth-root-authentication-method=socket >/dev/null
fi

# Keep the server's own output — when it refuses to start, its log is the only thing that says
# why, and a container that dies silently is a container nobody can debug from CI logs.
SERVER_LOG=/var/log/tiger-mariadb.log
SERVER_BIN=mariadbd-safe
command -v "${SERVER_BIN}" >/dev/null 2>&1 || SERVER_BIN=mysqld_safe

log "starting MariaDB (${SERVER_BIN})"
"${SERVER_BIN}" --datadir="${DATADIR}" --user=mysql --bind-address=127.0.0.1 >"${SERVER_LOG}" 2>&1 &

up=0
for _ in $(seq 1 60); do
    if mariadb-admin ping >/dev/null 2>&1; then up=1; break; fi
    sleep 1
done
if [ "${up}" != "1" ]; then
    log "FATAL: MariaDB did not come up — its log follows"
    tail -40 "${SERVER_LOG}" >&2 || true
    tail -40 /var/log/mysql/error.log >&2 2>/dev/null || true
    exit 1
fi
log "MariaDB is up"

log "ensuring database and user"
if ! mariadb -u root <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL
then
    log "FATAL: could not create the database or user — MariaDB said:"
    tail -20 "${SERVER_LOG}" >&2 || true
    exit 1
fi
log "database ${DB_NAME} ready"

# ---------------------------------------------------------------- install
# A password nobody chose is generated once and surfaced once — the same handoff the web installer
# makes. It is written beside the install so a restart reports the same one rather than a new lie.
PASSWORD_FILE="${APP_ROOT}/.admin-password"
if [ -z "${TIGER_ADMIN_PASSWORD}" ]; then
    if [ -f "${PASSWORD_FILE}" ]; then
        TIGER_ADMIN_PASSWORD="$(cat "${PASSWORD_FILE}")"
    else
        # NOT `tr -dc ... </dev/urandom | head -c 20`: under `set -o pipefail` head exits after
        # 20 bytes, tr takes SIGPIPE and returns 141, the pipeline "fails" and set -e kills the
        # script with nothing in the log. PHP is already here and needs no pipeline.
        TIGER_ADMIN_PASSWORD="$(php -r 'echo bin2hex(random_bytes(10));')"
        GENERATED=1
    fi
fi

mkdir -p "${APP_ROOT}"
chown -R www-data:www-data "${APP_ROOT}"

SPEC=$(TIGER_ADMIN_PASSWORD="${TIGER_ADMIN_PASSWORD}" \
       DB_NAME="${DB_NAME}" DB_USER="${DB_USER}" DB_PASSWORD="${DB_PASSWORD}" \
       APP_ROOT="${APP_ROOT}" DOCROOT="${DOCROOT}" php -r '
$spec = [
    "db"     => ["host" => "127.0.0.1", "port" => 3306, "name" => getenv("DB_NAME"),
                 "user" => getenv("DB_USER"), "password" => getenv("DB_PASSWORD")],
    "paths"  => ["app_root" => getenv("APP_ROOT"), "docroot" => getenv("DOCROOT")],
    "layout" => "docroot",
    "site"   => ["url" => getenv("TIGER_SITE_URL"), "name" => getenv("TIGER_SITE_NAME")],
    "admin"  => ["email" => getenv("TIGER_ADMIN_EMAIL"), "password" => getenv("TIGER_ADMIN_PASSWORD")],
    "locale" => getenv("TIGER_LOCALE") ?: "en",
    // No modules. The spec would otherwise default to ["comingsoon"], which stands up a holding
    // page that answers every public URL with 200 — right for a real site going live, exactly
    // wrong here, where the whole point is to look at Tiger. Passing an explicit list is an
    // ordinary use of the spec, not a special install.
    "modules" => [],
];
if (($v = getenv("TIGER_VERSION")) !== false && $v !== "") { $spec["source"] = ["version" => $v]; }
echo json_encode($spec);
')

: "${SPEC:?spec generation produced nothing}"
log "install spec built"
log "running the install engine (it adopts an existing install) — this can take a few minutes on first run"
set +e
RESULT=$(printf '%s' "${SPEC}" | runuser -u www-data -- php /opt/tiger-headless/bin/tiger-headless install --spec=- 2>/tmp/headless.err)
CODE=$?
set -e

if [ "${CODE}" -ne 0 ]; then
    log "install failed (exit ${CODE})"
    printf '%s\n' "${RESULT}" >&2
    sed -n '1,40p' /tmp/headless.err >&2
    exit "${CODE}"
fi

ALREADY=$(printf '%s' "${RESULT}" | php -r '$d=json_decode(stream_get_contents(STDIN),true); echo !empty($d["already_installed"]) ? "yes" : "no";')
VERSION=$(printf '%s' "${RESULT}" | php -r '$d=json_decode(stream_get_contents(STDIN),true); echo $d["version"] ?? "";')

if [ "${ALREADY}" = "yes" ]; then
    log "existing install adopted (Tiger ${VERSION})"
else
    if [ "${GENERATED:-0}" = "1" ]; then
        printf '%s' "${TIGER_ADMIN_PASSWORD}" > "${PASSWORD_FILE}"
        chmod 600 "${PASSWORD_FILE}"; chown www-data:www-data "${PASSWORD_FILE}"
    fi
    log "installed Tiger ${VERSION}"
fi

# ---------------------------------------------------------------- first-run content
# Bare core serves a BLANK home by design — <main> with nothing in it. ComingSoon normally covers
# that gap and this image deliberately does not install it, so without something here an evaluator
# runs the container and sees a white screen that reads as broken. Seeded only on a fresh install;
# an adopted one keeps whatever its owner put there.
if [ "${ALREADY}" != "yes" ]; then
    if runuser -u www-data -- php /usr/local/lib/tiger-seed-home.php >/tmp/seed.out 2>&1; then
        log "$(cat /tmp/seed.out)"
    else
        log "could not seed the home page (not fatal) — it said:"
        sed -n '1,12p' /tmp/seed.out >&2
    fi
fi

# ---------------------------------------------------------------- banner
# A link that drops the evaluator straight into the Dashboard beats a password they have to carry.
# Two-minute life is fine here: it is printed the moment they run the container and they are
# looking at the terminal. tiger-login mints another whenever they want one.
MAGIC_URL=$(tiger-login 2>/dev/null || true)
# Said out loud because an agent driving docker on the desktop cannot otherwise know this image
# carries its own data. `docker rm` on a container is usually routine cleanup; here it is not.
cat >&2 <<BANNER

  Tiger is running — ${TIGER_SITE_URL}

  Sign straight in (one-time link, valid ~2 minutes):
    ${MAGIC_URL:-  run: docker exec <container> tiger-login}

  Or sign in at ${TIGER_SITE_URL}/admin with:
    ${TIGER_ADMIN_EMAIL}
    ${TIGER_ADMIN_PASSWORD}

  A fresh sign-in link any time:  docker exec <container> tiger-login

  This container holds your Tiger site — there is no volume.
    docker stop / docker start   safe, your site is preserved
    docker rm                    DESTRUCTIVE, deletes the site and its database

  Evaluation image: no TLS, no mail. Not for production.

BANNER

exec "$@"
