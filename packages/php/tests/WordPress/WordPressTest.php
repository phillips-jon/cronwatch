<?php

declare(strict_types=1);

namespace Cronwatch\Tests\WordPress;

use Cronwatch\Store\MysqlStore;
use PHPUnit\Framework\TestCase;

/**
 * The WordPress plugin in a real WordPress. WP-CLI installs WordPress into
 * a temporary directory on the database CRONWATCH_TEST_WORDPRESS names (a
 * mysql:// URL; its tables get a prefix of their own, dropped afterwards),
 * the plugin goes in as the zip wordpress/build.php makes, with
 * fixtures/cwt-fixtures.php as a must-use plugin beside it, and the tests
 * drive it as a site would be: `wp cron event run`, wp-cron.php requested
 * from PHP's built-in server, `wp cronwatch check`, the settings handlers
 * and uninstalling. CRONWATCH_TEST_WPCLI is the path to wp-cli.phar, and
 * CRONWATCH_TEST_WP_VERSION the WordPress version (default below).
 *
 * The tests share one site and run in order; the last uninstalls the plugin.
 */
final class WordPressTest extends TestCase
{
    public const WORDPRESS = '7.1.2';

    private static ?string $skip = null;
    private static string $dir = '';
    private static string $phar = '';
    private static string $url = '';
    private static string $prefix = '';
    private static string $version = '';
    private static int $port = 0;
    /** @var resource|null */
    private static $server = null;

    public static function setUpBeforeClass(): void
    {
        $url = (string) getenv('CRONWATCH_TEST_WORDPRESS');
        $phar = (string) getenv('CRONWATCH_TEST_WPCLI');
        if ($url === '' || $phar === '') {
            self::$skip = 'set CRONWATCH_TEST_WORDPRESS (a mysql:// URL) and CRONWATCH_TEST_WPCLI (the path to wp-cli.phar) to run';
            return;
        }
        if (!extension_loaded('mysqli') || !extension_loaded('pdo_mysql') || !class_exists(\ZipArchive::class) || !function_exists('proc_open')) {
            self::$skip = 'needs mysqli, pdo_mysql, zip and proc_open';
            return;
        }
        self::$skip = null;
        self::$url = $url;
        self::$phar = $phar;
        self::$prefix = 'cwwp' . getmypid() . '_';
        self::$dir = sys_get_temp_dir() . '/cronwatch-wp-' . getmypid() . '-' . bin2hex(random_bytes(4));
        self::$port = self::freePort();
        $parts = parse_url($url);
        $host = ($parts['host'] ?? '127.0.0.1') . (isset($parts['port']) ? ':' . $parts['port'] : '');
        $version = self::$version = (string) (getenv('CRONWATCH_TEST_WP_VERSION') ?: self::WORDPRESS);

        mkdir(self::$dir, 0777, true);
        self::must(['core', 'download', "--version={$version}", '--skip-content', '--force']);
        self::must(['config', 'create', '--dbname=' . ltrim((string) ($parts['path'] ?? ''), '/'), '--dbuser=' . rawurldecode((string) ($parts['user'] ?? '')),
            '--dbpass=' . rawurldecode((string) ($parts['pass'] ?? '')), "--dbhost={$host}", '--dbprefix=' . self::$prefix, '--skip-check', '--extra-php'],
            // Nothing spawns wp-cron.php on its own: each test runs events when it means to.
            "define( 'DISABLE_WP_CRON', true );\ndefine( 'WP_DEBUG', false );\n");
        self::must(['core', 'install', '--url=http://127.0.0.1:' . self::$port, '--title=CronWatch test', '--admin_user=admin',
            '--admin_password=' . bin2hex(random_bytes(8)), '--admin_email=admin@example.com', '--skip-email']);
        self::must(['user', 'create', 'reader', 'reader@example.com', '--role=subscriber']);

        // The plugin as it ships: the zip, unpacked into the plugins directory.
        $zip = self::buildZip(self::$dir . '/build');
        @mkdir(self::$dir . '/wp-content/plugins', 0777, true);
        @mkdir(self::$dir . '/wp-content/mu-plugins', 0777, true);
        $archive = new \ZipArchive();
        $archive->open($zip);
        $archive->extractTo(self::$dir . '/wp-content/plugins');
        $archive->close();
        copy(__DIR__ . '/fixtures/cwt-fixtures.php', self::$dir . '/wp-content/mu-plugins/cwt-fixtures.php');
        self::must(['plugin', 'activate', 'cronwatch']);
    }

    public static function tearDownAfterClass(): void
    {
        if (self::$skip !== null || self::$dir === '') {
            return;
        }
        self::stopServer();
        try {
            $pdo = self::pdo();
            $tables = [
                ...$pdo->query('SHOW TABLES LIKE ' . $pdo->quote(self::$prefix . '%'))->fetchAll(\PDO::FETCH_COLUMN),
                ...$pdo->query('SHOW TABLES LIKE ' . $pdo->quote(self::networkPrefix() . '%'))->fetchAll(\PDO::FETCH_COLUMN),
            ];
            foreach ($tables as $table) {
                $pdo->exec("DROP TABLE IF EXISTS `{$table}`");
            }
        } finally {
            self::remove(self::$dir);
        }
    }

    protected function setUp(): void
    {
        if (self::$skip !== null) {
            $this->markTestSkipped(self::$skip);
        }
    }

    // ------------------------------------------------------------ helpers

    /** Builds the plugin zip into `dir` with wordpress/build.php and returns its path. */
    public static function buildZip(string $dir): string
    {
        [$code, $out, $err] = self::exec([PHP_BINARY, dirname(__DIR__, 2) . '/wordpress/build.php', $dir]);
        if ($code !== 0 || preg_match('/^wrote (\S+\.zip) /m', $out, $m) !== 1) {
            throw new \RuntimeException("build.php failed: {$out}{$err}");
        }
        return $m[1];
    }

    /**
     * Runs a command, stdin given, and returns [exit code, stdout, stderr].
     *
     * @param list<string> $command
     * @return array{int, string, string}
     */
    private static function exec(array $command, string $stdin = ''): array
    {
        $process = proc_open($command, [0 => ['pipe', 'r'], 1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes);
        if (!is_resource($process)) {
            throw new \RuntimeException('could not start ' . $command[0]);
        }
        fwrite($pipes[0], $stdin);
        fclose($pipes[0]);
        $out = stream_get_contents($pipes[1]);
        $err = stream_get_contents($pipes[2]);
        fclose($pipes[1]);
        fclose($pipes[2]);
        return [proc_close($process), (string) $out, (string) $err];
    }

    /**
     * A WP-CLI command on the test site.
     *
     * @param list<string> $args
     * @return array{int, string, string}
     */
    private static function wp(array $args, string $stdin = '', ?string $dir = null): array
    {
        // WP-CLI 2.12 is older than PHP 8.5; its deprecation notices are not the plugin's.
        // In a container the tests may run as root, which WP-CLI refuses unless told.
        $root = function_exists('posix_geteuid') && posix_geteuid() === 0 ? ['--allow-root'] : [];
        return self::exec([PHP_BINARY, '-d', 'error_reporting=' . (E_ALL & ~E_DEPRECATED), '-d', 'display_errors=stderr', self::$phar, '--path=' . ($dir ?? self::$dir), ...$root, ...$args], $stdin);
    }

    /** @param list<string> $args */
    private static function must(array $args, string $stdin = '', ?string $dir = null): string
    {
        [$code, $out, $err] = self::wp($args, $stdin, $dir);
        if ($code !== 0) {
            throw new \RuntimeException('wp ' . implode(' ', $args) . " exited {$code}:\n{$out}\n{$err}");
        }
        return $out;
    }

    /** Runs PHP inside WordPress (wp eval-file) and returns what it echoes as JSON on its last line. */
    private static function inWp(string $code): mixed
    {
        $file = self::$dir . '/cwt-eval-' . bin2hex(random_bytes(4)) . '.php';
        file_put_contents($file, "<?php\n" . $code);
        try {
            [$status, $out, $err] = self::wp(['eval-file', $file]);
        } finally {
            unlink($file);
        }
        $lines = preg_split('/\R/', trim($out)) ?: [];
        $last = (string) end($lines);
        json_decode($last);
        if ($status !== 0 || json_last_error() !== JSON_ERROR_NONE) {
            throw new \RuntimeException("eval-file exited {$status}:\n{$out}\n{$err}");
        }
        return json_decode($last, true);
    }

    private static function pdo(): \PDO
    {
        [$dsn, $user, $password] = MysqlStore::connection(self::$url);
        return new \PDO($dsn, $user, $password, [\PDO::ATTR_ERRMODE => \PDO::ERRMODE_EXCEPTION]);
    }

    /** @return list<array<string, mixed>> the runs of a job, oldest first, straight from the table */
    private static function runs(string $job): array
    {
        $statement = self::pdo()->prepare('SELECT * FROM ' . self::$prefix . 'cronwatch_runs WHERE job = ? ORDER BY seq');
        $statement->execute([$job]);
        return $statement->fetchAll(\PDO::FETCH_ASSOC);
    }

    /** @return array<string, mixed> a job's newest run */
    private static function lastRun(string $job): array
    {
        $runs = self::runs($job);
        return $runs === [] ? [] : $runs[count($runs) - 1];
    }

    /** @return array<string, mixed>|null a stored job's definition */
    private static function definition(string $job): ?array
    {
        $statement = self::pdo()->prepare('SELECT definition FROM ' . self::$prefix . 'cronwatch_jobs WHERE name = ?');
        $statement->execute([$job]);
        $json = $statement->fetchColumn();
        return $json === false ? null : json_decode((string) $json, true);
    }

    /** Clears a hook's events and schedules new ones, each [recurrence or null, args], due a minute ago. */
    private static function schedule(string $hook, array $events): void
    {
        $code = 'wp_clear_scheduled_hook(' . var_export($hook, true) . ');';
        foreach ($events as $i => [$recurrence, $args]) {
            $at = 'time() - 60 + ' . (int) $i;
            $code .= $recurrence === null
                ? "wp_schedule_single_event({$at}, " . var_export($hook, true) . ', ' . var_export($args, true) . ', true);'
                : "wp_schedule_event({$at}, " . var_export($recurrence, true) . ', ' . var_export($hook, true) . ', ' . var_export($args, true) . ', true);';
        }
        self::inWp($code . 'echo json_encode(true);');
    }

    private static function freePort(): int
    {
        $socket = stream_socket_server('tcp://127.0.0.1:0');
        $name = stream_socket_get_name($socket, false);
        fclose($socket);
        return (int) substr((string) $name, strrpos((string) $name, ':') + 1);
    }

    /**
     * PHP's built-in server on the site, set as php.ini-production sets a
     * host: errors logged rather than shown, and output buffered, so nothing
     * is sent before WordPress's fatal error handler shows its page. It
     * answers one request at a time, so the fixtures keep WordPress from
     * requesting anything over HTTP (Site Health's weekly event requests the
     * site itself, which would wait on the request making it).
     */
    private static function startServer(): void
    {
        if (self::$server !== null) {
            return;
        }
        self::$server = proc_open([PHP_BINARY, '-d', 'display_errors=0', '-d', 'output_buffering=4096', '-d', 'log_errors=1', '-d', 'error_log=' . self::$dir . '/php-errors.log',
            '-S', '127.0.0.1:' . self::$port, '-t', self::$dir], [0 => ['file', '/dev/null', 'r'], 1 => ['file', self::$dir . '/server.log', 'a'], 2 => ['file', self::$dir . '/server.log', 'a']], $pipes);
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

    /** GET /wp-cron.php, with WP-Cron's lock cleared first so it runs whatever is due. */
    private static function requestWpCron(): string
    {
        self::pdo()->exec('DELETE FROM ' . self::$prefix . "options WHERE option_name IN ('_transient_doing_cron', '_transient_timeout_doing_cron')");
        self::startServer();
        $body = @file_get_contents('http://127.0.0.1:' . self::$port . '/wp-cron.php', false, stream_context_create(['http' => ['ignore_errors' => true, 'timeout' => 30]]));
        return (string) $body;
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

    // ------------------------------------------------------------ the tests

    public function testActivationCreatesTheLibrarysTablesAndSchedulesTheCheck(): void
    {
        $pdo = self::pdo();
        $p = self::$prefix;
        $columns = $pdo->query("SELECT table_name, column_name, column_type, collation_name FROM information_schema.columns
            WHERE table_schema = DATABASE() AND table_name LIKE '{$p}cronwatch%' ORDER BY table_name, ordinal_position")->fetchAll(\PDO::FETCH_NUM);
        $this->assertSame(['name', 'definition', 'created_at', 'updated_at'], array_values(array_map(fn ($c) => $c[1], array_filter($columns, fn ($c) => $c[0] === "{$p}cronwatch_jobs"))));
        $this->assertSame(['seq', 'id', 'job', 'status', 'started_at', 'finished_at', 'duration_ms', 'error', 'output', 'metrics', 'trigger'],
            array_values(array_map(fn ($c) => $c[1], array_filter($columns, fn ($c) => $c[0] === "{$p}cronwatch_runs"))));
        $this->assertSame(['job', 'state'], array_values(array_map(fn ($c) => $c[1], array_filter($columns, fn ($c) => $c[0] === "{$p}cronwatch_state"))));
        foreach ($columns as $column) {
            if ($column[3] !== null) {
                $this->assertSame('utf8mb4_bin', $column[3], "{$column[0]}.{$column[1]} compares as bytes");
            }
        }
        $state = $this->inWpState();
        $this->assertSame('1', $state['db_version']);
        $this->assertSame('cronwatch_five_minutes', $state['check_schedule']);
        $this->assertSame(300, $state['check_interval']);
    }

    private function inWpState(): array
    {
        return self::inWp(<<<'PHP'
            $event = wp_get_scheduled_event('cronwatch_check');
            echo json_encode([
                'db_version' => get_option('cronwatch_db_version'),
                'check_schedule' => $event ? $event->schedule : null,
                'check_interval' => $event ? $event->interval : null,
            ]);
            PHP);
    }

    public function testARecurringEventsRunIsRecordedOnItsJobWithItsOutput(): void
    {
        self::schedule('cwt_ok', [['hourly', []], ['daily', ['x']]]);
        [$code, $out] = self::wp(['cron', 'event', 'run', 'cwt_ok']);
        $this->assertSame(0, $code);
        $this->assertSame(2, substr_count($out, "did ok\n"), 'what the callback echoes is passed on');

        $hourly = self::definition('wp:cwt_ok');
        $this->assertSame('every 3600s', $hourly['schedule']);
        $this->assertSame(['wp-cron'], $hourly['tags']);
        $this->assertSame('WP-Cron hook cwt_ok, hourly (every 3600s)', $hourly['description']);
        $key = substr(md5(serialize(['x'])), 0, 8);
        $daily = self::definition("wp:cwt_ok:{$key}");
        $this->assertSame('every 86400s', $daily['schedule']);
        $this->assertSame('WP-Cron hook cwt_ok with args ["x"], daily (every 86400s)', $daily['description']);

        $run = self::runs('wp:cwt_ok')[0];
        $this->assertSame('ok', $run['status']);
        $this->assertSame('wp-cron', $run['trigger']);
        $this->assertSame("logged []\ndid ok", $run['output'], 'cronwatch_log() lines, then what was echoed');
        $this->assertSame("logged [\"x\"]\ndid ok", self::runs("wp:cwt_ok:{$key}")[0]['output']);
    }

    public function testSingleEventsAreOneJobPerHookWithoutASchedule(): void
    {
        self::schedule('cwt_single', [[null, [1]], [null, [2]]]);
        self::must(['cron', 'event', 'run', 'cwt_single']);
        $definition = self::definition('wp:cwt_single');
        $this->assertArrayNotHasKey('schedule', $definition);
        $this->assertSame('WP-Cron hook cwt_single, single events', $definition['description']);
        $this->assertSame(['single 1', 'single 2'], array_column(self::runs('wp:cwt_single'), 'output'));
    }

    public function testAHookFiredByHandIsNotARunAndAnIgnoredEventIsNotWatched(): void
    {
        // cwt_single runs first, so its hook is watched when cwt_inner fires it by hand.
        self::schedule('cwt_single', [[null, ['queued']]]);
        self::schedule('cwt_inner', [[null, []]]);
        self::schedule('cwt_ignored', [[null, []]]);
        $before = count(self::runs('wp:cwt_single'));
        self::must(['cron', 'event', 'run', 'cwt_single', 'cwt_inner', 'cwt_ignored']);
        $this->assertSame(['single queued'], array_column(array_slice(self::runs('wp:cwt_single'), $before), 'output'), 'do_action() inside a run records nothing of its own');
        $this->assertSame('single by-hand', self::runs('wp:cwt_inner')[0]['output'], 'its output is the enclosing run\'s');
        $this->assertNull(self::definition('wp:cwt_ignored'), 'cronwatch_watch_event left it out');
        self::inWp('do_action("cwt_ok"); echo json_encode(true);');
        $this->assertCount(1, self::runs('wp:cwt_ok'), 'a hook fired outside WP-Cron is not a run');
    }

    public function testAThrowAFatalErrorAndAnExitUnderWpCliAreFailedRuns(): void
    {
        foreach (['cwt_throw', 'cwt_fatal', 'cwt_exit'] as $hook) {
            self::schedule($hook, [[null, []]]);
            self::wp(['cron', 'event', 'run', $hook]);
        }
        $throw = self::runs('wp:cwt_throw')[0];
        $this->assertSame('failed', $throw['status']);
        $this->assertStringStartsWith('Interrupted: Fatal error: Uncaught RuntimeException: boom in ', $throw['error']);
        $this->assertSame('before throw', $throw['output']);
        $fatal = self::runs('wp:cwt_fatal')[0];
        $this->assertStringStartsWith('Interrupted: Fatal error: Uncaught Error: Call to undefined function cwt_no_such_function()', $fatal['error']);
        $this->assertMatchesRegularExpression('/\n    at \S*cwt-fixtures\.php:\d+$/', $fatal['error'], 'the file and line, as a frame');
        $exit = self::runs('wp:cwt_exit')[0];
        $this->assertSame('Interrupted: the process exited during the run', $exit['error']);
        $this->assertNotNull($exit['finished_at']);
    }

    public function testRunsThroughWpCronPhpAreRecordedAndAFatalErrorBeforeWordPressShowsItsErrorPage(): void
    {
        self::schedule('cwt_ok', [['hourly', []]]);
        self::schedule('cwt_throw', [[null, []]]);
        $before = count(self::runs('wp:cwt_throw'));
        $page = self::requestWpCron();
        $this->assertStringContainsString('critical error', $page, 'WordPress\'s fatal error handler showed its page (and ended the process with wp_die)');
        $throws = self::runs('wp:cwt_throw');
        $this->assertCount($before + 1, $throws);
        $this->assertStringStartsWith('Interrupted: Fatal error: Uncaught RuntimeException: boom', end($throws)['error']);
        $this->assertSame('ok', self::lastRun('wp:cwt_ok')['status']);

        self::schedule('cwt_single', [[null, ['web']]]);
        self::requestWpCron();
        $this->assertSame('single web', self::lastRun('wp:cwt_single')['output']);
    }

    public function testTheCheckFindsAMissedEventAndSendsThroughTheChannelsAndPrintsOneLine(): void
    {
        self::schedule('cwt_missed', [['hourly', []]]);
        self::inWp('delete_option("cwt_now"); delete_option("cwt_alerts"); echo json_encode(true);');
        $line = trim(self::must(['cronwatch', 'check']));
        $this->assertMatchesRegularExpression('/^cronwatch: checked \d+ jobs, sent \d+ alerts?$/', $line);
        $this->assertNotNull(self::definition('wp:wp_version_check'), 'WordPress\'s own events are watched too');
        $this->assertNull(self::definition('wp:cronwatch_check'), 'the plugin\'s own check is not');

        self::inWp('update_option("cwt_now", (int) floor(microtime(true) * 1000) + 3 * 3600 * 1000); echo json_encode(true);');
        self::must(['cronwatch', 'check']);
        $alerts = self::inWp('echo json_encode(get_option("cwt_alerts", []));');
        $missed = array_values(array_filter($alerts, fn (array $a) => $a['job'] === 'wp:cwt_missed'));
        $this->assertSame([['type' => 'missed', 'job' => 'wp:cwt_missed', 'title' => 'wp:cwt_missed missed its scheduled run']], $missed);
        self::must(['cronwatch', 'check']);
        $again = self::inWp('echo json_encode(get_option("cwt_alerts", []));');
        $this->assertCount(count($alerts), $again, 'an open condition does not alert again');
        self::inWp('delete_option("cwt_now"); echo json_encode(true);');
    }

    public function testQuietChecksAndTheSummaryLine(): void
    {
        [$code, $out] = self::wp(['cronwatch', 'check', '--quiet']);
        $this->assertSame(0, $code);
        $this->assertSame('', trim($out));
        $this->assertMatchesRegularExpression('/^cronwatch: checked \d+ jobs, sent \d+ alerts?$/', trim(self::must(['cronwatch', 'check'])));
    }

    public function testAnEventThatIsNoLongerScheduledLosesItsSchedule(): void
    {
        self::inWp('delete_option("cwt_now"); echo json_encode(true);');
        self::schedule('cwt_gone', [['twicedaily', []]]);
        self::must(['cronwatch', 'check']);
        $this->assertSame('every 43200s', self::definition('wp:cwt_gone')['schedule']);
        self::inWp('wp_clear_scheduled_hook("cwt_gone"); echo json_encode(true);');
        self::must(['cronwatch', 'check']);
        $definition = self::definition('wp:cwt_gone');
        $this->assertArrayNotHasKey('schedule', $definition);
        $this->assertSame('WP-Cron hook cwt_gone, twicedaily (every 43200s) (no longer scheduled)', $definition['description']);
        self::must(['cronwatch', 'check']);
        $this->assertSame('WP-Cron hook cwt_gone, twicedaily (every 43200s) (no longer scheduled)', self::definition('wp:cwt_gone')['description'], 'retired once');
    }

    public function testTheStoreWritesTheBytesMysqlStoreWritesAndKeepsTheStoreContract(): void
    {
        $result = self::inWp(<<<'PHP'
            use Cronwatch\{JobDefinition, JobState, Run};
            global $wpdb;
            $store = new Cronwatch\WordPress\WpdbStore($wpdb);
            $out = [];
            $store->upsertJob(new JobDefinition(['name' => 'contract', 'schedule' => '0 2 * * *', 'grace' => 900000]), 1000);
            $out['job'] = $store->getJob('contract')?->definition->get('grace');
            $run = new Run('c1', 'contract', 'running', 1000, null, null, null, "caf\u{e9} 100% 'quoted' \\ back \u{1F600}", ['n' => 1.5]);
            $store->insertRun($run);
            try { $store->insertRun($run); $out['duplicate'] = 'inserted'; } catch (Throwable $e) { $out['duplicate'] = 'refused'; }
            $done = clone $run; $done->status = 'ok'; $done->finishedAt = 2000; $done->durationMs = 1000;
            $out['updateIf'] = [$store->updateRunIf($done, ['running']), $store->updateRunIf($done, ['running']), $store->updateRunIf($done, ['ok'])];
            $out['run'] = $store->getRun('c1')?->toJson();
            $state = JobState::fromJson(['job' => 'contract', 'version' => 1]);
            $out['cas'] = [$store->compareAndSetState($state, 0), $store->compareAndSetState($state, 0),
                $store->compareAndSetState(JobState::fromJson(['job' => 'contract', 'version' => 2]), 1), $store->compareAndSetState($state, 1)];
            $out['version'] = $store->getState('contract')?->version;
            $store->insertRun(new Run('c0', 'contract', 'ok', 500, 600, 100));
            $out['pruned'] = $store->prune(1_000_000);
            $out['left'] = array_map(fn (Run $r) => $r->id, $store->listRuns('contract', 10));
            $store->deleteJob('contract');
            $out['deleted'] = [$store->getJob('contract'), $store->getRun('c1'), $store->getState('contract')];
            echo json_encode($out);
            PHP);
        $this->assertSame(900000, $result['job']);
        $this->assertSame('refused', $result['duplicate']);
        $this->assertSame([true, false, true], $result['updateIf'], 'written only over the statuses given, and a write that changes nothing still counts');
        $this->assertSame("caf\u{e9} 100% 'quoted' \\ back \u{1F600}", $result['run']['output'], 'quotes, % and four byte characters survive $wpdb');
        $this->assertSame([true, false, true, false], $result['cas']);
        $this->assertSame(2, $result['version']);
        $this->assertSame(1, $result['pruned']);
        $this->assertSame(['c1'], $result['left'], 'the newest run is kept');
        $this->assertSame([null, null, null], $result['deleted']);

        // One row written by each store, compared column by column.
        $store = new MysqlStore(self::$url, prefix: self::$prefix . 'cronwatch_');
        $row = new \Cronwatch\Run('bytes-mysql', 'bytes', 'failed', 1767605400000, 1767605401500, 1500, "Error: x\n    at a (b:1)", "\u{1F680} r\u{e9}sum\u{e9}", ['cost' => 0.1, 'rows' => 1e21]);
        $store->insertRun($row);
        $store->upsertJob(new \Cronwatch\JobDefinition(['name' => 'bytes', 'budget' => ['cost' => 2], 'grace' => '15m']), 5);
        self::inWp(<<<'PHP'
            global $wpdb;
            $store = new Cronwatch\WordPress\WpdbStore($wpdb);
            $store->insertRun(new Cronwatch\Run('bytes-wpdb', 'bytes', 'failed', 1767605400000, 1767605401500, 1500, "Error: x\n    at a (b:1)", "\u{1F680} r\u{e9}sum\u{e9}", ['cost' => 0.1, 'rows' => 1e21]));
            $store->upsertJob(new Cronwatch\JobDefinition(['name' => 'bytes2', 'budget' => ['cost' => 2], 'grace' => '15m']), 5);
            echo json_encode(true);
            PHP);
        $pdo = self::pdo();
        $rows = $pdo->query('SELECT * FROM ' . self::$prefix . "cronwatch_runs WHERE job = 'bytes' ORDER BY id")->fetchAll(\PDO::FETCH_ASSOC);
        unset($rows[0]['seq'], $rows[1]['seq'], $rows[0]['id'], $rows[1]['id']);
        $this->assertSame($rows[0], $rows[1]);
        $this->assertSame('{"cost":0.1,"rows":1e+21}', $rows[0]['metrics']);
        $jobs = $pdo->query('SELECT definition FROM ' . self::$prefix . "cronwatch_jobs WHERE name IN ('bytes', 'bytes2') ORDER BY name")->fetchAll(\PDO::FETCH_COLUMN);
        $this->assertSame(str_replace('"bytes"', '"bytes2"', $jobs[0]), $jobs[1]);
        $store->close();
    }

    public function testTheSettingsHandlersCheckTheCapabilityAndTheNonceAndSanitize(): void
    {
        $result = self::inWp(<<<'PHP'
            use Cronwatch\WordPress\Admin;
            add_filter('wp_die_handler', fn () => function ($message, $title = '', $args = []) {
                throw new RuntimeException('died ' . (is_array($args) ? ($args['response'] ?? '') : ''));
            }, PHP_INT_MAX);
            add_filter('wp_redirect', function ($location) { throw new RuntimeException('redirect ' . $location); });
            $attempt = function (callable $fn): string {
                try { $fn(); return 'ran'; } catch (RuntimeException $e) { return $e->getMessage(); }
            };
            $out = [];
            $reader = get_user_by('login', 'reader');
            wp_set_current_user($reader->ID);
            $_POST = $_REQUEST = ['_wpnonce' => wp_create_nonce('cronwatch_save'), 'cronwatch' => ['email_to' => 'x@example.com']];
            $out['subscriber'] = $attempt([Admin::class, 'save']);
            $out['subscriberTest'] = $attempt([Admin::class, 'test']);
            wp_set_current_user(get_user_by('login', 'admin')->ID);
            $_POST = $_REQUEST = ['cronwatch' => ['email_to' => 'x@example.com']];
            $out['noNonce'] = $attempt([Admin::class, 'save']);
            $_POST = $_REQUEST = ['_wpnonce' => wp_create_nonce('cronwatch_test'), 'cronwatch' => ['email_to' => 'x@example.com']];
            $out['wrongNonce'] = $attempt([Admin::class, 'save']);
            $out['saved'] = get_option('cronwatch_settings');
            $_POST = $_REQUEST = ['_wpnonce' => wp_create_nonce('cronwatch_save'), 'cronwatch' => wp_slash([
                'email_to' => 'ops@example.com, not an address, dev@example.com',
                'slack_webhook_url' => 'javascript:alert(1)',
                'webhook_url' => ' https://hooks.example.com/in?team=a&b=1 ',
                'webhook_secret' => 'shh-its-a-secret',
                'grace' => '1h30m',
            ])];
            $out['save'] = $attempt([Admin::class, 'save']);
            $out['after'] = get_option('cronwatch_settings');
            $_POST = $_REQUEST = ['_wpnonce' => wp_create_nonce('cronwatch_save'), 'cronwatch' => ['email_to' => '', 'webhook_url' => 'https://hooks.example.com/in', 'webhook_secret' => '', 'grace' => 'soon']];
            $out['keep'] = $attempt([Admin::class, 'save']);
            $out['kept'] = get_option('cronwatch_settings');
            ob_start();
            Admin::render();
            $page = ob_get_clean();
            $out['pageHasSecret'] = str_contains($page, 'shh-its-a-secret');
            $out['pageHasNonce'] = str_contains($page, 'name="_wpnonce"');
            $out['pageLinksTheDashboard'] = str_contains($page, 'href="' . esc_url(admin_url('admin.php?page=cronwatch')) . '">Open the dashboard</a>');
            update_option('cronwatch_settings', Cronwatch\WordPress\Plugin::DEFAULTS);
            echo json_encode($out);
            PHP);
        $this->assertSame('died 403', $result['subscriber']);
        $this->assertSame('died 403', $result['subscriberTest']);
        $this->assertStringStartsWith('died', $result['noNonce']);
        $this->assertStringStartsWith('died', $result['wrongNonce']);
        $this->assertSame('', $result['saved']['email_to'], 'nothing was saved without the capability and the nonce');
        $this->assertStringContainsString('cronwatch_notice=saved', $result['save']);
        $this->assertSame([
            'email_to' => 'ops@example.com, dev@example.com',
            'slack_webhook_url' => '',
            'webhook_url' => 'https://hooks.example.com/in?team=a&b=1',
            'webhook_secret' => 'shh-its-a-secret',
            'grace' => '1h30m',
            'api_enabled' => '',
            'api_token' => '',
        ], $result['after'], 'the JSON API stays off unless asked for');
        $this->assertStringContainsString('cronwatch_notice=grace', $result['keep']);
        $this->assertSame('shh-its-a-secret', $result['kept']['webhook_secret'], 'a blank secret keeps the saved one');
        $this->assertSame('1h30m', $result['kept']['grace'], 'a grace that does not parse is not saved');
        $this->assertFalse($result['pageHasSecret'], 'the secret is never shown');
        $this->assertTrue($result['pageHasNonce']);
        $this->assertTrue($result['pageLinksTheDashboard']);
    }

    public function testTheTestAlertGoesToEveryChannelAndWpMailReportsAFailure(): void
    {
        $result = self::inWp(<<<'PHP'
            delete_option('cwt_alerts');
            $results = Cronwatch\WordPress\Admin::sendTest();
            $mail = new Cronwatch\WordPress\WpMail('ops@example.com');
            add_filter('pre_wp_mail', fn () => false);
            try {
                $mail->send(new Cronwatch\Alert('failed', null, [], 'j', new Cronwatch\JobDefinition(['name' => 'j']), 'j failed', 'm', 0), new Cronwatch\Alerts\ChannelContext(fn () => null));
                $failure = null;
            } catch (RuntimeException $e) {
                $failure = $e->getMessage();
            }
            $sent = null;
            remove_all_filters('pre_wp_mail');
            add_filter('pre_wp_mail', function ($return, $atts) use (&$sent) { $sent = $atts; return true; }, 10, 2);
            $mail->send(new Cronwatch\Alert('failed', null, [], 'j', new Cronwatch\JobDefinition(['name' => 'j']), "j\nfailed", 'the message', 0), new Cronwatch\Alerts\ChannelContext(fn () => null));
            echo json_encode(['results' => $results, 'seen' => get_option('cwt_alerts'), 'failure' => $failure, 'sent' => $sent]);
            PHP);
        $this->assertSame([['channel' => 'custom', 'ok' => true, 'message' => '']], $result['results']);
        $this->assertSame('CronWatch test alert', $result['seen'][0]['title']);
        $this->assertSame('wp_mail could not send the alert', $result['failure']);
        $this->assertSame(['ops@example.com'], $result['sent']['to']);
        $this->assertSame('j failed', $result['sent']['subject'], 'one line');
        $this->assertStringStartsWith("j\nfailed\n\nthe message", $result['sent']['message']);
    }

    /** The table prefix of the network the multisite test installs. */
    private static function networkPrefix(): string
    {
        return 'cwms' . getmypid() . '_';
    }

    /**
     * A request to the site under PHP's built-in server.
     *
     * @param array<string, string> $headers
     * @return array{int, array<string, string>, string}
     */
    private static function http(string $method, string $path, array $headers = [], string $body = ''): array
    {
        self::startServer();
        $lines = [];
        foreach ($headers as $name => $value) {
            $lines[] = "{$name}: {$value}";
        }
        $context = stream_context_create(['http' => ['method' => $method, 'header' => $lines, 'content' => $body, 'ignore_errors' => true, 'follow_location' => 0, 'timeout' => 30]]);
        $text = (string) @file_get_contents('http://127.0.0.1:' . self::$port . $path, false, $context);
        // http_get_last_response_headers() is 8.4's; before it the headers land in a local variable.
        $received = function_exists('http_get_last_response_headers') ? http_get_last_response_headers() : ($http_response_header ?? []);
        $status = 0;
        $out = [];
        foreach ($received ?? [] as $line) {
            if (preg_match('#^HTTP/\S+ (\d{3})#', $line, $m) === 1) {
                $status = (int) $m[1];
                continue;
            }
            [$name, $value] = array_map('trim', explode(':', $line, 2) + [1 => '']);
            $out[strtolower($name)] = $value;
        }
        if ($status === 0) {
            throw new \RuntimeException("{$method} {$path} got no answer: " . (error_get_last()['message'] ?? '') . "\nserver: "
                . substr((string) @file_get_contents(self::$dir . '/server.log'), -1500) . "\nerrors: " . substr((string) @file_get_contents(self::$dir . '/php-errors.log'), -1500));
        }
        return [$status, $out, $text];
    }

    /** The Cookie header of a signed-in session for a user, as the login form would set it. */
    private static function signedIn(string $login): string
    {
        $cookies = self::inWp(<<<PHP
            \$user = get_user_by('login', '{$login}');
            \$expiration = time() + 3600;
            \$token = WP_Session_Tokens::get_instance(\$user->ID)->create(\$expiration);
            echo json_encode([
                AUTH_COOKIE => wp_generate_auth_cookie(\$user->ID, \$expiration, 'auth', \$token),
                LOGGED_IN_COOKIE => wp_generate_auth_cookie(\$user->ID, \$expiration, 'logged_in', \$token),
            ]);
            PHP);
        return implode('; ', array_map(fn ($name, $value) => $name . '=' . rawurlencode($value), array_keys($cookies), $cookies));
    }

    public function testTheDashboardIsInWpAdminForAdministratorsOnly(): void
    {
        $admin = ['Cookie' => self::signedIn('admin')];
        [$status, , $screen] = self::http('GET', '/wp-admin/admin.php?page=cronwatch', $admin);
        $this->assertSame(200, $status);
        $this->assertMatchesRegularExpression('#<iframe class="cronwatch-dashboard-frame" title="CronWatch dashboard" src="[^"]*admin\.php\?page=cronwatch&\#038;cw=%2F"#', $screen);
        $this->assertStringContainsString('page=cronwatch-settings', $screen, 'the settings are a link away');

        [$status, $headers, $page] = self::http('GET', '/wp-admin/admin.php?page=cronwatch&cw=%2F', $admin);
        $this->assertSame(200, $status);
        $this->assertSame('text/html; charset=utf-8', $headers['content-type']);
        $this->assertSame('SAMEORIGIN', $headers['x-frame-options'], 'wp-admin may frame it');
        $this->assertStringContainsString("frame-ancestors 'self'", $headers['content-security-policy']);
        $this->assertStringContainsString("default-src 'none'", $headers['content-security-policy']);
        $this->assertStringStartsWith("<!doctype html>\n", $page, 'the dashboard\'s own page, without wp-admin around it');
        $this->assertStringContainsString('wp:cwt_ok', $page);
        $this->assertStringNotContainsString('/__cronwatch_wp_admin__', $page, 'every link points into wp-admin');
        $this->assertStringNotContainsString('manifest.webmanifest', $page);
        $this->assertStringNotContainsString('<script', $page);
        $this->assertMatchesRegularExpression('#href="[^"]*/wp-admin/admin\.php\?page=cronwatch&\#038;cw=%2Fjobs%2Fwp%253Acwt_ok"#', $page);

        // A job's page, through the link the board gives it.
        [$status, , $job] = self::http('GET', '/wp-admin/admin.php?page=cronwatch&cw=%2Fjobs%2Fwp%253Acwt_ok', $admin);
        $this->assertSame(200, $status);
        $this->assertStringContainsString('<h1 class="jobname">wp:cwt_ok</h1>', $job);

        // Changes carry a WordPress nonce, which the forms' actions hold.
        $this->assertSame(1, preg_match('#<form class="inline" method="post" action="([^"]*cw=%2Fcheck[^"]*)"#', $page, $m));
        $action = html_entity_decode($m[1]);
        $this->assertStringContainsString('_wpnonce=', $action);
        $origin = 'http://127.0.0.1:' . self::$port;
        [$status, $headers] = self::http('POST', (string) preg_replace('#^https?://[^/]+#', '', $action), $admin + ['Origin' => $origin]);
        $this->assertSame(303, $status);
        $this->assertSame("{$origin}/wp-admin/admin.php?page=cronwatch&cw=%2F", $headers['location']);
        [$status] = self::http('POST', '/wp-admin/admin.php?page=cronwatch&cw=%2Fcheck', $admin + ['Origin' => $origin]);
        $this->assertSame(403, $status, 'no nonce, no change');
        [$status] = self::http('POST', (string) preg_replace('#^https?://[^/]+#', '', $action), $admin + ['Origin' => 'https://evil.example']);
        $this->assertSame(403, $status, 'the dashboard\'s own cross-site check stands too');

        // Not for a subscriber, nor for anyone signed out; and nothing of it outside wp-admin.
        [$status] = self::http('GET', '/wp-admin/admin.php?page=cronwatch&cw=%2Fapi%2Fjobs', ['Cookie' => self::signedIn('reader')]);
        $this->assertSame(403, $status);
        [$status, $headers] = self::http('GET', '/wp-admin/admin.php?page=cronwatch&cw=%2Fapi%2Fjobs');
        $this->assertSame(302, $status, 'signed out, wp-admin sends the browser to log in');
        $this->assertStringContainsString('wp-login.php', $headers['location']);
    }

    public function testTheJsonApiIsOffUntilTheOwnerTurnsItOnWithAToken(): void
    {
        $api = '/?rest_route=/cronwatch/v1/api/jobs';
        [$status] = self::http('GET', $api, ['Authorization' => 'Bearer anything']);
        $this->assertSame(404, $status, 'off: no route at all');

        $token = self::inWp(<<<'PHP'
            wp_set_current_user(get_user_by('login', 'admin')->ID);
            $notice = Cronwatch\WordPress\Admin::saveSettings(['api_enabled' => '1']);
            echo json_encode([$notice, get_option('cronwatch_settings')['api_token'], (bool) get_transient('cronwatch_new_token_' . get_current_user_id())]);
            PHP);
        [$notice, $secret, $shownOnce] = $token;
        $this->assertSame('saved', $notice);
        $this->assertSame(40, strlen($secret), 'turned on with no token given, the plugin makes one');
        $this->assertTrue($shownOnce, 'and the settings page shows it once');

        [$status, $headers, $body] = self::http('GET', $api, ['Authorization' => "Bearer {$secret}"]);
        $this->assertSame(200, $status);
        $this->assertSame('application/json; charset=utf-8', $headers['content-type']);
        $this->assertSame('no-store', $headers['cache-control']);
        $this->assertStringStartsWith('{"ok":true,"jobs":[', $body);
        $this->assertStringContainsString('"name":"wp:cwt_ok"', $body);
        $this->assertStringNotContainsString('\/', $body, 'the library\'s JSON, not the REST server\'s (which escapes slashes)');
        [$status, , $body] = self::http('GET', $api);
        $this->assertSame([401, '{"ok":false,"error":"Unauthorized"}'], [$status, $body]);
        [$status] = self::http('GET', $api, ['Authorization' => 'Bearer wrong']);
        $this->assertSame(401, $status);
        [$status, , $body] = self::http('POST', '/?rest_route=/cronwatch/v1/api/check', ['Authorization' => "Bearer {$secret}"]);
        $this->assertSame(200, $status);
        $this->assertStringStartsWith('{"ok":true,"checkedAt":', $body);
        [$status, , $body] = self::http('GET', '/?rest_route=/cronwatch/v1/api/jobs/wp%3Acwt_ok&runs=1', ['Authorization' => "Bearer {$secret}"]);
        $this->assertSame(200, $status);
        $this->assertCount(1, json_decode($body, true)['runs']);
        [$status] = self::http('GET', '/?rest_route=/cronwatch/v1/jobs', ['Authorization' => "Bearer {$secret}"]);
        $this->assertSame(404, $status, 'only the API: the dashboard\'s pages stay in wp-admin');

        $short = self::inWp('wp_set_current_user(1); echo json_encode(Cronwatch\WordPress\Admin::saveSettings(["api_enabled" => "1", "api_token" => "too-short"]));');
        $this->assertSame('token', $short);
        self::inWp('update_option("cronwatch_settings", Cronwatch\WordPress\Plugin::DEFAULTS); echo json_encode(true);');
        [$status] = self::http('GET', $api, ['Authorization' => "Bearer {$secret}"]);
        $this->assertSame(404, $status, 'off again');
    }

    public function testNetworkActivationSchedulesTheCheckOnEverySiteAndOnSitesMadeLater(): void
    {
        $dir = self::$dir . '/network';
        mkdir($dir);
        $parts = parse_url(self::$url);
        $host = ($parts['host'] ?? '127.0.0.1') . (isset($parts['port']) ? ':' . $parts['port'] : '');
        self::must(['core', 'download', '--version=' . self::$version, '--skip-content', '--force'], '', $dir);
        self::must(['config', 'create', '--dbname=' . ltrim((string) ($parts['path'] ?? ''), '/'), '--dbuser=' . rawurldecode((string) ($parts['user'] ?? '')),
            '--dbpass=' . rawurldecode((string) ($parts['pass'] ?? '')), "--dbhost={$host}", '--dbprefix=' . self::networkPrefix(), '--skip-check', '--extra-php'],
            "define( 'DISABLE_WP_CRON', true );\n", $dir);
        self::must(['core', 'multisite-install', '--url=cwms.test', '--title=CronWatch network', '--admin_user=admin', '--admin_password=' . bin2hex(random_bytes(8)),
            '--admin_email=admin@example.com', '--skip-email'], '', $dir);
        @mkdir("{$dir}/wp-content/plugins", 0777, true);
        $archive = new \ZipArchive();
        $archive->open(self::buildZip(self::$dir . '/build-network'));
        $archive->extractTo("{$dir}/wp-content/plugins");
        $archive->close();
        self::must(['site', 'create', '--slug=early'], '', $dir);

        $hooks = fn (string $url): array => array_column(json_decode(self::must(['cron', 'event', 'list', "--url={$url}", '--fields=hook', '--format=json'], '', $dir), true), 'hook');
        $tables = fn (string $site): array => self::pdo()->query('SHOW TABLES LIKE ' . self::pdo()->quote(self::networkPrefix() . $site . 'cronwatch%'))->fetchAll(\PDO::FETCH_COLUMN);
        self::must(['plugin', 'activate', 'cronwatch', '--network'], '', $dir);
        $this->assertContains('cronwatch_check', $hooks('cwms.test'));
        $this->assertContains('cronwatch_check', $hooks('cwms.test/early/'), 'a site made before activation gets the check');
        $this->assertCount(3, $tables('2_'));

        self::must(['site', 'create', '--slug=later'], '', $dir);
        $this->assertContains('cronwatch_check', $hooks('cwms.test/later/'), 'a site made after activation gets it too');
        $this->assertCount(3, $tables('3_'), 'and its tables');
        $this->assertMatchesRegularExpression('/^cronwatch: checked \d+ jobs?, sent \d+ alerts?$/', trim(self::must(['cronwatch', 'check', '--url=cwms.test/later/'], '', $dir)));

        self::must(['plugin', 'deactivate', 'cronwatch', '--network'], '', $dir);
        foreach (['cwms.test', 'cwms.test/early/', 'cwms.test/later/'] as $url) {
            $this->assertNotContains('cronwatch_check', $hooks($url), "{$url} keeps no check once the network deactivates it");
        }
        self::must(['plugin', 'uninstall', 'cronwatch'], '', $dir);
        foreach (['', '2_', '3_'] as $site) {
            $this->assertSame([], $tables($site), "uninstalling drops site {$site}'s tables");
        }
    }

    public function testUninstallingRemovesTheTablesOptionsAndEvents(): void
    {
        self::must(['plugin', 'deactivate', 'cronwatch']);
        $this->assertFalse(self::inWp('echo json_encode(wp_next_scheduled("cronwatch_check"));'), 'deactivating unschedules the check');
        self::must(['plugin', 'uninstall', 'cronwatch']);
        $tables = self::pdo()->query('SHOW TABLES LIKE ' . self::pdo()->quote(self::$prefix . 'cronwatch%'))->fetchAll(\PDO::FETCH_COLUMN);
        $this->assertSame([], $tables);
        $left = self::inWp('global $wpdb; echo json_encode($wpdb->get_col("SELECT option_name FROM {$wpdb->options} WHERE option_name LIKE \'%cronwatch%\'"));');
        $this->assertSame([], $left);
        $this->assertFileDoesNotExist(self::$dir . '/wp-content/plugins/cronwatch');
    }
}
