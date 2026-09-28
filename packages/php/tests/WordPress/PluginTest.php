<?php

declare(strict_types=1);

namespace Cronwatch\Tests\WordPress;

use Cronwatch\WordPress\Jobs;
use Cronwatch\WordPress\WpdbStore;
use PHPUnit\Framework\TestCase;

/**
 * The WordPress plugin's parts that need no WordPress: how events are named
 * and declared, the schema per database server, and the zip the directory
 * gets. WordPressTest runs the rest in a real WordPress.
 */
final class PluginTest extends TestCase
{
    public static function setUpBeforeClass(): void
    {
        // The plugin's files stop when loaded outside WordPress.
        if (!defined('ABSPATH')) {
            define('ABSPATH', sys_get_temp_dir() . '/');
        }
        foreach (['Jobs', 'WpdbStore'] as $class) {
            require_once dirname(__DIR__, 2) . "/wordpress/includes/{$class}.php";
        }
    }

    public function testJobNames(): void
    {
        $this->assertSame('wp:wp_version_check', Jobs::name('wp_version_check'));
        $this->assertSame('wp:my_hook', Jobs::name('my_hook', ['x']), 'arguments name only recurring events');
        $key = substr(md5(serialize(['x'])), 0, 8);
        $this->assertSame("wp:my_hook:{$key}", Jobs::name('my_hook', ['x'], true));
        $this->assertSame('wp:my_hook', Jobs::name('my_hook', [], true));
        $hash = substr(md5('my hook/1'), 0, 8);
        $this->assertSame("wp:my-hook-1-{$hash}", Jobs::name('my hook/1'), 'a changed hook gets its hash');
        $this->assertNotSame(Jobs::name('a b'), Jobs::name('a-b'));
        $long = Jobs::name(str_repeat('h', 200), ['x'], true);
        $this->assertSame(120, strlen($long));
        $this->assertMatchesRegularExpression('/^wp:h+-[0-9a-f]{8}:[0-9a-f]{8}$/', $long);
        $this->assertSame('wp:--' . substr(md5(str_repeat('é', 100)), 0, 8), Jobs::name(str_repeat('é', 100)));
        foreach (['wp_version_check', 'a b', str_repeat('h', 200), 'Émoji 😀', '---', ''] as $hook) {
            $this->assertMatchesRegularExpression('/^[A-Za-z0-9][A-Za-z0-9._:-]{0,119}$/D', Jobs::name($hook, [1], true), "a valid job name for \"{$hook}\"");
        }
    }

    public function testTheCronArrayAsJobs(): void
    {
        $crons = [
            1000 => [
                'hourly_thing' => [md5(serialize([])) => ['schedule' => 'hourly', 'args' => [], 'interval' => 3600]],
                'publish_future_post' => [md5(serialize([7])) => ['schedule' => false, 'args' => [7]]],
            ],
            2000 => [
                'publish_future_post' => [md5(serialize([8])) => ['schedule' => false, 'args' => [8]]],
                'custom' => [md5(serialize(['a'])) => ['schedule' => 'every_ten', 'args' => ['a']]],
                'hourly_thing' => [md5(serialize([])) => ['schedule' => false, 'args' => []]],
            ],
            'version' => 2,
        ];
        $jobs = Jobs::fromCron($crons, ['every_ten' => ['interval' => 600, 'display' => 'Every ten minutes']]);
        $key = substr(md5(serialize(['a'])), 0, 8);
        $this->assertSame(['wp:custom:' . $key, 'wp:hourly_thing', 'wp:publish_future_post'], array_keys($jobs));
        $this->assertSame(600, $jobs["wp:custom:{$key}"]['interval'], 'a custom recurrence\'s interval from cron_schedules');
        $this->assertSame('hourly', $jobs['wp:hourly_thing']['recurrence'], 'a recurring event wins over a single one of the same name');
        $this->assertSame([
            'description' => 'WP-Cron hook custom with args ["a"], every_ten (every 10m)',
            'tags' => ['wp-cron'],
            'schedule' => 'every 10m',
        ], Jobs::options($jobs["wp:custom:{$key}"]));
        $this->assertSame(['description' => 'WP-Cron hook publish_future_post, single events', 'tags' => ['wp-cron']], Jobs::options($jobs['wp:publish_future_post']));
    }

    public function testTheSchemaPerServer(): void
    {
        $this->assertSame(['MySQL', '8.4.3'], WpdbStore::server('8.4.3'));
        $this->assertSame(['MariaDB', '10.11.8'], WpdbStore::server('5.5.5-10.11.8-MariaDB'));
        $this->assertSame(['MariaDB', '10.6.21'], WpdbStore::server('10.6.21-MariaDB-log'));
        $this->assertNull(WpdbStore::unsupported('8.0.36'));
        $this->assertNull(WpdbStore::unsupported('5.7.44-log'));
        $this->assertNull(WpdbStore::unsupported('5.5.5-10.3.39-MariaDB'));
        $this->assertStringContainsString('MySQL 5.7.8 or MariaDB 10.3', (string) WpdbStore::unsupported('5.6.51'));
        $this->assertNotNull(WpdbStore::unsupported('5.5.5-10.2.44-MariaDB'));
        $default = "metrics LONGTEXT NOT NULL DEFAULT ('{}')";
        $this->assertStringContainsString($default, WpdbStore::schema('wp_cronwatch_', '8.0.13')[1]);
        $this->assertStringContainsString($default, WpdbStore::schema('wp_cronwatch_', '5.5.5-10.3.39-MariaDB')[1]);
        $old = WpdbStore::schema('wp_cronwatch_', '5.7.44');
        $this->assertStringNotContainsString('DEFAULT (', $old[1], 'MySQL before 8.0.13 takes no expression default');
        $this->assertStringContainsString('metrics LONGTEXT NOT NULL,', $old[1]);
    }

    /** PHP source without its comments and string literals, so only code is searched. */
    private static function codeOnly(string $php): string
    {
        $out = '';
        foreach (token_get_all($php) as $token) {
            if (is_array($token) && in_array($token[0], [T_COMMENT, T_DOC_COMMENT, T_CONSTANT_ENCAPSED_STRING, T_ENCAPSED_AND_WHITESPACE, T_INLINE_HTML], true)) {
                continue;
            }
            $out .= is_array($token) ? $token[1] : $token;
        }
        return $out;
    }

    public function testTheZipHoldsThePluginAndTheLibraryAndNothingElse(): void
    {
        if (!class_exists(\ZipArchive::class)) {
            $this->markTestSkipped('needs the zip extension');
        }
        $dir = sys_get_temp_dir() . '/cronwatch-zip-' . getmypid() . '-' . bin2hex(random_bytes(4));
        $path = WordPressTest::buildZip($dir);
        try {
            $zip = new \ZipArchive();
            $zip->open($path);
            $names = [];
            for ($i = 0; $i < $zip->numFiles; $i++) {
                $names[] = (string) $zip->getNameIndex($i);
            }
            $header = (string) $zip->getFromName('cronwatch/cronwatch.php');
            $stylesheet = $zip->getFromName('cronwatch/css/dashboard.css');
            $adminDashboard = (string) $zip->getFromName('cronwatch/includes/AdminDashboard.php');
            $api = (string) $zip->getFromName('cronwatch/includes/Api.php');
            $zip->close();
            $version = \Cronwatch\Cronwatch::VERSION;
            $this->assertSame("cronwatch-{$version}.zip", basename($path));
            foreach (['cronwatch/cronwatch.php', 'cronwatch/uninstall.php', 'cronwatch/readme.txt', 'cronwatch/includes/Plugin.php',
                'cronwatch/includes/WpdbStore.php', 'cronwatch/lib/src/Cronwatch.php', 'cronwatch/lib/src/Alerts/Slack.php', 'cronwatch/lib/LICENSE'] as $name) {
                $this->assertContains($name, $names);
            }
            foreach ($names as $name) {
                $this->assertStringStartsWith('cronwatch/', $name);
                $this->assertDoesNotMatchRegularExpression('#(^|/)\.|/tests?/|build\.php$|composer\.|phpunit|/dist/|DESIGN\.md$#', $name, "{$name} does not ship");
            }
            $this->assertCount(count(array_unique($names)), $names);
            $this->assertContains('cronwatch/includes/AdminDashboard.php', $names);
            $this->assertContains('cronwatch/lib/src/Web/Dashboard.php', $names);
            // The dashboard's stylesheet is the library's, as a file of the plugin's, which it registers,
            // enqueues and prints through WordPress's styles (AdminDashboard::head()) for every dashboard it makes.
            $this->assertContains('cronwatch/css/dashboard.css', $names);
            $this->assertSame(ltrim(\Cronwatch\Web\Html::CSS, "\n"), $stylesheet);
            $this->assertStringContainsString("public const STYLESHEET = 'css/dashboard.css';", $adminDashboard);
            $this->assertMatchesRegularExpression('/\bwp_register_style\(self::STYLE, plugins_url\(self::STYLESHEET, CRONWATCH_PLUGIN_FILE\)/', $adminDashboard);
            $this->assertMatchesRegularExpression('/\bwp_enqueue_style\(self::STYLE\);/', $adminDashboard);
            $this->assertMatchesRegularExpression('/\bwp_print_styles\(\[self::STYLE\]\);/', $adminDashboard);
            $this->assertMatchesRegularExpression("/new Dashboard\\([^;]*head: \\[self::class, 'head'\\]\\);/", $adminDashboard);
            $this->assertMatchesRegularExpression("/new Dashboard\\([^;]*head: \\[AdminDashboard::class, 'head'\\]\\);/", $api);
            // The library's files the plugin never runs are left out: no curl, no alert channels but Slack and the
            // webhook (the ones its settings offer), no AWS signing, no triage, no standalone page head (with its
            // inline stylesheet and script), no PDO stores, no pg_cron, no PSR adapters, no Laravel or Symfony.
            $leftOut = ['Alerts/NativeHttp.php', 'Cli.php', 'Sources/PgCron.php', 'Sources/PgCronPdo.php', 'Store/MysqlStore.php', 'Store/PdoStore.php',
                'Store/PostgresStore.php', 'Store/SqliteStore.php', 'Web/PsrHandler.php', 'Web/PsrMiddleware.php', 'Web/PsrJobHandler.php',
                'Store/Migrated.php', 'Watch.php', 'Web/StandaloneHead.php', 'Alerts/SigV4.php'];
            foreach (['Bugsnag', 'Datadog', 'Discord', 'Honeybadger', 'Mailgun', 'NewRelic', 'Postmark', 'Resend', 'Rollbar', 'Sendgrid', 'Sentry', 'Ses', 'Twilio'] as $channel) {
                $leftOut[] = "Alerts/{$channel}.php";
            }
            $src = dirname(__DIR__, 2) . '/src';
            // Every channel the library has is either left out or one the plugin runs.
            foreach (glob("{$src}/Alerts/*.php") ?: [] as $file) {
                $relative = 'Alerts/' . basename($file);
                if (!in_array($relative, $leftOut, true)) {
                    $this->assertContains(basename($file, '.php'), ['AlertChannel', 'ChannelContext', 'Console', 'Custom', 'Email', 'Http', 'HttpResponse', 'RequestTimeout', 'Shared', 'Slack', 'Transport', 'Webhook'], "{$relative} is shipped: leave it out, or say why the plugin needs it");
                }
            }
            foreach (['Bridge', 'Laravel', 'Symfony', 'Triage'] as $dir) {
                $files = new \RecursiveIteratorIterator(new \RecursiveDirectoryIterator("{$src}/{$dir}", \FilesystemIterator::SKIP_DOTS));
                foreach ($files as $file) {
                    $relative = substr($file->getPathname(), strlen($src) + 1);
                    $this->assertNotContains("cronwatch/lib/src/{$relative}", $names);
                    if (preg_match('#(^|/)[A-Z][A-Za-z]*\.php$#', $relative) === 1) {
                        $leftOut[] = $relative;
                    }
                }
            }
            foreach ($leftOut as $file) {
                $this->assertNotContains("cronwatch/lib/src/{$file}", $names);
            }
            $zip->open($path);
            for ($i = 0; $i < $zip->numFiles; $i++) {
                $name = (string) $zip->getNameIndex($i);
                $source = (string) $zip->getFromIndex($i);
                $code = str_ends_with($name, '.php') ? self::codeOnly($source) : '';
                if (str_starts_with($name, 'cronwatch/lib/src/') && str_ends_with($name, '.php')) {
                    // build.php's one added line, after the declare, and nothing else changed.
                    $this->assertStringContainsString("\ndeclare(strict_types=1);\n// phpcs:disable WordPress.Security.EscapeOutput.ExceptionNotEscaped -- ", $source, "{$name} carries the exception annotation");
                    $original = (string) file_get_contents(dirname(__DIR__, 2) . '/src/' . substr($name, strlen('cronwatch/lib/src/')));
                    $this->assertSame($original, (string) preg_replace('#\n// phpcs:disable WordPress\.Security\.EscapeOutput\.ExceptionNotEscaped -- [^\n]*#', '', $source, 1), "{$name} is the library's file");
                }
                $this->assertDoesNotMatchRegularExpression('/\bcurl_[a-z_]+\s*\(/', $code, "{$name} calls curl directly");
                $this->assertDoesNotMatchRegularExpression('/\bnew\s+\\\\?PDO\b|\bfsockopen\s*\(/', $code, "{$name} opens its own connection");
                // No script or style element anywhere: the dashboard's stylesheet is enqueued, and there is no script.
                $this->assertDoesNotMatchRegularExpression('/<(script|style)\b/i', $source, "{$name} writes a script or style element");
                foreach ($leftOut as $file) {
                    $class = str_replace('/', '\\', substr($file, 0, -4));
                    $short = basename($file, '.php');
                    $this->assertStringNotContainsString("Cronwatch\\{$class}", $code, "{$name} names a class the zip leaves out");
                    // Within the library a class of the same namespace is named by its short name.
                    if (str_starts_with($name, 'cronwatch/lib/') && !in_array("{$name}:{$short}", ['cronwatch/lib/src/Alerts/Transport.php:NativeHttp', 'cronwatch/lib/src/Web/Html.php:StandaloneHead'], true)) {
                        // Transport makes a NativeHttp only when nothing was set; the plugin sets WpHttp when it boots.
                        // Html uses StandaloneHead only for a Dashboard given no head; the plugin gives each one its own.
                        $this->assertDoesNotMatchRegularExpression('/\bnew\s+(?:\\\\?Cronwatch\\\\[A-Za-z\\\\]+\\\\)?' . $short . '\s*\(|\b' . $short . '::/', $code, "{$name} uses {$short}");
                    }
                }
            }
            $zip->close();
            $this->assertStringContainsString(" * Version:           {$version}\n", $header);
            $this->assertStringContainsString(' * License:           GPLv2 or later', $header);
            // The same sources give the same bytes.
            $again = WordPressTest::buildZip($dir . '/again');
            $this->assertSame(hash_file('sha256', $path), hash_file('sha256', $again));
        } finally {
            foreach ([$path, $dir . '/again/' . basename($path)] as $file) {
                @unlink($file);
            }
            @rmdir($dir . '/again');
            @rmdir($dir);
        }
    }
}
