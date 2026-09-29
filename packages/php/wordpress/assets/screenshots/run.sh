#!/bin/sh
# Retakes the plugin directory's screenshots (../screenshot-1.png to
# ../screenshot-4.png, one per line of the readme's Screenshots section)
# from a real WordPress running the built plugin:
#
#     PLAYWRIGHT=/path/to/node_modules/playwright packages/php/wordpress/assets/screenshots/run.sh
#
# Needs Docker, PHP with the zip extension (for wordpress/build.php), Node,
# and Playwright with its Chromium (not a dependency of the repository; set
# PLAYWRIGHT to its package directory). It takes about five minutes, most of
# it waiting for the seeded "now".
#
# What it does:
# 1. Starts MySQL 8.4 and the wordpress:php8.3-apache image (network cws,
#    containers cws-db and cws-wp, volume cws_html, port 127.0.0.1:8088),
#    installs WordPress $WP_VERSION as "Example Store" at
#    http://store.example.com, and installs the zip build.php makes, with
#    cws-store.php (the store's events, a clock, a warehouse feed that can
#    be down) as a must-use plugin.
# 2. Seeds a week of runs (seed.mjs): successful runs through the steps
#    wp-cron.php takes (seed.php), each at its time on the seeded clock, and
#    the warehouse feed's failures as real wp-cron.php requests that end on
#    the uncaught exception. The week ends a few minutes from now.
# 3. Runs `wp cronwatch check`, saves the settings the screenshots show,
#    restarts WordPress without DISABLE_WP_CRON (as the site had it), and
#    captures the four screenshots with Playwright (capture.mjs).
# 4. Removes the containers, the volume and the network, unless KEEP=1.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
PHP_DIR=$(cd "$HERE/../../.." && pwd)
WP_VERSION=${WP_VERSION:-7.1.2}
: "${PLAYWRIGHT:?set PLAYWRIGHT to the playwright package directory}"
CWS_WORK=$(mktemp -d)
export CWS_WORK PLAYWRIGHT
WPC="$HERE/wpc"

cleanup() {
  if [ "${KEEP:-}" != 1 ]; then
    docker rm -f cws-wp cws-db >/dev/null 2>&1 || true
    docker volume rm cws_html >/dev/null 2>&1 || true
    docker network rm cws >/dev/null 2>&1 || true
  fi
  rm -rf "$CWS_WORK"
}
trap cleanup EXIT

web() {
  docker rm -f cws-wp >/dev/null 2>&1 || true
  docker run -d --name cws-wp --network cws -p 127.0.0.1:8088:80 -v cws_html:/var/www/html \
    -e WORDPRESS_DB_HOST=cws-db -e WORDPRESS_DB_USER=root -e WORDPRESS_DB_PASSWORD=pw -e WORDPRESS_DB_NAME=wp \
    "$@" wordpress:php8.3-apache >/dev/null
  sleep 3
}

docker network create cws >/dev/null
docker volume create cws_html >/dev/null
docker run -d --name cws-db --network cws -e MYSQL_ROOT_PASSWORD=pw -e MYSQL_DATABASE=wp mysql:8.4 >/dev/null
until docker exec cws-db mysql -uroot -ppw -e 'SELECT 1' wp >/dev/null 2>&1; do sleep 2; done
web -e "WORDPRESS_CONFIG_EXTRA=define('DISABLE_WP_CRON', true);"
until docker exec cws-wp test -f /var/www/html/wp-config.php; do sleep 1; done

"$WPC" core download --version="$WP_VERSION" --force --skip-content >/dev/null
"$WPC" core install --url=http://store.example.com --title="Example Store" --admin_user=admin \
  --admin_password=cws-shots-pass --admin_email=admin@example.com --skip-email >/dev/null

php "$PHP_DIR/wordpress/build.php" "$CWS_WORK/build" >/dev/null
(cd "$CWS_WORK/build" && unzip -q cronwatch-*.zip)
docker exec cws-wp mkdir -p /var/www/html/wp-content/plugins /var/www/html/wp-content/mu-plugins
docker cp "$CWS_WORK/build/cronwatch" cws-wp:/var/www/html/wp-content/plugins/
docker exec -i cws-wp sh -c 'cat > /var/www/html/wp-content/mu-plugins/cws-store.php' < "$HERE/cws-store.php"
docker exec cws-wp chown -R www-data:www-data /var/www/html/wp-content
"$WPC" plugin activate cronwatch >/dev/null

cp "$HERE/setup.php" "$HERE/seed.php" "$CWS_WORK/"
"$WPC" eval-file /work/setup.php >/dev/null
R=$(node -e 'console.log(Math.ceil((Date.now()+3*60e3)/60e3)*60e3)')
echo "$R" > "$CWS_WORK/R.txt"
node "$HERE/seed.mjs" "$R" | tail -1
"$WPC" cronwatch check
# A placeholder Slack URL, put together here so secret scanners do not take it for a real one.
SLACK="https://hooks.slack.com/services/$(printf 'T%08d/B%08d/%024d' 0 0 0)"
"$WPC" option update cronwatch_settings --format=json \
  '{"email_to":"alerts@example.com","slack_webhook_url":"'"$SLACK"'","webhook_url":"","webhook_secret":"","grace":"10m","api_enabled":"","api_token":""}'

web
node "$HERE/capture.mjs" "$HERE/.."
