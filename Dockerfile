# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026 WebTigers. Tiger™ and WebTigers™ are trademarks of WebTigers.
#
# Tiger — evaluation image. One container: Apache + PHP + MariaDB + a Tiger install.
#
# The container is its own kind of shared host: nothing about what gets installed is special.
# The install is performed by tiger-headless — the same engine the web installer, cPanel and node
# provisioning use — from the same published bundle. If an install here ever differs from an
# ordinary install of the same version, that is a bug in this image, not a feature.
#
# NOT for production: no TLS, no mail, no backups, no upgrade path. State lives in the container.

FROM php:8.3-apache-bookworm

# The engine's host requirements (Tiger_Headless_Installer::hostRequirements): PHP 8.1+, pdo_mysql,
# mbstring, json, zip, curl, a writable app root and docroot. json and curl ship with the base image.
# libzip/oniguruma stay installed — they are what the zip and mbstring extensions link against.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        mariadb-server mariadb-client \
        libzip-dev libonig-dev \
        unzip ca-certificates; \
    docker-php-ext-install -j"$(nproc)" pdo_mysql zip mbstring; \
    rm -rf /var/lib/apt/lists/*

# Tiger's public/.htaccess carries the rewrite rules and the Authorization passthrough, so the
# docroot has to allow overrides. mod_rewrite is what makes routes resolve at all.
RUN set -eux; \
    a2enmod rewrite; \
    printf '%s\n' \
        '<Directory /var/www/tiger/public>' \
        '    Options -Indexes +FollowSymLinks' \
        '    AllowOverride All' \
        '    Require all granted' \
        '</Directory>' \
        > /etc/apache2/conf-available/tiger.conf; \
    a2enconf tiger; \
    sed -ri 's!DocumentRoot /var/www/html!DocumentRoot /var/www/tiger/public!g' /etc/apache2/sites-available/000-default.conf

# tiger-headless is not on Packagist and needs no composer — bin/tiger-headless requires its own
# src/autoload.php. Pinned by tag so an image rebuild cannot silently change the install engine.
ARG HEADLESS_REF=v1.4.0
RUN set -eux; \
    curl -fsSL "https://codeload.github.com/WebTigers/TigerHeadless/tar.gz/refs/tags/${HEADLESS_REF}" -o /tmp/headless.tar.gz; \
    mkdir -p /opt/tiger-headless; \
    tar -xzf /tmp/headless.tar.gz -C /opt/tiger-headless --strip-components=1; \
    rm /tmp/headless.tar.gz; \
    php /opt/tiger-headless/bin/tiger-headless 2>&1 | head -1 || true

# Which Tiger release to install. Empty means "the newest published bundle", which is what an
# ordinary install gets; pin it for a reproducible image.
ARG TIGER_VERSION=""
ENV TIGER_VERSION=${TIGER_VERSION}

ENV TIGER_APP_ROOT=/var/www/tiger \
    TIGER_SITE_URL=http://localhost:8080 \
    TIGER_SITE_NAME=Tiger \
    TIGER_ADMIN_EMAIL=admin@example.com \
    TIGER_ADMIN_PASSWORD="" \
    TIGER_LOCALE=en

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
COPY AGENTS.md /AGENTS.md
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

EXPOSE 80
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["apache2-foreground"]
