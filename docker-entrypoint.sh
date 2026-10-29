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

log "starting MariaDB"
mysqld_safe --datadir="${DATADIR}" --skip-networking=0 --bind-address=127.0.0.1 >/dev/null 2>&1 &

for _ in $(seq 1 60); do
    if mariadb-admin ping --silent 2>/dev/null; then break; fi
    sleep 1
done
if ! mariadb-admin ping --silent 2>/dev/null; then
    log "FATAL: MariaDB did not come up"; exit 1
fi

mariadb -u root <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL

# ---------------------------------------------------------------- install
# A password nobody chose is generated once and surfaced once — the same handoff the web installer
# makes. It is written beside the install so a restart reports the same one rather than a new lie.
PASSWORD_FILE="${APP_ROOT}/.admin-password"
if [ -z "${TIGER_ADMIN_PASSWORD}" ]; then
    if [ -f "${PASSWORD_FILE}" ]; then
        TIGER_ADMIN_PASSWORD="$(cat "${PASSWORD_FILE}")"
    else
        TIGER_ADMIN_PASSWORD="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)"
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
];
if (($v = getenv("TIGER_VERSION")) !== false && $v !== "") { $spec["source"] = ["version" => $v]; }
echo json_encode($spec);
')

log "running the install engine (it adopts an existing install)"
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

# ---------------------------------------------------------------- banner
# Said out loud because an agent driving docker on the desktop cannot otherwise know this image
# carries its own data. `docker rm` on a container is usually routine cleanup; here it is not.
cat >&2 <<BANNER

  Tiger is running — ${TIGER_SITE_URL}
    admin:    ${TIGER_SITE_URL}/admin
    sign in:  ${TIGER_ADMIN_EMAIL}
    password: ${TIGER_ADMIN_PASSWORD}

  This container holds your Tiger site — there is no volume.
    docker stop / docker start   safe, your site is preserved
    docker rm                    DESTRUCTIVE, deletes the site and its database

  Evaluation image: no TLS, no mail. Not for production.

BANNER

exec "$@"
