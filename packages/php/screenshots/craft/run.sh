#!/bin/sh
# Takes the Craft Plugin Store screenshots of the Craft CMS plugin
# (packages/php/craft) from a real Craft CMS 5 running it, into the
# directory given (1-overview.png to 5-jobs.png):
#
#     PLAYWRIGHT=/path/to/node_modules/playwright packages/php/screenshots/craft/run.sh ~/Desktop/shots
#
# Needs Docker, PHP 8.2 or newer and Composer on the host, Node, and
# Playwright with its Chromium (not a dependency of the repository; set
# PLAYWRIGHT to its package directory). It takes a few minutes.
#
# It lives outside packages/php/craft because that directory is the
# plugin's Composer package (split to its own repository), and
# packages/php/.gitattributes keeps it out of the library's archive.
#
# What it does:
# 1. Starts MySQL 8.4 (container cwc-db on network cwc, 127.0.0.1:$DB_PORT,
#    default 33107) and makes a Craft project with `composer create-project
#    craftcms/craft` in a work directory, with this checkout's library and
#    plugin as path repositories (copied, at the library's version), and
#    site/ copied over it: the site's module (its console commands app/...
#    and queue jobs), config/app.php and config/cronwatch.php.
# 2. Installs Craft as "Northwind Outfitters" and the plugin. Every `craft`
#    command runs in the craftcms/cli:8.2 image with the project at
#    /var/www/northwind, so what a run records (a stack trace's file names)
#    is a server's path, not this machine's.
# 3. Seeds a week of runs through the plugin (`craft app/seed`, see
#    site/modules/console/controllers/SeedController.php): the supplier feed
#    failing for its last four runs, the exchange rates' crontab line lost
#    five hours ago, last night's resave slow, and the inventory sync's
#    three failures yesterday and its recovery. The week ends a minute or
#    two from now; once that has passed, `craft cronwatch/check` finds the
#    missed runs, and `craft app/seed/settings` fills in the plugin's
#    settings with made-up channels (environment variables whose values in
#    .env are placeholders).
# 4. Serves the site with PHP's built-in server on 127.0.0.1:$PORT (default
#    8097) and captures the screenshots with Playwright (capture.mjs).
# 5. Stops the server and removes the container, the network and the work
#    directory, unless KEEP=1.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
PHP_DIR=$(cd "$HERE/../.." && pwd)
OUT=${1:?usage: run.sh <output directory>}
: "${PLAYWRIGHT:?set PLAYWRIGHT to the playwright package directory}"
DB_PORT=${DB_PORT:-33107}
PORT=${PORT:-8097}
export PORT PLAYWRIGHT
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/cwc.XXXXXX")
SITE="$WORK/site"
SERVER=

cleanup() {
  if [ -n "$SERVER" ]; then kill "$SERVER" 2>/dev/null || true; wait "$SERVER" 2>/dev/null || true; fi
  if [ "${KEEP:-}" != 1 ]; then
    docker rm -f cwc-db >/dev/null 2>&1 || true
    docker network rm cwc >/dev/null 2>&1 || true
    rm -rf "$WORK"
  else
    echo "kept $SITE and the cwc-db container"
  fi
}
trap cleanup EXIT

# `craft` in the container, the project at /var/www/northwind, MySQL by its name on the network.
craft() {
  docker run --rm --network cwc -v "$SITE":/var/www/northwind -w /var/www/northwind \
    -e CRAFT_DB_SERVER=cwc-db -e CRAFT_DB_PORT=3306 craftcms/cli:8.2 php craft "$@"
}

docker network create cwc >/dev/null
docker run -d --name cwc-db --network cwc -e MYSQL_ROOT_PASSWORD=pw -e MYSQL_DATABASE=craft \
  -p "127.0.0.1:$DB_PORT:3306" mysql:8.4 >/dev/null

VERSION=$(sed -n "s/.*const VERSION = '\(.*\)';.*/\1/p" "$PHP_DIR/src/Cronwatch.php")
composer create-project craftcms/craft "$SITE" --no-interaction --no-scripts --quiet
cd "$SITE"
cp .env.example.dev .env
composer config platform.php 8.2.26
composer config repositories.cronwatch-craft "{\"type\":\"path\",\"url\":\"$PHP_DIR/craft\",\"options\":{\"symlink\":false,\"versions\":{\"cronwatch/craft\":\"$VERSION\"}}}"
composer config repositories.cronwatch "{\"type\":\"path\",\"url\":\"$PHP_DIR\",\"options\":{\"symlink\":false,\"versions\":{\"cronwatch/cronwatch\":\"$VERSION\"}}}"
cp -R "$HERE/site/." "$SITE/"
php -r '$f = "composer.json"; $j = json_decode(file_get_contents($f), true); $j["autoload"]["psr-4"]["modules\\"] = "modules/"; file_put_contents($f, json_encode($j, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . "\n");'
composer update --no-interaction --quiet
composer require "cronwatch/craft:$VERSION" --no-interaction --quiet

# Production mode (no debug toolbar or dev banners), and the channels' environment
# variables as placeholders. The Slack URL is put together here so secret scanners do
# not take it for a real one.
{
  echo "CRAFT_APP_ID=CraftCMS--$(php -r 'echo bin2hex(random_bytes(16));')"
  echo "CRAFT_ENVIRONMENT=production"
  echo "CRAFT_SECURITY_KEY=$(php -r 'echo bin2hex(random_bytes(16));')"
  echo "CRAFT_DEV_MODE=false"
  echo "CRAFT_ALLOW_ADMIN_CHANGES=true"
  echo "CRAFT_DISALLOW_ROBOTS=true"
  echo "CRAFT_DB_DRIVER=mysql"
  echo "CRAFT_DB_SERVER=127.0.0.1"
  echo "CRAFT_DB_PORT=$DB_PORT"
  echo "CRAFT_DB_DATABASE=craft"
  echo "CRAFT_DB_USER=root"
  echo "CRAFT_DB_PASSWORD=pw"
  echo "CRAFT_DB_SCHEMA="
  echo "CRAFT_DB_TABLE_PREFIX="
  echo "PRIMARY_SITE_URL=http://northwind.example.com"
  echo "SLACK_WEBHOOK_URL=https://hooks.slack.com/services/$(printf 'T%08d/B%08d/%024d' 0 0 0)"
  echo "ALERTS_WEBHOOK_URL=https://ops.example.com/hooks/cronwatch"
  echo "ALERTS_WEBHOOK_SECRET=placeholder-secret-for-screenshots"
} > .env

until docker exec cwc-db mysql -uroot -ppw -e 'SELECT 1' craft >/dev/null 2>&1; do sleep 2; done
craft install --interactive=0 --username=admin --password=cwc-shots-pass --email=admin@example.com \
  --site-name="Northwind Outfitters" --site-url='$PRIMARY_SITE_URL' --language=en-GB >/dev/null
craft plugin/install cronwatch

R=$(node -e 'console.log(Math.ceil((Date.now() + 90e3) / 60e3) * 60e3)')
craft app/seed --now="$R" | tail -1
WAIT=$(node -e "console.log(Math.max(0, Math.ceil(($R - Date.now()) / 1000) + 2))")
echo "waiting ${WAIT}s for the seeded now"
sleep "$WAIT"
craft cronwatch/check
craft app/seed/settings

php -S "127.0.0.1:$PORT" -t "$SITE/web" "$SITE/vendor/craftcms/cms/bootstrap/router.php" >"$WORK/server.log" 2>&1 &
SERVER=$!
sleep 2
node "$HERE/capture.mjs" "$OUT"
