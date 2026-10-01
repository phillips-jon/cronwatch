<?php

declare(strict_types=1);

namespace Cronwatch\Tests\Craft;

use Cronwatch\Cronwatch;
use Cronwatch\Store\MysqlStore;
use Cronwatch\Store\PostgresStore;
use PHPUnit\Framework\TestCase;

/**
 * The Craft plugin in a real Craft.
 *
 * CRONWATCH_TEST_CRAFT is the Craft version to test, as a Composer
 * constraint ("^5.3", "5.11.*"), and CRONWATCH_TEST_CRAFT_DB the database
 * (a mysql:// or postgres:// URL; Craft runs on nothing else; its tables go
 * under a prefix of their own, dropped afterwards). A Craft project is made
 * with Composer in the system's temporary directory (kept between runs, one
 * per constraint and PHP version): craftcms/cms, and this package and the
 * plugin from their directories (path repositories, symlinked, so the code
 * under test is the working tree's), with the project files a new Craft
 * project has and fixtures/cwt as a module. Each run installs Craft
 * (`craft install`), installs the plugin, and drives it as a site is
 * driven: console commands, `craft queue/run`, `craft cronwatch/check`,
 * and the Control Panel under PHP's built-in server, signed in through
 * Craft's own login action.
 *
 * Craft's own test framework (Codeception with its Craft module) was passed
 * over: it runs each test inside one application instance and transaction,
 * with the plugin installed from fixtures, which hides what needs testing
 * here (the library's own connection to Craft's tables, a command or queue
 * run in a process of its own, the error handler ending a command, the
 * Control Panel's routes, CSRF and permissions).
 *
 * The tests share one install and run in order; the last uninstalls the plugin.
 */
final class CraftTest extends TestCase
{
    private static ?string $skip = null;
    private static string $root = '';
    private static string $db = '';
    private static string $prefix = '';
    private static int $port = 0;
    /** @var resource|null */
    private static $server = null;
    /** @var array<string, array<string, string>> */
    private static array $jars = [];
    /** @var array<string, string> */
    private static array $passwords = [];

    public static function setUpBeforeClass(): void
    {
        $constraint = (string) getenv('CRONWATCH_TEST_CRAFT');
        self::$db = (string) getenv('CRONWATCH_TEST_CRAFT_DB');
        if ($constraint === '' || self::$db === '') {
            self::$skip = 'set CRONWATCH_TEST_CRAFT (a craftcms/cms constraint, ^5.3) and CRONWATCH_TEST_CRAFT_DB (a mysql:// or postgres:// URL) to run';
            return;
        }
        if (!function_exists('proc_open')) {
            self::$skip = 'needs proc_open';
            return;
        }
        self::$skip = null;
        self::$root = self::project($constraint);
        self::$port = self::freePort();
        // Craft allows five characters and the underscore.
        self::$prefix = 'c' . bin2hex(random_bytes(2)) . '_';

        $parts = parse_url(self::$db);
        $postgres = str_starts_with(self::$db, 'postgres');
        @unlink(self::$root . '/config/project/project.yaml');
        self::remove(self::$root . '/config/project');
        self::remove(self::$root . '/storage');
        mkdir(self::$root . '/storage/runtime', 0777, true);
        file_put_contents(self::$root . '/.env', implode("\n", [
            'CRAFT_APP_ID=cronwatch-test',
            'CRAFT_ENVIRONMENT=dev',
            'CRAFT_SECURITY_KEY=' . bin2hex(random_bytes(16)),
            'CRAFT_DEV_MODE=true',
            'CRAFT_ALLOW_ADMIN_CHANGES=true',
            'CRAFT_DB_DRIVER=' . ($postgres ? 'pgsql' : 'mysql'),
            'CRAFT_DB_SERVER=' . ($parts['host'] ?? '127.0.0.1'),
            'CRAFT_DB_PORT=' . ($parts['port'] ?? ($postgres ? 5432 : 3306)),
            'CRAFT_DB_DATABASE=' . ltrim((string) ($parts['path'] ?? ''), '/'),
            'CRAFT_DB_USER=' . rawurldecode((string) ($parts['user'] ?? '')),
            'CRAFT_DB_PASSWORD=' . rawurldecode((string) ($parts['pass'] ?? '')),
            'CRAFT_DB_SCHEMA=public',
            'CRAFT_DB_TABLE_PREFIX=' . self::$prefix,
            'PRIMARY_SITE_URL=http://127.0.0.1:' . self::$port,
            '',
        ]));
        self::$passwords['admin'] = 'Pw' . bin2hex(random_bytes(8));
        self::must(['install', '--interactive=0', '--username=admin', '--password=' . self::$passwords['admin'], '--email=admin@example.com',
            '--site-name=CronWatch test', '--site-url=http://127.0.0.1:' . self::$port, '--language=en-US']);
        self::must(['plugin/install', 'cronwatch']);
        // Pro, which a dev install may try, for a second user with permissions of its own.
        self::$passwords['viewer'] = 'Pw' . bin2hex(random_bytes(8));
        $password = self::quote(self::$passwords['viewer']);
        self::exec_(<<<PHP
            Craft::\$app->setEdition(craft\\enums\\CmsEdition::Pro);
            \$user = new craft\\elements\\User(['username' => 'viewer', 'email' => 'viewer@example.com', 'newPassword' => '{$password}']);
            \$user->active = true;
            Craft::\$app->getElements()->saveElement(\$user, false);
            Craft::\$app->getUserPermissions()->saveUserPermissions(\$user->id, ['accessCp', 'accessPlugin-cronwatch']);
            PHP);
    }

    public static function tearDownAfterClass(): void
    {
        if (self::$skip !== null || self::$root === '') {
            return;
        }
        self::stopServer();
        $pdo = self::pdo();
        if (str_starts_with(self::$db, 'postgres')) {
            $tables = $pdo->query("SELECT tablename FROM pg_tables WHERE schemaname = 'public' AND tablename LIKE " . $pdo->quote(self::$prefix . '%'))->fetchAll(\PDO::FETCH_COLUMN);
            foreach ($tables as $table) {
                $pdo->exec("DROP TABLE IF EXISTS \"{$table}\" CASCADE");
            }
        } else {
            $pdo->exec('SET FOREIGN_KEY_CHECKS = 0');
            $tables = $pdo->query('SHOW TABLES LIKE ' . $pdo->quote(self::$prefix . '%'))->fetchAll(\PDO::FETCH_COLUMN);
            foreach ($tables as $table) {
                $pdo->exec("DROP TABLE IF EXISTS `{$table}`");
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

    /** The Craft project for a constraint, made with Composer when it is not there yet. */
    private static function project(string $constraint): string
    {
        $dir = sys_get_temp_dir() . '/cronwatch-craft-' . substr(md5($constraint . '|' . PHP_MAJOR_VERSION . '.' . PHP_MINOR_VERSION . '|' . dirname(__DIR__, 2)), 0, 10);
        $library = dirname(__DIR__, 2);
        // The project's own files, as a new Craft project has them, and the fixtures.
        @mkdir("{$dir}/web", 0777, true);
        @mkdir("{$dir}/config", 0777, true);
        @mkdir("{$dir}/templates", 0777, true);
        self::remove("{$dir}/modules");
        self::copy(__DIR__ . '/fixtures/cwt', "{$dir}/modules/cwt");
        file_put_contents("{$dir}/bootstrap.php", <<<'PHP'
            <?php
            error_reporting(E_ALL & ~E_DEPRECATED & ~E_USER_DEPRECATED);
            define('CRAFT_BASE_PATH', __DIR__);
            define('CRAFT_VENDOR_PATH', CRAFT_BASE_PATH . '/vendor');
            require_once CRAFT_VENDOR_PATH . '/autoload.php';
            Dotenv\Dotenv::createImmutable(CRAFT_BASE_PATH)->safeLoad();
            PHP);
        file_put_contents("{$dir}/craft", <<<'PHP'
            <?php
            require __DIR__ . '/bootstrap.php';
            $app = require CRAFT_VENDOR_PATH . '/craftcms/cms/bootstrap/console.php';
            exit($app->run());
            PHP);
        file_put_contents("{$dir}/web/index.php", <<<'PHP'
            <?php
            require dirname(__DIR__) . '/bootstrap.php';
            $app = require CRAFT_VENDOR_PATH . '/craftcms/cms/bootstrap/web.php';
            $app->run();
            PHP);
        // PHP's built-in server: files as they are, everything else to Craft.
        file_put_contents("{$dir}/web/router.php", <<<'PHP'
            <?php
            $path = parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH);
            if ($path !== '/' && is_file(__DIR__ . $path)) {
                return false;
            }
            $_SERVER['SCRIPT_NAME'] = '/index.php';
            $_SERVER['SCRIPT_FILENAME'] = __DIR__ . '/index.php';
            require __DIR__ . '/index.php';
            PHP);
        file_put_contents("{$dir}/config/general.php", <<<'PHP'
            <?php
            use craft\config\GeneralConfig;
            return GeneralConfig::create()
                ->omitScriptNameInUrls()
                ->devMode(true)
                ->allowAdminChanges(true)
                ->runQueueAutomatically(false)
                ->aliases(['@webroot' => dirname(__DIR__) . '/web', '@web' => craft\helpers\App::env('PRIMARY_SITE_URL')]);
            PHP);
        file_put_contents("{$dir}/config/app.php", <<<'PHP'
            <?php
            return ['modules' => ['cwt' => cwt\Module::class], 'bootstrap' => ['cwt']];
            PHP);
        file_put_contents("{$dir}/config/cronwatch.php", <<<'PHP'
            <?php
            return [
                'commands' => [
                    'cwt/task/hello' => ['schedule' => '0 3 * * *', 'timezone' => 'UTC'],
                    'cwt/task/fail' => true,
                    'cwt/task/boom' => ['name' => 'cwt-boom', 'description' => 'The command that breaks'],
                    'cwt/task/nested' => true,
                    'cwt/task/inner' => true,
                ],
                'queueJobs' => [cwt\jobs\Flaky::class => true],
            ];
            PHP);
        if (is_file("{$dir}/vendor/autoload.php")) {
            return $dir;
        }
        $version = Cronwatch::VERSION;
        $composer = [
            'name' => 'cronwatch/craft-test-site',
            'type' => 'project',
            'repositories' => [
                ['type' => 'path', 'url' => $library, 'options' => ['symlink' => true, 'versions' => ['cronwatch/cronwatch' => $version]]],
                ['type' => 'path', 'url' => "{$library}/craft", 'options' => ['symlink' => true, 'versions' => ['cronwatch/craft' => $version]]],
            ],
            'require' => [
                'craftcms/cms' => $constraint,
                'cronwatch/craft' => $version,
                'cronwatch/cronwatch' => $version,
                'vlucas/phpdotenv' => '^5.4',
            ],
            'autoload' => ['psr-4' => ['cwt\\' => 'modules/cwt/']],
            'minimum-stability' => 'stable',
            'prefer-stable' => true,
            'config' => [
                'allow-plugins' => ['craftcms/plugin-installer' => true, 'yiisoft/yii2-composer' => true],
                'sort-packages' => true,
                // The version under test is chosen by the test, advisories or not (Composer 2.9 and newer block them).
                'audit' => ['block-insecure' => false],
                'policy' => ['advisories' => ['block' => false]],
            ],
        ];
        file_put_contents("{$dir}/composer.json", json_encode($composer, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . "\n");
        $bin = (string) (getenv('CRONWATCH_TEST_COMPOSER') ?: 'composer');
        [$code, $out, $err] = self::exec([$bin, 'update', '--no-interaction', '--no-progress', "--working-dir={$dir}"]);
        if ($code !== 0) {
            throw new \RuntimeException("composer update for Craft {$constraint} failed:\n{$out}\n{$err}");
        }
        return $dir;
    }

    // ------------------------------------------------------------ helpers

    /**
     * @param list<string> $command
     * @return array{int, string, string}
     */
    private static function exec(array $command, ?string $cwd = null): array
    {
        $process = proc_open($command, [0 => ['file', '/dev/null', 'r'], 1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes, $cwd);
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
     * A craft console command.
     *
     * @param list<string> $args
     * @return array{int, string, string}
     */
    private static function craft(array $args): array
    {
        return self::exec([PHP_BINARY, self::$root . '/craft', ...$args], self::$root);
    }

    /** @param list<string> $args */
    private static function must(array $args): string
    {
        [$code, $out, $err] = self::craft($args);
        if ($code !== 0) {
            throw new \RuntimeException('craft ' . implode(' ', $args) . " exited {$code}:\n{$out}\n{$err}");
        }
        return $out;
    }

    /** Runs PHP statements inside Craft (a file `craft exec` includes). */
    private static function exec_(string $code): void
    {
        $file = self::$root . '/storage/runtime/cwt-exec-' . bin2hex(random_bytes(4)) . '.php';
        file_put_contents($file, "<?php\n" . $code . "\n");
        try {
            self::must(['exec', 'require ' . var_export($file, true)]);
        } finally {
            @unlink($file);
        }
    }

    /** Text for a PHP single-quoted string. */
    private static function quote(string $text): string
    {
        return str_replace(['\\', "'"], ['\\\\', "\\'"], $text);
    }

    private static function pdo(): \PDO
    {
        [$dsn, $user, $password] = str_starts_with(self::$db, 'postgres') ? PostgresStore::connection(self::$db) : MysqlStore::connection(self::$db);
        return new \PDO($dsn, $user, $password, [\PDO::ATTR_ERRMODE => \PDO::ERRMODE_EXCEPTION]);
    }

    private static function table(string $name): string
    {
        return self::$prefix . 'cronwatch_' . $name;
    }

    /** @return list<array<string, mixed>> */
    private static function runs(string $job): array
    {
        $statement = self::pdo()->prepare('SELECT * FROM ' . self::table('runs') . ' WHERE job = ? ORDER BY started_at, seq');
        $statement->execute([$job]);
        return $statement->fetchAll(\PDO::FETCH_ASSOC);
    }

    /** @return array<string, mixed> */
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

    /** @return list<array{type: string, job: string, title: string}> */
    private static function alerts(): array
    {
        $file = self::$root . '/storage/runtime/cwt-alerts.json';
        return is_file($file) ? (array) json_decode((string) file_get_contents($file), true) : [];
    }

    private static function clearAlerts(): void
    {
        @unlink(self::$root . '/storage/runtime/cwt-alerts.json');
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
            '-S', '127.0.0.1:' . self::$port, '-t', self::$root . '/web', self::$root . '/web/router.php'],
            [0 => ['file', '/dev/null', 'r'], 1 => ['file', self::$root . '/server.log', 'a'], 2 => ['file', self::$root . '/server.log', 'a']], $pipes, self::$root . '/web');
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
     * One request, no redirect followed, with a user's cookies.
     *
     * @param array<string, string> $headers
     * @return array{int, array<string, string>, string}
     */
    private static function http(string $method, string $path, ?string $user = null, array $headers = [], string $body = ''): array
    {
        self::startServer();
        // Craft makes no session for a request without a user agent.
        $headers += ['User-Agent' => 'cronwatch-test'];
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
                if ($content === 'deleted' || $content === '' || str_contains(strtolower($value), 'max-age=0')) {
                    unset(self::$jars[$user][$cookie]);
                } else {
                    self::$jars[$user][$cookie] = $content;
                }
            }
            $out[$name] = trim($value);
        }
        return [$status, $out, (string) $answer];
    }

    /** The CSRF token for a user's session, from Craft's session-info action. */
    private static function csrf(string $user): string
    {
        [$status, , $body] = self::http('GET', '/actions/users/session-info', $user, ['Accept' => 'application/json']);
        $info = json_decode($body, true);
        if ($status !== 200 || !is_string($info['csrfTokenValue'] ?? null)) {
            throw new \RuntimeException("session-info answered {$status}: {$body}");
        }
        return $info['csrfTokenValue'];
    }

    /** Signs a user in through Craft's login action, keeping the session in their jar. */
    private static function signIn(string $user): void
    {
        self::$jars[$user] = [];
        $token = self::csrf($user);
        $body = http_build_query(['CRAFT_CSRF_TOKEN' => $token, 'loginName' => $user, 'password' => self::$passwords[$user]]);
        [$status, , $answer] = self::http('POST', '/actions/users/login', $user, ['Accept' => 'application/json', 'Content-Type' => 'application/x-www-form-urlencoded'], $body);
        if ($status !== 200) {
            throw new \RuntimeException("signing {$user} in answered {$status}: {$answer}");
        }
    }

    private static function remove(string $path): void
    {
        if (is_link($path) || is_file($path)) {
            @unlink($path);
            return;
        }
        if (!is_dir($path)) {
            return;
        }
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
        $store = str_starts_with(self::$db, 'postgres') ? new PostgresStore(pdo: $pdo, prefix: 'cwcref_') : new MysqlStore(pdo: $pdo, prefix: 'cwcref_');
        $store->init();
        try {
            foreach (['jobs', 'runs', 'state'] as $table) {
                $this->assertSame(self::columns($pdo, 'cwcref_' . $table), self::columns($pdo, self::table($table)), $table);
            }
        } finally {
            foreach (['runs', 'state', 'jobs'] as $table) {
                $pdo->exec("DROP TABLE IF EXISTS cwcref_{$table}");
            }
        }
    }

    /** @return list<string> */
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

    public function testCommandsTheSettingsListAreWatched(): void
    {
        self::clearAlerts();
        $this->assertStringEndsWith("hello\n", self::must(['cwt/task/hello']));
        $run = self::last('craft:cwt:task:hello');
        $this->assertSame('ok', $run['status']);
        $this->assertSame('craft-command', $run['trigger']);
        $this->assertSame('hello from cwt', $run['output']);
        $definition = self::definition('craft:cwt:task:hello');
        $this->assertSame('0 3 * * *', $definition['schedule']);
        // The integration's tags, and this install's under craft-config (from CRAFT_APP_ID).
        $tags = $definition['tags'];
        $this->assertSame(['craft-command', 'craft-config'], array_slice($tags, 0, 2));
        $this->assertCount(3, $tags);
        $this->assertStringStartsWith('craft-config:', $tags[2]);

        [$code] = self::craft(['cwt/task/fail']);
        $this->assertSame(3, $code);
        $this->assertSame('failed', self::last('craft:cwt:task:fail')['status']);
        $this->assertStringStartsWith('Exited with code 3', (string) self::last('craft:cwt:task:fail')['error']);

        [$code] = self::craft(['cwt/task/boom']);
        $this->assertNotSame(0, $code);
        $boom = self::last('cwt-boom');
        $this->assertSame('failed', $boom['status'], 'an exception is recorded from the error handler');
        $this->assertStringStartsWith('RuntimeException: cwt command broke', (string) $boom['error']);
        $this->assertSame('craft cwt/task/hello', $definition['description'], 'a listed command is described by its route');
        $this->assertSame('The command that breaks', self::definition('cwt-boom')['description'], 'unless it is given a description');

        self::must(['cwt/task/unwatched']);
        $this->assertNull(self::definition('craft:cwt:task:unwatched'), 'a command nobody listed is not a job');
        $this->assertSame([['failed', 'craft:cwt:task:fail'], ['failed', 'cwt-boom']], array_map(fn ($a) => [$a['type'], $a['job']], self::alerts()));
    }

    public function testANestedCommandThatThrowsFailsAndItsCallerFinishes(): void
    {
        self::clearAlerts();
        $this->assertStringContainsString('caught: cwt inner broke', self::must(['cwt/task/nested']));
        $nested = self::last('craft:cwt:task:nested');
        $this->assertSame('ok', $nested['status'], 'the caller carried on and finished');
        $inner = self::last('craft:cwt:task:inner');
        $this->assertSame('failed', $inner['status']);
        $this->assertSame('Threw an exception that craft cwt/task/nested, which ran it, caught', $inner['error']);
        $this->assertSame([['failed', 'craft:cwt:task:inner']], array_map(fn ($a) => [$a['type'], $a['job']], self::alerts()));
    }

    public function testACommandWithTheBehaviorIsWatched(): void
    {
        self::must(['cwt/behaved']);
        $run = self::last('craft:cwt:behaved:index');
        $this->assertSame('ok', $run['status']);
        $definition = self::definition('craft:cwt:behaved:index');
        $this->assertSame('0 4 * * *', $definition['schedule']);
        $this->assertSame('20m', $definition['grace']);
        $this->assertSame(['craft-command'], $definition['tags']);
        self::must(['cwt/behaved/other']);
        $this->assertNull(self::definition('craft:cwt:behaved:other'), 'the behavior names its actions');
    }

    public function testQueueJobsOptInAndEachAttemptIsARun(): void
    {
        self::clearAlerts();
        self::must(['cwt/task/push', 'a', '3']);
        for ($i = 0; $i < 3; $i++) {
            self::must(['queue/run']);
            sleep(2);
        }
        $name = 'cwt.jobs.Flaky';
        $runs = self::runs($name);
        $this->assertSame(['failed', 'failed', 'ok'], array_column($runs, 'status'), 'each attempt is a run');
        $this->assertSame(['craft-queue'], array_values(array_unique(array_column($runs, 'trigger'))));
        $this->assertStringStartsWith('RuntimeException: job a failed attempt 1', (string) $runs[0]['error']);
        $this->assertSame('job a attempt 3', $runs[2]['output']);
        // The integration's tags, and this install's under craft-config (from CRAFT_APP_ID).
        $tags = self::definition($name)['tags'];
        $this->assertSame(['craft-queue', 'craft-config'], array_slice($tags, 0, 2));
        $this->assertCount(3, $tags);
        $this->assertStringStartsWith('craft-config:', $tags[2]);
        $this->assertSame([['failed', $name], ['recovered', $name]], array_map(fn ($a) => [$a['type'], $a['job']], self::alerts()));

        $marked = self::runs('cwt-marked');
        $this->assertSame(['ok'], array_column($marked, 'status'), '#[Watch] opts a job in');
        $this->assertSame('marked ran', $marked[0]['output']);
        $this->assertSame(2, self::definition('cwt-marked')['failuresBeforeAlert']);
        $this->assertSame('The marked job', self::definition('cwt-marked')['description'], "the attribute's description wins");
        $this->assertSame('Queue job cwt\jobs\Flaky', self::definition($name)['description']);
    }

    /**
     * A listener of EVENT_BEFORE_EXEC registered after the plugin's cancels
     * the job (the fixtures' Module does, for Cancelled): the queue sends no
     * "after" event, and the attempt is no run at all, not one left running
     * (stuck) or ended as interrupted when the process exits. In a child
     * process per job (queue/run's default) and in the worker's own.
     */
    public function testAQueueJobAnotherListenerCancelsIsNoRun(): void
    {
        foreach ([[], ['--isolate=0']] as $options) {
            self::must(['cwt/task/push-cancelled']);
            self::must(['queue/run', ...$options]);
            $this->assertSame([], self::runs('cwt-cancelled'), 'queue/run ' . implode(' ', $options));
        }
    }

    public function testAlertLinksNeverTakeTheHostOfAVisitorsRequest(): void
    {
        // A site as Craft makes one: @web not set, so Craft takes it from each
        // request, and the queue run by the Control Panel's queue runner.
        $general = self::$root . '/config/general.php';
        $before = (string) file_get_contents($general);
        file_put_contents($general, str_replace(
            ["->runQueueAutomatically(false)", ", '@web' => craft\\helpers\\App::env('PRIMARY_SITE_URL')"],
            ["->runQueueAutomatically(true)", ''],
            $before,
        ));
        self::stopServer();
        self::clearAlerts();
        self::must(['cwt/task/push', 'link', '2']);
        try {
            // A queue job run in a request whose Host a visitor chose.
            [$status] = self::http('GET', '/actions/queue/run', null, ['Host' => 'cronwatch-login.example']);
            $this->assertSame(200, $status);
            $alerts = self::alerts();
            $this->assertSame([['failed', 'cwt.jobs.Flaky']], array_map(fn ($a) => [$a['type'], $a['job']], $alerts));
            $this->assertStringStartsWith('http://127.0.0.1:' . self::$port . '/', $alerts[0]['link'], 'the primary site\'s host');
            $this->assertStringContainsString('cronwatch?job=cwt.jobs.Flaky', $alerts[0]['link']);
        } finally {
            file_put_contents($general, $before);
            self::stopServer();
            self::must(['queue/release', 'all']);
        }
    }

    public function testTheCheckCommand(): void
    {
        // The last line: Craft warns first when run as root (in a container).
        $lines = explode("\n", trim(self::must(['cronwatch/check'])));
        $line = (string) end($lines);
        $this->assertMatchesRegularExpression('/^cronwatch: checked \d+ jobs, sent \d+ alerts?$/', $line);
        // The settings' commands are declared by the check itself.
        $this->assertSame('0 3 * * *', self::definition('craft:cwt:task:hello')['schedule']);
    }

    public function testACommandTakenOutOfTheSettingsLosesItsSchedule(): void
    {
        $config = self::$root . '/config/cronwatch.php';
        $before = (string) file_get_contents($config);
        file_put_contents($config, str_replace("'cwt/task/hello' => ['schedule' => '0 3 * * *', 'timezone' => 'UTC'],", '', $before));
        try {
            self::must(['cronwatch/check']);
            $definition = self::definition('craft:cwt:task:hello');
            $this->assertArrayNotHasKey('schedule', $definition);
            $this->assertStringEndsWith('(no longer scheduled)', $definition['description']);
        } finally {
            file_put_contents($config, $before);
        }
        self::must(['cronwatch/check']);
        $this->assertSame('0 3 * * *', self::definition('craft:cwt:task:hello')['schedule']);
    }

    /**
     * Whether $call prepares the check it runs: with hello taken out of the
     * settings, a prepared check declares it again without its schedule.
     */
    private static function prepares(callable $call): bool
    {
        $config = self::$root . '/config/cronwatch.php';
        $before = (string) file_get_contents($config);
        file_put_contents($config, str_replace("'cwt/task/hello' => ['schedule' => '0 3 * * *', 'timezone' => 'UTC'],", '', $before));
        // A server of its own, so no opcode cache holds the file as it was.
        self::stopServer();
        try {
            $call();
            return !array_key_exists('schedule', self::definition('craft:cwt:task:hello') ?? []);
        } finally {
            file_put_contents($config, $before);
            self::stopServer();
            self::must(['cronwatch/check']);
        }
    }

    public function testTheDashboardIsInTheControlPanel(): void
    {
        self::signIn('admin');
        self::signIn('viewer');

        [$status, , $page] = self::http('GET', '/admin/cronwatch', 'admin');
        $this->assertSame(200, $status);
        $this->assertSame(1, preg_match('#<iframe[^>]*>#', $page, $frame), 'the page frames the dashboard');
        $this->assertMatchesRegularExpression('#src="http://127\.0\.0\.1:\d+/admin/cronwatch/view\?cw=(?:%2F|/)"#', $frame[0]);
        $mask = (string) file_get_contents(dirname(__DIR__, 2) . '/craft/src/icon-mask.svg');
        $this->assertSame(1, preg_match('# d="([^"]+)"#', $mask, $shape));
        $this->assertStringContainsString($shape[1], $page, "the navigation shows the plugin's icon (src/icon-mask.svg)");

        [$status, $headers, $page] = self::http('GET', '/admin/cronwatch/view?cw=%2F', 'admin');
        $this->assertSame(200, $status);
        $this->assertStringStartsWith('text/html', $headers['content-type']);
        $this->assertStringContainsString('craft:cwt:task:hello', $page);
        $this->assertStringNotContainsString('__cronwatch_embedded__', $page);
        $this->assertSame(1, preg_match('#<form class="inline" method="post" action="([^"]*cw=(?:%2F|/)check[^"]*)"><input type="hidden" name="CRAFT_CSRF_TOKEN" value="([^"]+)">#', $page, $m), 'forms carry the CSRF field');
        $check = html_entity_decode($m[1]);
        $token = html_entity_decode($m[2]);
        $check = (string) preg_replace('#^https?://[^/]+#', '', $check);

        $origin = ['Origin' => 'http://127.0.0.1:' . self::$port, 'Content-Type' => 'application/x-www-form-urlencoded'];
        [$status] = self::http('POST', $check, 'admin', $origin, '');
        $this->assertSame(400, $status, 'no CSRF token, no change');
        [$status, $headers] = self::http('POST', $check, 'admin', $origin, 'CRAFT_CSRF_TOKEN=' . rawurlencode($token));
        $this->assertSame(303, $status);
        $this->assertStringContainsString('/admin/cronwatch/view?cw=', $headers['location']);

        [$status, , $page] = self::http('GET', '/admin/cronwatch/view?cw=%2F', 'viewer');
        $this->assertSame(200, $status, 'the plugin permission lets a user look');
        preg_match('#name="CRAFT_CSRF_TOKEN" value="([^"]+)"#', $page, $m);
        [$status] = self::http('POST', $check, 'viewer', $origin, 'CRAFT_CSRF_TOKEN=' . rawurlencode(html_entity_decode($m[1] ?? '')));
        $this->assertSame(403, $status, 'changing needs cronwatch-manage');

        // A bearer means nothing in the embedded dashboard: a viewer's GET of /api/check runs no check.
        [$status, , $body] = self::http('GET', '/admin/cronwatch/view?cw=' . rawurlencode('/api/check'), 'viewer', ['Authorization' => 'Bearer anything']);
        $this->assertSame(405, $status, $body);
        // The check by its API path, or with a slash after it, declares the settings' jobs first too.
        foreach (['/api/check', '/check/'] as $at) {
            $this->assertTrue(self::prepares(function () use ($at, $origin, $token): void {
                [$status, , $body] = self::http('POST', '/admin/cronwatch/view?cw=' . rawurlencode($at), 'admin', $origin, 'CRAFT_CSRF_TOKEN=' . rawurlencode($token));
                $this->assertContains($status, [200, 303], "{$at}: {$body}");
            }), "{$at} declares the settings' jobs first");
        }

        [$status] = self::http('GET', '/admin/cronwatch/view?cw=%2F');
        $this->assertNotSame(200, $status, 'an anonymous visitor is sent to the login page');

        [$status, , $form] = self::http('GET', '/admin/settings/plugins/cronwatch', 'admin');
        $this->assertSame(200, $status);
        $this->assertStringContainsString('Email alerts to', $form);
        $this->assertStringContainsString('Slack incoming webhook URL', $form);
        $this->assertStringContainsString('Run <code>php craft cronwatch/check</code> from', $form, 'the command is set as code');
        $this->assertStringNotContainsString('`', $form);
    }

    public function testTheJsonApiNeedsAToken(): void
    {
        [$status] = self::http('GET', '/cronwatch/api/jobs');
        $this->assertSame(404, $status, 'no token, no API');
        $config = self::$root . '/config/cronwatch.php';
        $before = (string) file_get_contents($config);
        $token = 'cwt-' . bin2hex(random_bytes(12));
        file_put_contents($config, str_replace("return [\n", "return [\n    'apiToken' => '{$token}',\n", $before));
        // A server of its own, so no opcode cache holds the file as it was.
        self::stopServer();
        try {
            [$status, $headers, $body] = self::http('GET', '/cronwatch/api/jobs', null, ['Authorization' => "Bearer {$token}"]);
            $this->assertSame(200, $status, $body);
            $this->assertStringStartsWith('application/json', $headers['content-type']);
            $this->assertStringContainsString('"name":"craft:cwt:task:hello"', $body);
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

            // A check is prepared (the jobs declared, the jobs table read) only for a caller with the token:
            // with the table unreadable, anyone else still gets the 401, not the error preparing it would raise.
            $pdo = self::pdo();
            $jobs = self::table('jobs');
            $pdo->exec("ALTER TABLE {$jobs} RENAME TO {$jobs}_kept");
            $pdo->exec("CREATE VIEW {$jobs} AS SELECT 1 AS unreadable");
            try {
                [$status] = self::http('POST', '/cronwatch/api/check', null, ['Authorization' => 'Bearer wrong']);
                $this->assertSame(401, $status);
                [$status] = self::http('POST', '/cronwatch/api/check');
                $this->assertSame(401, $status);
            } finally {
                $pdo->exec("DROP VIEW {$jobs}");
                $pdo->exec("ALTER TABLE {$jobs}_kept RENAME TO {$jobs}");
            }
            [$status, , $body] = self::http('POST', '/cronwatch/api/check', null, ['Authorization' => "Bearer {$token}"]);
            $this->assertSame(200, $status, $body);
            $this->assertStringContainsString('"ok":true', $body);

            // A platform cron's GET with the token is a check too, prepared first.
            $this->assertTrue(self::prepares(function () use ($token): void {
                [$status, , $body] = self::http('GET', '/cronwatch/api/check', null, ['Authorization' => "Bearer {$token}"]);
                $this->assertSame(200, $status, $body);
            }), 'GET /cronwatch/api/check declares the settings\' jobs first');
        } finally {
            file_put_contents($config, $before);
        }
    }

    public function testUninstallDropsTheTables(): void
    {
        self::stopServer();
        self::must(['plugin/uninstall', 'cronwatch']);
        $pdo = self::pdo();
        foreach (['jobs', 'runs', 'state'] as $table) {
            try {
                $pdo->query('SELECT 1 FROM ' . self::table($table));
                $this->fail(self::table($table) . ' is still there');
            } catch (\PDOException) {
                $this->addToAssertionCount(1);
            }
        }
        $this->assertStringEndsWith("hello\n", self::must(['cwt/task/hello']), 'commands run as before');
    }
}
