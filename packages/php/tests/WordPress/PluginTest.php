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
            'description' => 'WP-Cron hook custom with args ["a"], every_ten (every 600s)',
            'tags' => ['wp-cron'],
            'schedule' => 'every 600s',
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
