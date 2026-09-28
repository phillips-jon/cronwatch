<?php

/**
 * Builds the plugin zip the WordPress.org directory takes:
 *
 *     php wordpress/build.php [output directory]      (from packages/php)
 *
 * writes cronwatch-<version>.zip (default into wordpress/dist/) holding one
 * folder, cronwatch/: the plugin's own files (cronwatch.php, uninstall.php,
 * readme.txt, includes/), the dashboard's stylesheet (css/dashboard.css,
 * written here from the library's Html::CSS, which the plugin enqueues) and
 * the library it runs on (lib/src, with its MIT LICENSE as lib/LICENSE),
 * less the library's files the plugin never runs (LEFT_OUT: the curl and
 * stream transport, since every request goes through wp_remote_post; every
 * alert channel but Slack and the webhook, the two the settings offer (email
 * goes through wp_mail), and the AWS signing only SES used; Claude triage;
 * the standalone dashboard's head, with its inline stylesheet and app.js,
 * since the plugin gives the dashboard its own; the PDO stores, since the
 * plugin stores through $wpdb; the pg_cron source; the command-line check;
 * the PSR-15 adapters; the Laravel and Symfony integrations and what only
 * they use). Nothing else goes in: no tests, no Composer files, no build
 * script, no dotfiles.
 *
 * Each of the library's PHP files gets one line after its declare():
 * CRONWATCH_LIB_ANNOTATION, which tells the directory's Plugin Check (PHPCS
 * with the WordPress rules) that the library's exception messages are not
 * output. They are plain text for the error log, WP-CLI and the dashboard,
 * and everywhere the plugin shows one it escapes it (esc_html in wp-admin,
 * the dashboard's own escaping on its pages); the library runs outside
 * WordPress too, so it cannot call esc_html itself. Nothing else in a file
 * changes. The version is the library's
 * (Cronwatch::VERSION); the plugin header's Version and the readme's Stable
 * tag must match it, and the readme's changelog must have its section, and
 * the build stops when they do not. Entries carry a
 * fixed time, so the same sources give the same zip.
 */

declare(strict_types=1);

/** The library's files (under src/) the plugin never loads, so its zip leaves them out. A path ending in "/" is a directory. */
const CRONWATCH_LEFT_OUT = [
    'Alerts/Bugsnag.php',
    'Alerts/Datadog.php',
    'Alerts/Discord.php',
    'Alerts/Honeybadger.php',
    'Alerts/Mailgun.php',
    'Alerts/NativeHttp.php',
    'Alerts/NewRelic.php',
    'Alerts/Postmark.php',
    'Alerts/Resend.php',
    'Alerts/Rollbar.php',
    'Alerts/Sendgrid.php',
    'Alerts/Sentry.php',
    'Alerts/Ses.php',
    'Alerts/SigV4.php',
    'Alerts/Twilio.php',
    'Bridge/',
    'Cli.php',
    'Laravel/',
    'Sources/PgCron.php',
    'Sources/PgCronPdo.php',
    'Store/Migrated.php',
    'Store/MysqlStore.php',
    'Store/PdoStore.php',
    'Store/PostgresStore.php',
    'Store/SqliteStore.php',
    'Symfony/',
    'Triage/',
    'Watch.php',
    'Web/PsrHandler.php',
    'Web/PsrJobHandler.php',
    'Web/PsrMiddleware.php',
    'Web/StandaloneHead.php',
];

/** Where the dashboard's stylesheet goes in the plugin (AdminDashboard::STYLESHEET). */
const CRONWATCH_STYLESHEET = 'css/dashboard.css';

/** The line each library PHP file gets in the zip, after declare(strict_types=1); (see above). */
const CRONWATCH_LIB_ANNOTATION = '// phpcs:disable WordPress.Security.EscapeOutput.ExceptionNotEscaped -- the library\'s exception messages are plain text for logs, WP-CLI and the dashboard, and are escaped wherever the plugin shows one.';

/** Whether a file under src/ is left out. */
function cronwatch_left_out(string $file): bool
{
    foreach (CRONWATCH_LEFT_OUT as $out) {
        if ($file === $out || (str_ends_with($out, '/') && str_starts_with($file, $out))) {
            return true;
        }
    }
    return false;
}

$plugin = __DIR__;
$library = dirname(__DIR__);
$out = $argv[1] ?? "{$plugin}/dist";

if (!class_exists(ZipArchive::class)) {
    fwrite(STDERR, "build: needs the zip extension\n");
    exit(1);
}

$version = preg_match("/public const VERSION = '([^']+)'/", (string) file_get_contents("{$library}/src/Cronwatch.php"), $m) === 1 ? $m[1] : null;
$header = preg_match('/^ \* Version:\s+(\S+)$/m', (string) file_get_contents("{$plugin}/cronwatch.php"), $m) === 1 ? $m[1] : null;
$stable = preg_match('/^Stable tag:\s+(\S+)$/m', (string) file_get_contents("{$plugin}/readme.txt"), $m) === 1 ? $m[1] : null;
if ($version === null || $header !== $version || $stable !== $version) {
    fwrite(STDERR, 'build: versions differ: library ' . var_export($version, true) . ', cronwatch.php ' . var_export($header, true) . ', readme.txt ' . var_export($stable, true) . "\n");
    exit(1);
}
// The directory shows the readme's changelog; the version shipped has its section there (release.mjs adds it).
if (preg_match('/^= ' . preg_quote($version, '/') . ' =$/m', (string) file_get_contents("{$plugin}/readme.txt")) !== 1) {
    fwrite(STDERR, "build: readme.txt has no \"= {$version} =\" changelog section\n");
    exit(1);
}

/** Every file under a directory, relative to it, sorted, dotfiles left out. */
function cronwatch_build_files(string $dir): array
{
    $files = [];
    $items = new RecursiveIteratorIterator(new RecursiveDirectoryIterator($dir, FilesystemIterator::SKIP_DOTS));
    foreach ($items as $item) {
        $relative = substr($item->getPathname(), strlen($dir) + 1);
        if ($item->isFile() && !preg_match('#(^|/)\.#', $relative)) {
            $files[] = str_replace(DIRECTORY_SEPARATOR, '/', $relative);
        }
    }
    sort($files);
    return $files;
}

// The dashboard's stylesheet, from the library's pages. Html only declares
// constants, so loading it runs nothing and needs no other class.
require_once "{$library}/src/Web/Html.php";
$generated = ['cronwatch/' . CRONWATCH_STYLESHEET => ltrim(\Cronwatch\Web\Html::CSS, "\n")];

$entries = [];
foreach (['cronwatch.php', 'uninstall.php', 'readme.txt'] as $file) {
    $entries["cronwatch/{$file}"] = "{$plugin}/{$file}";
}
$entries += array_fill_keys(array_keys($generated), null);
foreach (cronwatch_build_files("{$plugin}/includes") as $file) {
    $entries["cronwatch/includes/{$file}"] = "{$plugin}/includes/{$file}";
}
foreach (cronwatch_build_files("{$library}/src") as $file) {
    if (!cronwatch_left_out($file)) {
        $entries["cronwatch/lib/src/{$file}"] = "{$library}/src/{$file}";
    }
}
foreach (CRONWATCH_LEFT_OUT as $file) {
    if (str_ends_with($file, '/') ? !is_dir("{$library}/src/{$file}") : !is_file("{$library}/src/{$file}")) {
        fwrite(STDERR, "build: {$file} is left out but is not in src/; update CRONWATCH_LEFT_OUT\n");
        exit(1);
    }
}
$entries['cronwatch/lib/LICENSE'] = "{$library}/LICENSE";

if (!is_dir($out) && !mkdir($out, 0777, true) && !is_dir($out)) {
    fwrite(STDERR, "build: cannot create {$out}\n");
    exit(1);
}
$zipPath = rtrim($out, '/') . "/cronwatch-{$version}.zip";
@unlink($zipPath);
$zip = new ZipArchive();
if ($zip->open($zipPath, ZipArchive::CREATE | ZipArchive::EXCL) !== true) {
    fwrite(STDERR, "build: cannot write {$zipPath}\n");
    exit(1);
}
// 2026-01-01 00:00:00 UTC, so the zip does not change with the checkout's file times.
$time = 1767225600;
foreach ($entries as $name => $source) {
    if ($source === null) {
        $zip->addFromString($name, $generated[$name]);
    } elseif (str_starts_with($name, 'cronwatch/lib/src/') && str_ends_with($name, '.php')) {
        $code = (string) file_get_contents($source);
        $declare = "\ndeclare(strict_types=1);\n";
        if (substr_count($code, $declare) !== 1) {
            fwrite(STDERR, "build: {$source} needs exactly one declare(strict_types=1); line\n");
            exit(1);
        }
        $zip->addFromString($name, str_replace($declare, $declare . CRONWATCH_LIB_ANNOTATION . "\n", $code));
    } else {
        $zip->addFile($source, $name);
    }
    $zip->setMtimeName($name, $time);
    $zip->setExternalAttributesName($name, ZipArchive::OPSYS_UNIX, 0644 << 16);
}
$zip->close();
echo "wrote {$zipPath} (" . count($entries) . " files)\n";
