<?php

declare(strict_types=1);

namespace Cronwatch\Tests\Drupal;

use Cronwatch\Cronwatch;
use Cronwatch\Store\MysqlStore;
use Cronwatch\Store\PostgresStore;
use PHPUnit\Framework\TestCase;

/**
 * The Drupal module in a real Drupal.
 *
 * CRONWATCH_TEST_DRUPAL is the core version to test, as a Composer
 * constraint ("^11.4", "~10.6.0"). A Drupal project is made with Composer
 * in the system's temporary directory (kept between runs, one per
 * constraint and PHP version): drupal/core-recommended, Drush, and this
 * package and the module from their directories (path repositories,
 * symlinked, so the code under test is the working tree's). Each run
 * installs a fresh site with `drush site:install minimal` on the database
 * CRONWATCH_TEST_DRUPAL_DB names (a mysql:// or postgres:// URL, its tables
 * under a prefix of their own, dropped afterwards; default a SQLite file in
 * the site), enables the module and fixtures/cwt_fixtures, and drives it as
 * a site is driven: `drush cron`, `drush queue:run`, `drush cronwatch:check`,
 * /cron/<key> and the admin pages under PHP's built-in server, signed in
 * with one-time login links.
 *
 * Drupal's own test runner (a KernelTestBase or BrowserTestBase in a
 * Drupal checkout) was passed over: it needs core's development
 * dependencies and its own PHPUnit, installs each test's site under a
 * random table prefix with SQLite tables attached as separate files, and
 * runs cron inside the test process, which hides what needs testing here
 * (the library's own connection to the site's real tables, a cron run in a
 * process of its own, Drush, the web routes).
 *
 * The tests share one site and run in order; the last uninstalls the module.
 */
final class DrupalTest extends TestCase
{
    /** The Ultimate Cron release the module's support for it was written against, installed for its tests only. */
    private const ULTIMATE_CRON = '2.0.0-beta1';

    private static ?string $skip = null;
    private static string $root = '';
    private static string $web = '';
    private static string $db = '';
    /** The SQLite file, as the site's settings name it (Drupal 11 keeps the path relative to the web root; 10 makes it absolute). */
    private static string $sqlite = '';
    private static string $prefix = '';
    private static int $port = 0;
    /** @var resource|null */
    private static $server = null;
    /** @var array<string, array<string, string>> cookie jars by user */
    private static array $jars = [];

    public static function setUpBeforeClass(): void
    {
        $constraint = (string) getenv('CRONWATCH_TEST_DRUPAL');
        if ($constraint === '') {
            self::$skip = 'set CRONWATCH_TEST_DRUPAL to a drupal/core constraint (^11.4, ~10.6.0) to run';
            return;
        }
        if (!function_exists('proc_open') || !extension_loaded('pdo_sqlite')) {
            self::$skip = 'needs proc_open and pdo_sqlite';
            return;
        }
        self::$skip = null;
        self::$db = (string) (getenv('CRONWATCH_TEST_DRUPAL_DB') ?: 'sqlite');
        self::$root = self::project($constraint);
        self::$web = self::$root . '/web';
        self::$port = self::freePort();
        self::$prefix = self::$db === 'sqlite' ? '' : 'cwd' . getmypid() . '_';

        // A fresh site: settings.php and files from the last run go first.
        $default = self::$web . '/sites/default';
        @chmod($default, 0755);
        @unlink("{$default}/settings.php");
        self::remove("{$default}/files");
        self::remove(self::$web . '/modules/custom');
        mkdir(self::$web . '/modules/custom', 0777, true);
        self::copy(__DIR__ . '/fixtures/cwt_fixtures', self::$web . '/modules/custom/cwt_fixtures');

        $dbUrl = match (true) {
            // A path relative to the web root, as the installer writes one.
            self::$db === 'sqlite' => 'sqlite://localhost/sites/default/files/.ht.sqlite',
            str_starts_with(self::$db, 'postgres') => 'pgsql://' . substr(self::$db, strpos(self::$db, '://') + 3),
            default => self::$db,
        };
        $install = ['site:install', 'minimal', "--db-url={$dbUrl}", '--account-name=admin', '--account-pass=' . bin2hex(random_bytes(8)),
            '--site-name=CronWatch test', '--site-mail=site@example.com', '--account-mail=admin@example.com', '-y'];
        if (self::$prefix !== '') {
            $install[] = '--db-prefix=' . self::$prefix;
        }
        self::must($install);
        // The site's base URL, for alert links and one-time login links.
        @chmod($default, 0755);
        @chmod("{$default}/settings.php", 0644);
        file_put_contents("{$default}/settings.php", "\n\$settings['trusted_host_patterns'] = ['^127\\.0\\.0\\.1\$'];\n", FILE_APPEND);
        self::must(['pm:install', 'cronwatch', 'cwt_fixtures', 'automated_cron', '-y']);
        self::must(['role:create', 'viewer', 'Viewer']);
        self::must(['role:perm:add', 'viewer', 'view cronwatch dashboard']);
        self::must(['user:create', 'viewer', '--mail=viewer@example.com', '--password=' . bin2hex(random_bytes(8))]);
        self::must(['user:role:add', 'viewer', 'viewer']);
    }

    public static function tearDownAfterClass(): void
    {
        if (self::$skip !== null || self::$root === '') {
            return;
        }
        self::stopServer();
        if (self::$db !== 'sqlite') {
            $pdo = self::pdo();
            if (str_starts_with(self::$db, 'postgres')) {
                $tables = $pdo->query("SELECT tablename FROM pg_tables WHERE schemaname = current_schema() AND tablename LIKE " . $pdo->quote(self::$prefix . '%'))->fetchAll(\PDO::FETCH_COLUMN);
                foreach ($tables as $table) {
                    $pdo->exec("DROP TABLE IF EXISTS \"{$table}\" CASCADE");
                }
            } else {
                $tables = $pdo->query('SHOW TABLES LIKE ' . $pdo->quote(self::$prefix . '%'))->fetchAll(\PDO::FETCH_COLUMN);
                foreach ($tables as $table) {
                    $pdo->exec("DROP TABLE IF EXISTS `{$table}`");
                }
            }
        }
    }

    protected function setUp(): void
    {
        if (self::$skip !== null) {
            $this->markTestSkipped(self::$skip);
        }
    }

    // ------------------------------------------------------------ the project

    /**
     * The Drupal project for a core constraint, made with Composer when it is
     * not there yet, and its path.
     */
    private static function project(string $constraint): string
    {
        $dir = sys_get_temp_dir() . '/cronwatch-drupal-' . substr(md5($constraint . '|' . PHP_MAJOR_VERSION . '.' . PHP_MINOR_VERSION . '|' . dirname(__DIR__, 2) . '|' . self::ULTIMATE_CRON), 0, 10);
        if (is_file("{$dir}/vendor/autoload.php") && is_file("{$dir}/vendor/bin/drush")) {
            return $dir;
        }
        @mkdir($dir, 0777, true);
        $library = dirname(__DIR__, 2);
        $version = Cronwatch::VERSION;
        $composer = [
            'name' => 'cronwatch/drupal-test-site',
            'type' => 'project',
            'repositories' => [
                ['type' => 'path', 'url' => $library, 'options' => ['symlink' => true, 'versions' => ['cronwatch/cronwatch' => $version]]],
                ['type' => 'path', 'url' => "{$library}/drupal", 'options' => ['symlink' => true, 'versions' => ['drupal/cronwatch' => $version]]],
                ['type' => 'composer', 'url' => 'https://packages.drupal.org/8', 'exclude' => ['drupal/cronwatch']],
            ],
            'require' => [
                'composer/installers' => '^2.3',
                'cronwatch/cronwatch' => $version,
                'drupal/core-composer-scaffold' => $constraint,
                'drupal/core-recommended' => $constraint,
                'drupal/cronwatch' => $version,
                'drupal/ultimate_cron' => self::ULTIMATE_CRON,
                'drush/drush' => '^13.3',
            ],
            'minimum-stability' => 'stable',
            'prefer-stable' => true,
            'config' => [
                'allow-plugins' => [
                    'composer/installers' => true,
                    'drupal/core-composer-scaffold' => true,
                    'php-http/discovery' => true,
                    'php-tuf/composer-integration' => true,
                    'symfony/runtime' => true,
                    'tbachert/spi' => false,
                    'dealerdirect/phpcodesniffer-composer-installer' => false,
                    'phpstan/extension-installer' => false,
                ],
                'sort-packages' => true,
                // The version under test is chosen by the test, advisories or not (Composer 2.9 and newer block them).
                'audit' => ['block-insecure' => false],
                'policy' => ['advisories' => ['block' => false]],
            ],
            'extra' => [
                'drupal-scaffold' => ['locations' => ['web-root' => 'web/']],
                'installer-paths' => [
                    'web/core' => ['type:drupal-core'],
                    'web/modules/contrib/{$name}' => ['type:drupal-module'],
                    'web/profiles/contrib/{$name}' => ['type:drupal-profile'],
                    'web/themes/contrib/{$name}' => ['type:drupal-theme'],
                ],
            ],
        ];
        file_put_contents("{$dir}/composer.json", json_encode($composer, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . "\n");
        $bin = (string) (getenv('CRONWATCH_TEST_COMPOSER') ?: 'composer');
        [$code, $out, $err] = self::exec([$bin, 'update', '--no-interaction', '--no-progress', "--working-dir={$dir}"]);
        if ($code !== 0) {
            throw new \RuntimeException("composer update for Drupal {$constraint} failed:\n{$out}\n{$err}");
        }
        return $dir;
    }

    // ------------------------------------------------------------ helpers

    /**
     * @param list<string> $command
     * @param array<string, string>|null $env
     * @return array{int, string, string}
     */
    private static function exec(array $command, ?string $cwd = null, ?array $env = null): array
    {
        $process = proc_open($command, [0 => ['file', '/dev/null', 'r'], 1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes, $cwd, $env);
        if (!is_resource($process)) {
            throw new \RuntimeException('could not start ' . $command[0]);
        }
        $out = stream_get_contents($pipes[1]);
        $err = stream_get_contents($pipes[2]);
        fclose($pipes[1]);
        fclose($pipes[2]);
        return [proc_close($process), (string) $out, (string) $err];
    }

    /**
     * A Drush command on the test site.
     *
     * @param list<string> $args
     * @return array{int, string, string}
     */
    private static function drush(array $args): array
    {
        return self::exec([PHP_BINARY, '-d', 'error_reporting=' . (E_ALL & ~E_DEPRECATED), self::$root . '/vendor/bin/drush.php',
            '--root=' . self::$web, '--uri=http://127.0.0.1:' . self::$port, ...$args], self::$root);
    }

    /** @param list<string> $args */
    private static function must(array $args): string
    {
        [$code, $out, $err] = self::drush($args);
        if ($code !== 0) {
            throw new \RuntimeException('drush ' . implode(' ', $args) . " exited {$code}:\n{$out}\n{$err}");
        }
        return $out;
    }

    /** Runs PHP inside Drupal (drush php:eval) and returns what it echoes as JSON on its last line. */
    private static function inDrupal(string $code): mixed
    {
        [$status, $out, $err] = self::drush(['php:eval', $code]);
        $lines = preg_split('/\R/', trim($out)) ?: [];
        $last = (string) end($lines);
        $value = json_decode($last, true);
        if ($status !== 0 || json_last_error() !== JSON_ERROR_NONE) {
            throw new \RuntimeException("php:eval exited {$status}:\n{$out}\n{$err}");
        }
        return $value;
    }

    private static function pdo(): \PDO
    {
        if (self::$db === 'sqlite') {
            if (self::$sqlite === '') {
                $path = (string) self::inDrupal("echo json_encode(\\Drupal\\Core\\Database\\Database::getConnectionInfo()['default']['database']);");
                self::$sqlite = str_starts_with($path, '/') ? $path : self::$web . '/' . $path;
            }
            return new \PDO('sqlite:' . self::$sqlite, null, null, [\PDO::ATTR_ERRMODE => \PDO::ERRMODE_EXCEPTION]);
        }
        [$dsn, $user, $password] = str_starts_with(self::$db, 'postgres') ? PostgresStore::connection(self::$db) : MysqlStore::connection(self::$db);
        return new \PDO($dsn, $user, $password, [\PDO::ATTR_ERRMODE => \PDO::ERRMODE_EXCEPTION]);
    }

    private static function table(string $name): string
    {
        return self::$prefix . 'cronwatch_' . $name;
    }

    /** @return list<array<string, mixed>> a job's runs, oldest first, straight from the table */
    private static function runs(string $job): array
    {
        $order = self::$db === 'sqlite' ? 'rowid' : 'seq';
        $statement = self::pdo()->prepare('SELECT * FROM ' . self::table('runs') . " WHERE job = ? ORDER BY started_at, {$order}");
        $statement->execute([$job]);
        return $statement->fetchAll(\PDO::FETCH_ASSOC);
    }

    /** @return array<string, mixed> a job's newest run */
    private static function last(string $job): array
    {
        $runs = self::runs($job);
        return $runs === [] ? [] : $runs[count($runs) - 1];
    }

    /** @return array<string, mixed>|null */
    private static function definition(string $job): ?array
    {
        $statement = self::pdo()->prepare('SELECT definition FROM ' . self::table('jobs') . ' WHERE name = ?');
        $statement->execute([$job]);
        $json = $statement->fetchColumn();
        return $json === false ? null : json_decode((string) $json, true);
    }

    /** @return list<array{type: string, job: string, title: string}> the alerts the fixture channel kept */
    private static function alerts(): array
    {
        return (array) self::inDrupal("echo json_encode(\\Drupal::state()->get('cwt.alerts', []));");
    }

    private static function setState(string $key, mixed $value): void
    {
        self::inDrupal('\Drupal::state()->set(' . var_export($key, true) . ', ' . var_export($value, true) . '); echo json_encode(true);');
    }

    /** @param list<string> $queues the watched queue workers, as the settings form saves them */
    private static function setQueues(array $queues): void
    {
        self::inDrupal("\\Drupal::configFactory()->getEditable('cronwatch.settings')->set('queues', " . var_export($queues, true) . ")->save(); echo json_encode(TRUE);");
    }

    private static function freePort(): int
    {
        $socket = stream_socket_server('tcp://127.0.0.1:0');
        $name = stream_socket_get_name($socket, false);
        fclose($socket);
        return (int) substr((string) $name, strrpos((string) $name, ':') + 1);
    }

    private static function startServer(): void
    {
        if (self::$server !== null) {
            return;
        }
        self::$server = proc_open([PHP_BINARY, '-d', 'display_errors=0', '-d', 'log_errors=1', '-d', 'error_log=' . self::$root . '/php-errors.log',
            '-S', '127.0.0.1:' . self::$port, '-t', self::$web, self::$web . '/.ht.router.php'],
            [0 => ['file', '/dev/null', 'r'], 1 => ['file', self::$root . '/server.log', 'a'], 2 => ['file', self::$root . '/server.log', 'a']], $pipes, self::$web);
        for ($i = 0; $i < 100; $i++) {
            $socket = @stream_socket_client('tcp://127.0.0.1:' . self::$port, $errno, $error, 0.1);
            if ($socket !== false) {
                fclose($socket);
                return;
            }
            usleep(50_000);
        }
        throw new \RuntimeException('the built-in server did not start');
    }

    private static function stopServer(): void
    {
        if (self::$server !== null) {
            proc_terminate(self::$server);
            proc_close(self::$server);
            self::$server = null;
        }
    }

    /**
     * One request to the site, no redirect followed, with a user's cookies.
     *
     * @param array<string, string> $headers
     * @return array{int, array<string, string>, string} the status, the headers (lowercase names) and the body
     */
    private static function http(string $method, string $path, ?string $user = null, array $headers = [], string $body = ''): array
    {
        self::startServer();
        $jar = $user !== null ? (self::$jars[$user] ?? []) : [];
        if ($jar !== []) {
            $headers['Cookie'] = implode('; ', array_map(fn ($k, $v) => "{$k}={$v}", array_keys($jar), $jar));
        }
        $lines = [];
        foreach ($headers as $name => $value) {
            $lines[] = "{$name}: {$value}";
        }
        $context = stream_context_create(['http' => [
            'method' => $method, 'header' => implode("\r\n", $lines), 'content' => $body,
            'ignore_errors' => true, 'follow_location' => 0, 'timeout' => 60,
        ]]);
        $answer = @file_get_contents('http://127.0.0.1:' . self::$port . $path, false, $context);
        $status = 0;
        $out = [];
        foreach ($http_response_header ?? [] as $line) {
            if (preg_match('#^HTTP/\S+ (\d{3})#', $line, $m) === 1) {
                $status = (int) $m[1];
                $out = [];
                continue;
            }
            [$name, $value] = array_pad(explode(':', $line, 2), 2, '');
            $name = strtolower(trim($name));
            if ($name === 'set-cookie' && $user !== null) {
                [$pair] = explode(';', trim($value), 2);
                [$cookie, $content] = array_pad(explode('=', $pair, 2), 2, '');
                if ($content === 'deleted' || $content === '') {
                    unset(self::$jars[$user][$cookie]);
                } else {
                    self::$jars[$user][$cookie] = $content;
                }
            }
            $out[$name] = trim($value);
        }
        return [$status, $out, (string) $answer];
    }

    /** Signs a user in with a one-time login link, keeping the session cookie in their jar. */
    private static function signIn(string $user): void
    {
        self::startServer();
        $link = trim(self::must(['user:login', "--name={$user}", '--no-browser']));
        $path = (string) preg_replace('#^https?://[^/]+#', '', $link);
        self::$jars[$user] = [];
        [$status] = self::http('GET', $path, $user);
        if ($status !== 302 && $status !== 303) {
            throw new \RuntimeException("signing {$user} in answered {$status}");
        }
    }

    private static function remove(string $path): void
    {
        if (is_link($path) || is_file($path)) {
            @chmod($path, 0644);
            @unlink($path);
            return;
        }
        if (!is_dir($path)) {
            return;
        }
        @chmod($path, 0755);
        foreach (scandir($path) ?: [] as $item) {
            if ($item !== '.' && $item !== '..') {
                self::remove("{$path}/{$item}");
            }
        }
        @rmdir($path);
    }

    private static function copy(string $from, string $to): void
    {
        if (is_dir($from)) {
            @mkdir($to, 0777, true);
            foreach (scandir($from) ?: [] as $item) {
                if ($item !== '.' && $item !== '..') {
                    self::copy("{$from}/{$item}", "{$to}/{$item}");
                }
            }
            return;
        }
        copy($from, $to);
    }

    // ------------------------------------------------------------ the tests

    public function testInstallMadeTheLibrarysTables(): void
    {
        $pdo = self::pdo();
        // The tables are the ones the library's own store makes on this database.
        $store = match (true) {
            self::$db === 'sqlite' => new \Cronwatch\Store\SqliteStore(pdo: $pdo, prefix: 'cwtref_'),
            str_starts_with(self::$db, 'postgres') => new PostgresStore(pdo: $pdo, prefix: 'cwtref_'),
            default => new MysqlStore(pdo: $pdo, prefix: 'cwtref_'),
        };
        $store->init();
        try {
            foreach (['jobs', 'runs', 'state'] as $table) {
                $this->assertSame(self::columns($pdo, 'cwtref_' . $table), self::columns($pdo, self::table($table)), $table);
            }
            if (self::$db === 'sqlite') {
                // SQLite keeps the CREATE text: the library's, word for word.
                $statement = $pdo->prepare('SELECT sql FROM sqlite_master WHERE name = ?');
                foreach (['jobs', 'runs', 'state'] as $table) {
                    $statement->execute(['cwtref_' . $table]);
                    $reference = str_replace('cwtref_', self::$prefix . 'cronwatch_', (string) $statement->fetchColumn());
                    $statement->closeCursor();
                    $statement->execute([self::table($table)]);
                    $this->assertSame($reference, (string) $statement->fetchColumn(), "{$table} is the library's CREATE text");
                    $statement->closeCursor();
                }
            }
        } finally {
            foreach (['runs', 'state', 'jobs'] as $table) {
                $pdo->exec("DROP TABLE IF EXISTS cwtref_{$table}");
            }
        }
    }

    /** @return list<string> a table's column names, in order */
    private static function columns(\PDO $pdo, string $table): array
    {
        $statement = $pdo->query("SELECT * FROM {$table} WHERE 1 = 0");
        $names = [];
        for ($i = 0; $i < $statement->columnCount(); $i++) {
            $names[] = (string) $statement->getColumnMeta($i)['name'];
        }
        $statement->closeCursor();
        return $names;
    }

    public function testCronRecordsTheRunAndEachHookCron(): void
    {
        $this->must(['cron']);
        $cron = self::runs('drupal:cron');
        $this->assertCount(1, $cron);
        $this->assertSame('ok', $cron[0]['status']);
        $this->assertSame('drupal-cron', $cron[0]['trigger']);
        $this->assertStringContainsString('cwt_fixtures', (string) $cron[0]['output']);
        $this->assertStringStartsWith('hook_cron: ', (string) $cron[0]['output']);

        $mine = self::runs('drupal:cwt_fixtures');
        $this->assertCount(1, $mine);
        $this->assertSame('ok', $mine[0]['status']);
        $this->assertSame('cwt cron ran', $mine[0]['output']);
        $this->assertSame('ok', self::runs('drupal:system')[0]['status'] ?? null);
        // Each hook ran inside the whole run.
        $this->assertGreaterThanOrEqual((int) $cron[0]['started_at'], (int) $mine[0]['started_at']);
        $this->assertLessThanOrEqual((int) $cron[0]['finished_at'], (int) $mine[0]['finished_at']);

        $definition = self::definition('drupal:cwt_fixtures');
        $this->assertSame('The fixture module', $definition['description']);
        // The integration's tag, and this site's under it (from its UUID).
        $this->assertCount(2, $definition['tags']);
        $this->assertSame('drupal-cron', $definition['tags'][0]);
        $this->assertMatchesRegularExpression('/^drupal-cron:[0-9a-f-]{36}$/', $definition['tags'][1]);
        $this->assertArrayNotHasKey('schedule', $definition, 'a hook_cron has no schedule of its own');
        // Automated Cron is on, at its default interval.
        $this->assertSame('every 3h', self::definition('drupal:cron')['schedule']);
    }

    public function testAHookCronThatThrowsFailsItsOwnRunOnly(): void
    {
        self::setState('cwt.alerts', []);
        self::setState('cwt.cron_mode', 'throw');
        $this->must(['cron']);
        $mine = self::runs('drupal:cwt_fixtures');
        $last = end($mine);
        $this->assertSame('failed', $last['status']);
        $this->assertStringStartsWith('RuntimeException: cwt cron broke', (string) $last['error']);
        $this->assertStringContainsString('cwt cron ran', (string) $last['output']);
        $cron = self::runs('drupal:cron');
        $this->assertSame('ok', end($cron)['status'], 'core carries on past an exception, so the cron run is ok');
        $this->assertStringContainsString("failed: cwt_fixtures", (string) end($cron)['output']);
        $this->assertCount(2, self::runs('drupal:system'), 'the other modules still ran');
        $this->assertSame([['type' => 'failed', 'job' => 'drupal:cwt_fixtures']], array_map(fn ($a) => ['type' => $a['type'], 'job' => $a['job']], self::alerts()));

        self::setState('cwt.cron_mode', 'ok');
        $this->must(['cron']);
        $this->assertSame('ok', self::last('drupal:cwt_fixtures')['status']);
        $this->assertSame(['failed', 'recovered'], array_column(self::alerts(), 'type'));
    }

    public function testAModuleWithTwoCronHooksIsOneRunOfItsJob(): void
    {
        $version = (string) self::inDrupal('echo json_encode(\Drupal::VERSION);');
        if (version_compare($version, '11.1', '<')) {
            $this->markTestSkipped("a module has one hook_cron before Drupal 11.1 (this is {$version})");
        }
        self::copy(__DIR__ . '/fixtures/cwt_twice', self::$web . '/modules/custom/cwt_twice');
        $this->must(['pm:install', 'cwt_twice', '-y']);
        try {
            self::setState('cwt.alerts', []);
            self::setState('cwt.twice_mode', 'throw');
            $this->must(['cron']);
            $this->must(['cron']);
            $runs = self::runs('drupal:cwt_twice');
            $this->assertSame(['failed', 'failed'], array_column($runs, 'status'), 'one run per cron run, failed by its first hook');
            $this->assertStringStartsWith('RuntimeException: the first cron hook broke', (string) $runs[1]['error']);
            $this->assertStringContainsString('first ran', (string) $runs[1]['output']);
            $this->assertStringContainsString('second ran', (string) $runs[1]['output']);
            $this->assertStringContainsString('failed: cwt_twice', (string) self::last('drupal:cron')['output']);
            $twice = fn (): array => array_values(array_column(array_filter(self::alerts(), fn ($a) => $a['job'] === 'drupal:cwt_twice'), 'type'));
            $this->assertSame(['failed'], $twice(), 'one alert, not one and a recovery each cron run');

            self::setState('cwt.twice_mode', 'ok');
            $this->must(['cron']);
            $this->assertSame(['failed', 'failed', 'ok'], array_column(self::runs('drupal:cwt_twice'), 'status'));
            $this->assertSame(['failed', 'recovered'], $twice());
        } finally {
            self::setState('cwt.twice_mode', 'ok');
            $this->must(['pm:uninstall', 'cwt_twice', '-y']);
        }
    }

    public function testAnErrorEndsTheCronRunAsCoreLetsIt(): void
    {
        self::setState('cwt.cron_mode', 'error');
        [$code] = self::drush(['cron']);
        $this->assertNotSame(0, $code, 'core does not catch an \Error');
        $last = self::runs('drupal:cwt_fixtures');
        $this->assertSame('failed', end($last)['status']);
        $this->assertStringStartsWith('TypeError: cwt cron hit a type error', (string) end($last)['error']);
        $cron = self::runs('drupal:cron');
        $this->assertSame('failed', end($cron)['status']);
        $this->assertStringStartsWith('TypeError: cwt cron hit a type error', (string) end($cron)['error']);
        // Core leaves its lock behind when a run dies; the next run needs it gone.
        self::setState('cwt.cron_mode', 'ok');
        self::inDrupal("\\Drupal::database()->delete('semaphore')->condition('name', 'cron')->execute(); echo json_encode(true);");
        $this->must(['cron']);
        $this->assertSame('ok', self::last('drupal:cron')['status']);
    }

    public function testTheScheduleIsTheSettingsElseAutomatedCrons(): void
    {
        $this->must(['config:set', 'cronwatch.settings', 'schedule', '*/15 * * * *', '-y']);
        $this->must(['cronwatch:check']);
        $this->assertSame('*/15 * * * *', self::definition('drupal:cron')['schedule']);
        $this->must(['config:set', 'automated_cron.settings', 'interval', '3600', '-y']);
        $this->must(['config:set', 'cronwatch.settings', 'schedule', '', '-y']);
        $this->must(['cronwatch:check']);
        $this->assertSame('every 1h', self::definition('drupal:cron')['schedule']);
        $this->must(['config:set', 'automated_cron.settings', 'interval', '0', '-y']);
        $this->must(['cronwatch:check']);
        $this->assertArrayNotHasKey('schedule', self::definition('drupal:cron'), 'no schedule when cron has none');
        $this->must(['config:set', 'automated_cron.settings', 'interval', '10800', '-y']);
    }

    public function testOneJobTheLibraryRefusesStopsNothingElse(): void
    {
        // A schedule the settings form never saw (a configuration import), and an alter hook's bad option.
        $this->must(['config:set', 'cronwatch.settings', 'schedule', 'every monday', '-y']);
        self::setState('cwt.bad_options', ['drupal:cwt_fixtures' => ['grace' => 'ten minutes']]);
        try {
            $line = trim($this->must(['cronwatch:check']));
            $this->assertMatchesRegularExpression('/^cronwatch: checked \d+ jobs, sent \d+ alerts?$/', $line);
            $this->assertArrayNotHasKey('schedule', self::definition('drupal:cron'), 'declared without the schedule it refused');
            $this->assertSame('hook_cron of the cwt_fixtures module', self::definition('drupal:cwt_fixtures')['description'], 'declared without the alter hooks');
            $cron = count(self::runs('drupal:cron'));
            $mine = count(self::runs('drupal:cwt_fixtures'));
            $this->must(['cron']);
            $this->assertCount($cron + 1, self::runs('drupal:cron'), 'the cron run is still recorded');
            $this->assertSame('ok', self::last('drupal:cron')['status']);
            $this->assertCount($mine + 1, self::runs('drupal:cwt_fixtures'));
        } finally {
            self::setState('cwt.bad_options', []);
            $this->must(['config:set', 'cronwatch.settings', 'schedule', '', '-y']);
        }
        $this->must(['cronwatch:check']);
        $this->assertSame('every 3h', self::definition('drupal:cron')['schedule']);
        $this->assertSame('The fixture module', self::definition('drupal:cwt_fixtures')['description']);
    }

    public function testTheCheckReportsCronMissedAndTheNextRunRecovers(): void
    {
        self::setState('cwt.alerts', []);
        // The check a cron run ends with would itself report missed whenever
        // the run took longer than the schedule and grace (2s here), leaving
        // nothing for cronwatch:check to send. Only the explicit check runs.
        $this->must(['config:set', 'cronwatch.settings', 'check_on_cron', '0', '-y']);
        $this->must(['config:set', 'cronwatch.settings', 'schedule', 'every 1s', '-y']);
        $this->must(['config:set', 'cronwatch.settings', 'grace', '1s', '-y']);
        $this->must(['cron']);
        sleep(3);
        $line = trim($this->must(['cronwatch:check']));
        $this->assertMatchesRegularExpression('/^cronwatch: checked \d+ jobs, sent 1 alert$/', $line);
        $this->assertSame([['type' => 'missed', 'job' => 'drupal:cron']], array_map(fn ($a) => ['type' => $a['type'], 'job' => $a['job']], self::alerts()));
        $this->must(['cron']);
        $this->assertSame(['missed', 'recovered'], array_column(self::alerts(), 'type'));
        $this->must(['config:set', 'cronwatch.settings', 'schedule', '', '-y']);
        $this->must(['config:set', 'cronwatch.settings', 'grace', '10m', '-y']);
        $this->must(['config:set', 'cronwatch.settings', 'check_on_cron', '1', '-y']);
    }

    public function testQueueWorkersOptInAndEachAttemptIsARun(): void
    {
        self::setState('cwt.alerts', []);
        self::setQueues(['cwt_flaky']);
        $this->must(['cache:rebuild']);
        self::inDrupal(<<<'PHP'
            $queue = \Drupal::queue('cwt_flaky');
            $queue->createItem(['id' => 'a', 'succeed_on' => 3]);
            $queue->createItem(['id' => 'r', 'requeue' => TRUE]);
            \Drupal::queue('cwt_marked')->createItem('one');
            echo json_encode(TRUE);
            PHP);
        // A failed item stays claimed until its lease runs out, as in core's
        // cron; the lease is ended by hand between runs so the retry is now.
        for ($i = 0; $i < 3; $i++) {
            $this->must(['queue:run', 'cwt_flaky']);
            self::inDrupal("\\Drupal::database()->update('queue')->fields(['expire' => 0])->condition('name', 'cwt_flaky')->execute(); echo json_encode(TRUE);");
        }
        $this->must(['queue:run', 'cwt_marked']);

        $flaky = self::runs('drupal:queue:cwt_flaky');
        $this->assertSame(['drupal-queue'], array_values(array_unique(array_column($flaky, 'trigger'))));
        $a = array_values(array_filter($flaky, fn ($r) => str_contains((string) $r['output'], 'item a ')));
        $this->assertSame(['failed', 'failed', 'ok'], array_column($a, 'status'), 'each attempt is a run');
        $this->assertStringStartsWith('RuntimeException: item a failed attempt 1', (string) $a[0]['error']);
        $r = array_values(array_filter($flaky, fn ($run) => str_contains((string) $run['output'], 'item r ')));
        $this->assertSame(['failed', 'ok'], array_column($r, 'status'));
        $this->assertStringStartsWith('RequeueException: not yet', (string) $r[0]['error']);
        $types = array_map(fn ($x) => [$x['type'], $x['job']], self::alerts());
        $this->assertSame(['failed', 'drupal:queue:cwt_flaky'], $types[0]);
        $this->assertContains(['recovered', 'drupal:queue:cwt_flaky'], $types);
        $tags = self::definition('drupal:queue:cwt_flaky')['tags'];
        $this->assertCount(2, $tags);
        $this->assertSame('drupal-queue', $tags[0]);
        $this->assertMatchesRegularExpression('/^drupal-queue:[0-9a-f-]{36}$/', $tags[1]);

        $marked = self::runs('cwt-marked');
        $this->assertSame(['ok'], array_column($marked, 'status'), 'a worker with #[Watch] is watched unlisted');
        $this->assertSame('marked one', $marked[0]['output']);
        $definition = self::definition('cwt-marked');
        $this->assertSame('Marks each item', $definition['description'], 'the worker\'s own description wins');
        $this->assertSame('1h', $definition['grace']);
        $this->assertSame(2, $definition['failuresBeforeAlert']);

        // Cron's own processing of a watched queue is recorded the same way.
        self::inDrupal("\\Drupal::queue('cwt_flaky')->createItem(['id' => 'c']); echo json_encode(TRUE);");
        $this->must(['cron']);
        $this->assertSame('ok', self::last('drupal:queue:cwt_flaky')['status']);

        // Taken off the list, a worker's items are no longer runs.
        self::setQueues([]);
        $this->must(['cache:rebuild']);
        $count = count(self::runs('drupal:queue:cwt_flaky'));
        self::inDrupal("\\Drupal::queue('cwt_flaky')->createItem(['id' => 'd']); echo json_encode(TRUE);");
        $this->must(['queue:run', 'cwt_flaky']);
        $this->assertCount($count, self::runs('drupal:queue:cwt_flaky'));
    }

    public function testTheDashboardIsBehindThePermissions(): void
    {
        self::signIn('admin');
        self::signIn('viewer');

        [$status, , $page] = self::http('GET', '/admin/reports/cronwatch', 'admin');
        $this->assertSame(200, $status);
        $this->assertMatchesRegularExpression('#<iframe[^>]+src="/admin/reports/cronwatch/view\?cw=/"#', $page);

        [$status, $headers, $page] = self::http('GET', '/admin/reports/cronwatch/view?cw=/', 'admin');
        $this->assertSame(200, $status);
        $this->assertStringStartsWith('text/html', $headers['content-type']);
        $this->assertStringContainsString('drupal:cron', $page);
        $this->assertStringNotContainsString('__cronwatch_embedded__', $page, 'every link points into Drupal');
        $this->assertStringNotContainsString('app.js', $page);
        $this->assertStringContainsString("frame-ancestors 'self'", $headers['content-security-policy']);
        $this->assertSame(1, preg_match('#action="(/admin/reports/cronwatch/view\?cw=/check&amp;token=[^"]+)"#', $page, $m), 'forms carry the CSRF token');
        $check = html_entity_decode($m[1]);

        [$status, , $job] = self::http('GET', '/admin/reports/cronwatch/view?cw=' . rawurlencode('/jobs/drupal%3Acron'), 'admin');
        $this->assertSame(200, $status);
        $this->assertSame(1, preg_match('#action="([^"]*cw=(?:/|%2F)jobs(?:/|%2F)drupal%253Acron(?:/|%2F)silence[^"]*)"#', $job, $m), 'the silence form');
        $silence = html_entity_decode($m[1]);

        $origin = ['Origin' => 'http://127.0.0.1:' . self::$port, 'Content-Type' => 'application/x-www-form-urlencoded'];
        [$status] = self::http('POST', (string) preg_replace('/&token=[^&]+/', '', $silence), 'admin', $origin, 'for=1h');
        $this->assertSame(403, $status, 'a change without the CSRF token is refused');
        [$status, $headers] = self::http('POST', $silence, 'viewer', $origin, 'for=1h');
        $this->assertSame(403, $status, 'viewing is not administering');
        [$status, $headers] = self::http('POST', $silence, 'admin', $origin, 'for=1h');
        $this->assertSame(303, $status);
        $this->assertStringContainsString('/admin/reports/cronwatch/view?cw=', $headers['location']);
        $state = self::pdo()->query('SELECT state FROM ' . self::table('state') . " WHERE job = 'drupal:cron'")->fetchColumn();
        $this->assertNotNull(json_decode((string) $state, true)['silencedUntil'] ?? null);
        [$status] = self::http('POST', $check, 'admin', $origin);
        $this->assertSame(303, $status, 'Run check now');

        [$status] = self::http('GET', '/admin/reports/cronwatch/view?cw=/', 'viewer');
        $this->assertSame(200, $status, 'a viewer may look');

        // A bearer means nothing in the embedded dashboard: a viewer's GET of /api/check runs no check.
        [$status, , $body] = self::http('GET', '/admin/reports/cronwatch/view?cw=/api/check', 'viewer', ['Authorization' => 'Bearer anything']);
        $this->assertSame(405, $status, $body);
        // The check by its API path, or with a slash after it, declares every job first too.
        $declared = fn (): int => (int) self::inDrupal("echo json_encode(\\Drupal::state()->get('cwt.declared', 0));");
        $this->assertSame(1, preg_match('/[?&]token=([^&]+)/', $check, $csrf));
        foreach (['/api/check', '/check/', '/api//check/'] as $at) {
            $before = $declared();
            [$status, , $body] = self::http('POST', '/admin/reports/cronwatch/view?cw=' . rawurlencode($at) . '&token=' . $csrf[1], 'admin', $origin);
            $this->assertContains($status, [200, 303], "{$at}: {$body}");
            $this->assertGreaterThan($before, $declared(), "{$at} declares every job first");
        }
        [$status] = self::http('GET', '/admin/reports/cronwatch/view?cw=/');
        $this->assertSame(403, $status, 'an anonymous visitor may not');

        [$status, , $form] = self::http('GET', '/admin/config/system/cronwatch', 'admin');
        $this->assertSame(200, $status);
        $this->assertStringContainsString('Email alerts to', $form);
        $this->assertStringContainsString('Send a test alert', $form);
        [$status] = self::http('GET', '/admin/config/system/cronwatch', 'viewer');
        $this->assertSame(403, $status);
    }

    public function testTheOtherChannelsAreSetInTheFormAndMadeIntoChannels(): void
    {
        self::signIn('admin');
        [$status, , $form] = self::http('GET', '/admin/config/system/cronwatch', 'admin');
        $this->assertSame(200, $status);
        $this->assertStringContainsString('More channels', $form);
        $this->assertStringContainsString('id="edit-resend-api-key"', $form);
        $this->assertStringContainsString('id="edit-newrelic-region"', $form);

        $result = self::inDrupal(<<<'PHP'
            $submit = function (array $values): array {
                $state = (new \Drupal\Core\Form\FormState())->setValues($values + ['grace' => '10m', 'schedule' => '', 'check_on_cron' => 1, 'queues' => []]);
                \Drupal::formBuilder()->submitForm(\Drupal\cronwatch\Form\SettingsForm::class, $state);
                return array_map('strval', $state->getErrors());
            };
            // The test module's capturing channel (a closure) left out.
            $names = fn (): array => array_values(array_map(fn ($c) => $c->name(), array_filter(\Drupal::service('cronwatch.recorder')->channels(), fn ($c) => $c instanceof \Cronwatch\Alerts\AlertChannel)));
            $out = [];
            $out['partial'] = $submit(['resend_api_key' => 're_123', 'resend_to' => 'ops@example.com']);
            $out['partialSaved'] = \Drupal::config('cronwatch.settings')->get('resend_api_key');
            $out['bad'] = $submit(['discord_webhook_url' => 'discord.com/x', 'newrelic_account_id' => 'abc', 'newrelic_license_key' => 'k']);
            $out['ok'] = $submit([
                'discord_webhook_url' => 'https://discord.com/api/webhooks/1/x',
                'resend_api_key' => ' re_123 ', 'resend_from' => 'CronWatch <alerts@example.com>', 'resend_to' => 'ops@example.com',
                'twilio_account_sid' => 'AC1', 'twilio_auth_token' => 't', 'twilio_from' => '+15005550006', 'twilio_to' => '+15551110000',
            ]);
            \Drupal::service('cronwatch.recorder')->reset();
            $out['saved'] = \Drupal::config('cronwatch.settings')->get('resend_api_key');
            $out['names'] = $names();
            // Every field emptied (a programmatic submission takes a field it is not given from the form's defaults).
            $out['cleared'] = $submit(\Cronwatch\Bridge\ChannelSettings::defaults());
            \Drupal::service('cronwatch.recorder')->reset();
            $out['clearedNames'] = $names();
            echo json_encode($out);
            PHP);
        $this->assertSame(['resend_from' => 'Resend: From is required, or clear the other Resend fields to turn it off.'], $result['partial']);
        $this->assertSame('', $result['partialSaved'], 'a form with an error saves nothing');
        $this->assertSame(['discord_webhook_url' => 'Enter an http or https URL.', 'newrelic_account_id' => 'NewRelic needs a numeric accountId'], $result['bad']);
        $this->assertSame([], $result['ok']);
        $this->assertSame('re_123', $result['saved']);
        $this->assertSame(['discord', 'resend', 'twilio'], $result['names']);
        $this->assertSame([], $result['cleared']);
        $this->assertSame([], $result['clearedNames']);
    }

    public function testCronFromItsUrlAndFromAutomatedCron(): void
    {
        $before = count(self::runs('drupal:cron'));
        $key = (string) self::inDrupal("echo json_encode(\\Drupal::state()->get('system.cron_key'));");
        [$status] = self::http('GET', "/cron/{$key}");
        $this->assertSame(204, $status);
        $this->assertCount($before + 1, self::runs('drupal:cron'));

        // Automated Cron runs cron after a page once its interval has passed.
        self::setState('system.cron_last', 0);
        [$status] = self::http('GET', '/user/login');
        $this->assertSame(200, $status);
        $runs = self::runs('drupal:cron');
        $this->assertCount($before + 2, $runs);
        $this->assertSame('ok', end($runs)['status']);
    }

    public function testAlertLinksNeverTakeTheHostOfAVisitorsRequest(): void
    {
        $settings = self::$web . '/sites/default/settings.php';
        @chmod(dirname($settings), 0755);
        @chmod($settings, 0644);
        // A site that trusts any host, with Automated Cron running after a visitor's request.
        file_put_contents($settings, "\$settings['trusted_host_patterns'] = [];\n", FILE_APPEND);
        self::stopServer();
        try {
            self::setState('cwt.alerts', []);
            self::setState('cwt.cron_mode', 'throw');
            self::setState('system.cron_last', 0);
            [$status] = self::http('GET', '/user/login', null, ['Host' => 'cronwatch-login.example']);
            $this->assertSame(200, $status);
            $alerts = self::alerts();
            $this->assertSame([['failed', 'drupal:cwt_fixtures']], array_map(fn ($a) => [$a['type'], $a['job']], $alerts));
            $this->assertSame('', $alerts[0]['link'], 'no link rather than one to the visitor\'s host');

            // With the site's address set, the link is there.
            file_put_contents($settings, "\$settings['cronwatch_base_url'] = 'https://site.example/sub/';\n", FILE_APPEND);
            self::stopServer();
            self::setState('cwt.cron_mode', 'ok');
            self::setState('system.cron_last', 0);
            [$status] = self::http('GET', '/user/password', null, ['Host' => 'cronwatch-login.example']);
            $this->assertSame(200, $status);
            $alerts = self::alerts();
            $this->assertSame('recovered', $alerts[1]['type']);
            $this->assertSame('https://site.example/sub/admin/reports/cronwatch?job=drupal%3Acwt_fixtures', $alerts[1]['link']);
        } finally {
            file_put_contents($settings, "\$settings['trusted_host_patterns'] = ['^127\\.0\\.0\\.1\$'];\n\$settings['cronwatch_base_url'] = NULL;\n", FILE_APPEND);
            self::stopServer();
            self::setState('cwt.cron_mode', 'ok');
        }
        // Under Drush, the link is the site's --uri.
        $this->assertSame('http://127.0.0.1:' . self::$port . '/admin/reports/cronwatch?job=x', self::inDrupal("echo json_encode(\\Drupal::service('cronwatch.recorder')->jobUrl('x'));"));
    }

    public function testTheJsonApiNeedsAToken(): void
    {
        [$status] = self::http('GET', '/cronwatch/api/jobs');
        $this->assertSame(404, $status, 'no token, no API');
        $settings = self::$web . '/sites/default/settings.php';
        @chmod(dirname($settings), 0755);
        @chmod($settings, 0644);
        $token = 'cwt-' . bin2hex(random_bytes(12));
        file_put_contents($settings, "\$settings['cronwatch_token'] = '{$token}';\n", FILE_APPEND);
        self::stopServer();
        [$status, $headers, $body] = self::http('GET', '/cronwatch/api/jobs', null, ['Authorization' => "Bearer {$token}"]);
        $this->assertSame(200, $status);
        $this->assertStringStartsWith('application/json', $headers['content-type']);
        $this->assertStringContainsString('"name":"drupal:cron"', $body);
        [$status, , $body] = self::http('GET', '/cronwatch/api/jobs/drupal%3Acron', null, ['Authorization' => "Bearer {$token}"]);
        $this->assertSame(200, $status);
        $this->assertStringContainsString('"job":"drupal:cron"', $body);
        [$status] = self::http('GET', '/cronwatch/api/jobs', null, ['Authorization' => 'Bearer wrong']);
        $this->assertSame(401, $status);

        // GET /api names the library: the dashboard answers it, not the site's 404 page.
        foreach (['/cronwatch/api', '/cronwatch/api/'] as $path) {
            [$status, $headers, $body] = self::http('GET', $path, null, ['Authorization' => "Bearer {$token}"]);
            $this->assertStringStartsWith('application/json', $headers['content-type'], "{$path}: {$body}");
            $this->assertContains($status, [200, 404], $body);
            $this->assertSame($status === 200 ? ['ok' => true, 'library' => 'cronwatch/cronwatch', 'language' => 'php', 'version' => \Cronwatch\Cronwatch::VERSION, 'api' => 1] : ['ok' => false, 'error' => 'Not found'], json_decode($body, true));
        }
        [$status] = self::http('GET', '/cronwatch/api');
        $this->assertSame(401, $status);

        // A check is prepared (every job declared) only for a caller with the token.
        $declared = fn (): int => (int) self::inDrupal("echo json_encode(\\Drupal::state()->get('cwt.declared', 0));");
        $before = $declared();
        [$status] = self::http('POST', '/cronwatch/api/check', null, ['Authorization' => 'Bearer wrong']);
        $this->assertSame(401, $status);
        [$status] = self::http('POST', '/cronwatch/api/check');
        $this->assertSame(401, $status);
        $this->assertSame($before, $declared(), 'nothing was declared for a caller without the token');
        [$status, , $body] = self::http('POST', '/cronwatch/api/check', null, ['Authorization' => "Bearer {$token}"]);
        $this->assertSame(200, $status);
        $this->assertStringContainsString('"ok":true', $body);
        $this->assertGreaterThan($before, $declared());

        // A platform cron's GET with the token is a check too, declared first; a GET with only the cookie is not one.
        $before = $declared();
        [$status, , $body] = self::http('GET', '/cronwatch/api/check', null, ['Authorization' => "Bearer {$token}"]);
        $this->assertSame(200, $status, $body);
        $this->assertGreaterThan($before, $declared(), 'GET /api/check declares every job first');
        $before = $declared();
        [$status] = self::http('GET', '/cronwatch/api/check', null, ['Cookie' => \Cronwatch\Web\Dashboard::COOKIE . '=' . \Cronwatch\Web\Dashboard::cookieValue($token)]);
        $this->assertSame(405, $status);
        $this->assertSame($before, $declared());
    }

    // ------------------------------------------------------------ Ultimate Cron

    /** Runs PHP in Drupal with Ultimate Cron's job class at hand. */
    private static function job(string $id, string $code): mixed
    {
        return self::inDrupal('$job = \Drupal\ultimate_cron\Entity\CronJob::load(' . var_export($id, true) . '); ' . $code);
    }

    /** Gives an Ultimate Cron job a scheduler and its rules. */
    private static function setRules(string $id, string $scheduler, array $rules): void
    {
        self::job($id, '$job->set("scheduler", ["id" => ' . var_export($scheduler, true) . ', "configuration" => ["rules" => ' . var_export($rules, true) . ', "catch_up" => 0]])->save(); echo json_encode(TRUE);');
    }

    /** The rule "*\/15+@" for a job, worked out here: every 15 minutes from its skew. */
    private static function quarterHours(string $id): string
    {
        $minute = (hexdec(substr(sha1($id), -8)) & 0xff) % 60;
        $minutes = [];
        for ($i = 0; $i < 4; $i++) {
            $minutes[] = ($minute + 15 * $i) % 60;
        }
        sort($minutes);
        return implode(',', $minutes) . ' * * * *';
    }

    public function testUltimateCronRunsEachJobOnItsOwnSchedule(): void
    {
        $before = count(self::runs('drupal:cwt_fixtures'));
        $this->must(['pm:install', 'ultimate_cron', '-y']);
        $this->assertSame(['ultimate_cron', 'Drupal\cronwatch\UltimateCron\WatchedUltimateCron', 'Drupal\cronwatch\UltimateCron\WatchedCronJob'], self::inDrupal(
            'echo json_encode([\Drupal::getContainer()->getParameter("cronwatch.cron_service"), get_class(\Drupal::service("cron")), get_class(\Drupal\ultimate_cron\Entity\CronJob::load("cwt_fixtures_cron"))]);'
        ));
        // A job made for something other than a hook_cron.
        self::inDrupal('\Drupal\ultimate_cron\Entity\CronJob::create(["id" => "cwt_nightly", "title" => "Nightly report", "module" => "cwt_fixtures", "callback" => "Drupal\\\\cwt_fixtures\\\\Nightly::run", "scheduler" => ["id" => "crontab", "configuration" => ["rules" => ["30 2 * * *"], "catch_up" => 0]]])->save(); echo json_encode(TRUE);');

        // The first cron run under Ultimate Cron launches every job, none having run yet.
        $this->must(['cron']);
        $cron = self::last('drupal:cron');
        $this->assertSame('ok', $cron['status']);
        $this->assertSame('drupal-cron', $cron['trigger']);
        $this->assertStringStartsWith('jobs: ', (string) $cron['output']);
        $this->assertStringContainsString('cwt_fixtures_cron', (string) $cron['output']);
        $this->assertStringContainsString('cwt_nightly', (string) $cron['output']);

        $mine = self::runs('drupal:cwt_fixtures');
        $this->assertCount($before + 1, $mine, 'the module\'s hook_cron goes on as the same job');
        $this->assertSame('ok', end($mine)['status']);
        $this->assertSame('ultimate-cron', end($mine)['trigger']);
        $this->assertSame('cwt cron ran', end($mine)['output']);
        $this->assertGreaterThanOrEqual((int) $cron['started_at'], (int) end($mine)['started_at']);

        $zone = (string) self::inDrupal('echo json_encode(\Drupal::config("system.date")->get("timezone.default"));');
        $definition = self::definition('drupal:cwt_fixtures');
        $this->assertSame(self::quarterHours('cwt_fixtures_cron'), $definition['schedule'], 'Simple\'s default, every 15 minutes at the job\'s skew');
        $this->assertSame($zone, $definition['timezone']);
        $this->assertSame('The fixture module', $definition['description'], 'the alter hook still applies');
        $this->assertSame('drupal-cron', $definition['tags'][0]);
        $this->assertSame(self::quarterHours('system_cron'), self::definition('drupal:system')['schedule']);

        $nightly = self::runs('drupal:job:cwt_nightly');
        $this->assertSame(['ok'], array_column($nightly, 'status'));
        $this->assertSame('nightly ran', $nightly[0]['output']);
        $definition = self::definition('drupal:job:cwt_nightly');
        $this->assertSame('30 2 * * *', $definition['schedule']);
        $this->assertSame('Ultimate Cron: Nightly report', $definition['description']);

        self::signIn('admin');
        [$status, , $form] = self::http('GET', '/admin/config/system/cronwatch', 'admin');
        $this->assertSame(200, $status);
        $this->assertStringContainsString('Ultimate Cron runs cron here', $form);

        // A job run on its own (the Run button, drush cron:run) is a run too.
        $this->must(['cron:run', 'cwt_fixtures_cron', '--force']);
        $this->assertSame('ultimate-cron-manual', self::last('drupal:cwt_fixtures')['trigger']);
        $this->assertCount($before + 2, self::runs('drupal:cwt_fixtures'));
    }

    public function testUltimateCronRulesAreReadAsUltimateCronReadsThem(): void
    {
        $cases = [
            ['*/15+@ * * * *', 7, '7,22,37,52 * * * *'],
            ['*/15+@ * * * *', 250, '10,25,40,55 * * * *'],
            ['0+@ */3 * * *', 75, '15 */3 * * *'],
            ['0+@ 0 * * 0', 3, '3 0 * * 0'],
            ['* * * * *', 9, '* * * * *'],
            ['*/10 2-5 * jan-mar mon-fri', 0, '*/10 2-5 * 1-3 1-5'],
            ['0 12 1 */2 1', 0, '0 12 1 */2 1'],
            ['0 0 1 * 7', 0, '0 0 1 * 0'],
            // Every day of the month named: Ultimate Cron goes by the weekday alone.
            ['0 0 1-31 * 1', 0, '0 0 * * 1'],
            ['nonsense', 0, null],
            ['0 0 * 0 *', 0, null],
            // Days 2 to 31 and Monday, both at once: no cron expression says that.
            ['0 0 1-31+1 * 1', 0, null],
        ];
        $read = (array) self::inDrupal('echo json_encode(array_map(fn ($c) => \Drupal\cronwatch\UltimateCron\Rules::expression($c[0], $c[1]), ' . var_export(array_map(fn ($c) => [$c[0], $c[1]], $cases), true) . '));');
        foreach ($cases as $i => [$rule, $skew, $expected]) {
            $this->assertSame($expected, $read[$i][0], "{$rule} at skew {$skew}");
            if ($expected === null) {
                $this->assertIsString($read[$i][1]);
            }
        }
    }

    public function testAFailingUltimateCronJobIsRecordedFailed(): void
    {
        self::setState('cwt.alerts', []);
        self::setState('cwt.cron_mode', 'throw');
        try {
            $this->must(['cron:run', 'cwt_fixtures_cron', '--force']);
            $last = self::last('drupal:cwt_fixtures');
            $this->assertSame('failed', $last['status']);
            $this->assertStringStartsWith('RuntimeException: cwt cron broke', (string) $last['error']);
            $this->assertStringContainsString('cwt cron ran', (string) $last['output']);
            // Ultimate Cron still logs the failure as it did.
            $this->assertSame(3, (int) self::job('cwt_fixtures_cron', 'echo json_encode($job->loadLatestLogEntry()->severity);'));
            $this->assertSame([['failed', 'drupal:cwt_fixtures']], array_map(fn ($a) => [$a['type'], $a['job']], self::alerts()));

            // An \Error too, which Ultimate Cron catches as it catches an exception.
            self::setState('cwt.cron_mode', 'error');
            $this->must(['cron:run', 'cwt_fixtures_cron', '--force']);
            $this->assertStringStartsWith('TypeError: cwt cron hit a type error', (string) self::last('drupal:cwt_fixtures')['error']);

            self::setState('cwt.cron_mode', 'ok');
            $this->must(['cron:run', 'cwt_fixtures_cron', '--force']);
            $this->assertSame('ok', self::last('drupal:cwt_fixtures')['status']);
            $this->assertSame(['failed', 'recovered'], array_column(self::alerts(), 'type'));
        } finally {
            self::setState('cwt.cron_mode', 'ok');
        }
    }

    public function testAnUltimateCronJobThatIsLockedIsNoRun(): void
    {
        $count = count(self::runs('drupal:cwt_fixtures'));
        // Another process holds the job (it is still running there).
        $lock = (string) self::inDrupal('$lock = \Drupal::service("ultimate_cron.lock"); $id = $lock->lock("cwt_fixtures_cron", 3600); $lock->persist($id); echo json_encode($id);');
        try {
            $this->assertNotSame('', $lock);
            $this->must(['cron:run', 'cwt_fixtures_cron', '--force']);
            $this->must(['cron']);
            $this->assertCount($count, self::runs('drupal:cwt_fixtures'), 'Ultimate Cron skipped it, so nothing ran');
        } finally {
            self::inDrupal('\Drupal::service("ultimate_cron.lock")->unlock(' . var_export($lock, true) . '); echo json_encode(TRUE);');
        }
        $this->must(['cron:run', 'cwt_fixtures_cron', '--force']);
        $this->assertCount($count + 1, self::runs('drupal:cwt_fixtures'));
    }

    public function testTheCheckReportsAnUltimateCronJobMissed(): void
    {
        self::setState('cwt.alerts', []);
        $this->must(['config:set', 'cronwatch.settings', 'check_on_cron', '0', '-y']);
        try {
            // The job last ran, and was first seen, three hours ago: its rule
            // (every 15 minutes) has come round since, past the grace.
            $pdo = self::pdo();
            $pdo->exec('UPDATE ' . self::table('runs') . " SET started_at = started_at - 10800000, finished_at = finished_at - 10800000 WHERE job = 'drupal:cwt_fixtures'");
            $pdo->exec('UPDATE ' . self::table('jobs') . " SET created_at = created_at - 10800000 WHERE name = 'drupal:cwt_fixtures'");
            $this->must(['cronwatch:check']);
            $mine = fn (): array => array_values(array_column(array_filter(self::alerts(), fn ($a) => $a['job'] === 'drupal:cwt_fixtures'), 'type'));
            $this->assertSame(['missed'], $mine());
            $this->must(['cron:run', 'cwt_fixtures_cron', '--force']);
            $this->assertSame(['missed', 'recovered'], $mine());
        } finally {
            $this->must(['config:set', 'cronwatch.settings', 'check_on_cron', '1', '-y']);
        }
    }

    public function testAnUltimateCronRuleWithNoCronExpressionIsReportedOnce(): void
    {
        self::setRules('cwt_fixtures_cron', 'crontab', ['0 * * * *', '30 2 * * *']);
        try {
            $reports = (int) self::inDrupal(<<<'PHP'
                $recorder = \Drupal::service('cronwatch.recorder');
                $recorder->prepare();
                $recorder->reset();
                $recorder->prepare();
                $count = 0;
                foreach (\Drupal::database()->select('watchdog', 'w')->fields('w', ['variables'])->condition('type', 'cronwatch')->execute()->fetchCol() as $variables) {
                  $count += str_contains((string) $variables, 'Ultimate Cron job cwt_fixtures_cron') ? 1 : 0;
                }
                echo json_encode($count);
                PHP);
            $this->assertSame(1, $reports, 'reported once, however often the job is declared');
            $this->must(['cron:run', 'cwt_fixtures_cron', '--force']);
            $this->assertSame('ok', self::last('drupal:cwt_fixtures')['status'], 'its runs are still recorded');
            $this->assertArrayNotHasKey('schedule', self::definition('drupal:cwt_fixtures'));

            // A disabled job is not run by Ultimate Cron, so it is never due.
            self::setRules('cwt_fixtures_cron', 'simple', ['*/15+@ * * * *']);
            self::job('cwt_fixtures_cron', '$job->disable()->save(); echo json_encode(TRUE);');
            $this->must(['cronwatch:check']);
            $this->assertArrayNotHasKey('schedule', self::definition('drupal:cwt_fixtures'));
        } finally {
            self::setRules('cwt_fixtures_cron', 'simple', ['*/15+@ * * * *']);
            self::job('cwt_fixtures_cron', '$job->enable()->save(); echo json_encode(TRUE);');
        }
        $this->must(['cronwatch:check']);
        $this->assertSame(self::quarterHours('cwt_fixtures_cron'), self::definition('drupal:cwt_fixtures')['schedule']);
    }

    public function testUninstallingUltimateCronGivesCronBackToCore(): void
    {
        $this->must(['pm:uninstall', 'ultimate_cron', '-y']);
        $this->assertSame(['core', 'Drupal\cronwatch\WatchedCron'], self::inDrupal('echo json_encode([\Drupal::getContainer()->getParameter("cronwatch.cron_service"), get_class(\Drupal::service("cron"))]);'));
        $this->must(['cron']);
        $this->assertStringStartsWith('hook_cron: ', (string) self::last('drupal:cron')['output']);
        $this->assertSame('drupal-cron', self::last('drupal:cwt_fixtures')['trigger']);
        $this->assertArrayNotHasKey('schedule', self::definition('drupal:cwt_fixtures'), 'a hook_cron has no schedule of its own again');
        $nightly = self::definition('drupal:job:cwt_nightly');
        $this->assertArrayNotHasKey('schedule', $nightly, 'a job Ultimate Cron took with it is never missed');
        $this->assertStringEndsWith('(no longer scheduled)', $nightly['description']);
    }

    public function testUninstallDropsTheTables(): void
    {
        self::stopServer();
        $this->must(['pm:uninstall', 'cronwatch', '-y']);
        $pdo = self::pdo();
        foreach (['jobs', 'runs', 'state'] as $table) {
            try {
                $pdo->query('SELECT 1 FROM ' . self::table($table));
                $this->fail(self::table($table) . ' is still there');
            } catch (\PDOException) {
                $this->addToAssertionCount(1);
            }
        }
        // Cron runs as core runs it again.
        $this->must(['cron']);
    }
}
