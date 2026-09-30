<?php

declare(strict_types=1);

namespace Cronwatch\Sources;

use Cronwatch\Alert;
use Cronwatch\Cronwatch;
use Cronwatch\Evaluate;
use Cronwatch\JobDefinition;
use Cronwatch\Js;
use Cronwatch\Output;
use Cronwatch\Run;
use Cronwatch\RunStatus;
use Cronwatch\Source;
use Cronwatch\Store\PostgresStore;

/**
 * Watches pg_cron jobs, which run inside Postgres where nothing can wrap
 * them (sources/pgcron.ts). As a source, on every check it reads cron.job
 * and declares each job with its schedule, then copies new rows of
 * cron.job_run_details in as runs (ids "pgcron:<runid>"), so the usual
 * evaluation raises missed, failed, stuck and slow alerts.
 *
 * A job that is renamed, unscheduled or no longer picked keeps its old
 * name's runs and history, and that name is declared again without a
 * schedule, so it is never reported missed. Its description says why.
 *
 *     $cw = new Cronwatch(
 *         store: new PostgresStore(getenv('DATABASE_URL')),
 *         sources: [new PgCron(getenv('DATABASE_URL'), prefix: 'db:')],
 *     );
 *
 * It reads through a PDO (pdo_pgsql), a postgres:// URL (a connection of
 * its own), or any object with query(string $sql, array $params): array
 * that answers rows as arrays, given the SDK's SQL with $1, $2 placeholders
 * and arrays for the array parameters.
 */
final class PgCron implements Source
{
    /** How many of a job's newest runs are copied, without alerting, the first time it is seen. */
    public const BACKFILL = 20;
    /** Run details read per query, and the most pages read in one sync. */
    public const PAGE = 500;
    public const MAX_PAGES = 10;
    /**
     * How long a run pg_cron has queued but not started (no start_time yet)
     * is waited for. After that it is copied as running from when it was
     * first seen, so a run that never starts is marked stuck like any other.
     */
    public const HOLD_MS = 10 * 60_000;

    public const JOBS_SQL = 'SELECT jobid, jobname, schedule, database, username, active FROM cron.job ORDER BY jobid';
    // pg_settings has no row for a setting the role may not read, where
    // current_setting() raises an error that would abort the caller's transaction.
    public const SETTING_SQL = 'SELECT setting FROM pg_settings WHERE name = $1';
    private const COLUMNS = 'd.runid, d.jobid, d.status, d.return_message, d.start_time, d.end_time';
    // Every tracked job's runs after its cursor, and any run still open here, whatever its job.
    public const RUNS_SQL = 'SELECT ' . self::COLUMNS . '
  FROM cron.job_run_details d
  LEFT JOIN unnest($1::bigint[], $2::bigint[]) AS c(jobid, after) ON d.jobid = c.jobid
  WHERE d.runid > c.after OR d.runid = ANY($3::bigint[])
  ORDER BY d.runid LIMIT ' . self::PAGE;
    public const NEWEST_SQL = 'SELECT ' . self::COLUMNS . ' FROM cron.job_run_details d WHERE d.jobid = $1 ORDER BY d.runid DESC LIMIT ' . self::BACKFILL;

    /** The options of a definition that are declared again, without its schedule, for a name no longer in use. */
    private const UNSCHEDULED = ['description', 'tags', 'grace', 'timeout', 'maxDuration', 'budget', 'failuresBeforeAlert'];

    private readonly object $db;
    private readonly string $prefix;
    private readonly string $idPrefix;
    /** @var list<string|int>|\Closure|null */
    private readonly array|\Closure|null $jobs;
    private readonly ?\Closure $jobName;
    /** @var array<string, mixed>|\Closure|null */
    private readonly array|\Closure|null $options;

    /** @var array<int, int> The newest runid read for each jobid, once known. */
    private array $cursors = [];
    /** @var array<int, int|float> The start of the newest run copied for each jobid: where a restart row with no times is put. */
    private array $lastAt = [];
    /** @var array<int, string> Runs copied while still going, by runid, with their job: read again until they finish, even once a check marks them timeout. */
    private array $pending = [];
    /** @var array<int, int|float> Runs read before they started, by runid, with when they were first seen. */
    private array $held = [];
    /** @var array<int, array{string, array<string, mixed>}> Each job's name and definition as last declared, by jobid. */
    private array $known = [];
    /** @var array<string, string> The last definition declared for each name, so an unchanged job is not declared again. */
    private array $declared = [];
    /** @var array<string, true> Names declared again without a schedule by retire(), whose open runs are still read. */
    private array $retired = [];
    private bool $scanned = false;
    /** @var array<string, true> */
    private array $warned = [];
    /** @var array<int, true> Jobids whose callback failed, reported once until it works again. */
    private array $failing = [];

    /**
     * @param \PDO|string|object $db a pdo_pgsql PDO, a postgres:// URL, or an object with query(string $sql, array $params): array
     * @param list<string|int>|(callable(array<string, mixed>): bool)|null $jobs which jobs to watch: names or ids, or a
     *        function given a cron.job row that picks them. Default every job the role can see.
     * @param string $prefix put before every job name, to keep them apart from your own ("db:"). Also keeps run ids apart.
     * @param (callable(array<string, mixed>): string)|null $jobName the CronWatch name for a cron.job row. Default its jobname
     *        with anything other than letters, digits, ".", "_", ":" and "-" turned into "-", or "pg_cron:<jobid>" when it has
     *        none. The prefix goes in front either way. One that throws or returns no string, like a jobs or options
     *        function that throws, is reported once and fails only that job, which keeps its last declaration until the
     *        callback works again.
     * @param array<string, mixed>|(callable(array<string, mixed>): array<string, mixed>)|null $options grace, timeout,
     *        maxDuration, expect and the rest, for every job or per job. The schedule and timezone always come from pg_cron.
     * @param string|null $timezone the timezone pg_cron reads its cron expressions in. Default the server's cron.timezone,
     *        read from pg_settings, which shows it only to roles with pg_read_all_settings; UTC (pg_cron's default) is
     *        assumed when it cannot be read.
     */
    public function __construct(
        mixed $db,
        array|callable|null $jobs = null,
        string $prefix = '',
        ?callable $jobName = null,
        array|callable|null $options = null,
        private readonly ?string $timezone = null,
    ) {
        $this->db = self::adapter($db);
        $this->jobs = is_callable($jobs) ? \Closure::fromCallable($jobs) : ($jobs === null ? null : array_values($jobs));
        $this->prefix = $prefix;
        $this->idPrefix = "pgcron:{$prefix}";
        $this->jobName = $jobName === null ? null : \Closure::fromCallable($jobName);
        $this->options = is_callable($options) ? \Closure::fromCallable($options) : $options;
    }

    /** What queries go through: an object with query() as it is, or a PDO (given or opened from a URL) wrapped. */
    public static function adapter(mixed $db): object
    {
        if ($db instanceof \PDO) {
            return new PgCronPdo($db);
        }
        if (is_string($db)) {
            if (!extension_loaded('pdo_pgsql')) {
                throw new \LogicException('PgCron needs the pdo_pgsql extension to connect to a URL');
            }
            [$dsn, $user, $password] = PostgresStore::connection($db);
            return new PgCronPdo(new \PDO($dsn, $user, $password, [\PDO::ATTR_ERRMODE => \PDO::ERRMODE_EXCEPTION, \PDO::ATTR_EMULATE_PREPARES => false]));
        }
        if (is_object($db) && method_exists($db, 'query')) {
            return $db;
        }
        throw new \InvalidArgumentException('PgCron needs a PDO, a postgres:// URL, or an object with query(string $sql, array $params): array');
    }

    public function name(): string
    {
        return 'pg_cron';
    }

    // ------------------------------------------------------------ the pure parts

    /**
     * pg_cron takes a cron expression, with "$" for the last day of the
     * month, or "N seconds" for 1 to 59 seconds. Returns the CronWatch
     * schedule, or null for one that has no cadence to watch. pg_cron reads
     * only the first five fields of an expression and ignores the rest, so
     * only those are kept (a sixth would otherwise be read as seconds).
     */
    public static function schedule(string $schedule): ?string
    {
        $text = Js::trim($schedule);
        if (preg_match('/^([0-9]+)[' . Js::WHITESPACE . ']*seconds?$/iDu', $text, $m) === 1) {
            return 'every ' . Js::number((float) $m[1]) . 's';
        }
        if (preg_match('/^@reboot$/iD', $text) === 1) {
            return null;
        }
        $fields = preg_split('/[' . Js::WHITESPACE . ']+/u', $text) ?: [$text];
        if (count($fields) > 5 && !str_starts_with($fields[0], '@')) {
            $fields = array_slice($fields, 0, 5);
        }
        if (count($fields) === 5 && str_contains($fields[2], '$')) {
            $fields[2] = str_replace('$', 'L', $fields[2]);
        }
        return implode(' ', $fields);
    }

    /**
     * The default CronWatch name for a pg_cron job, before the prefix.
     *
     * @param array<string, mixed> $job a cron.job row (jobid and jobname are read)
     */
    public static function jobName(array $job): string
    {
        $jobname = $job['jobname'] ?? null;
        $cleaned = (string) preg_replace('/[^A-Za-z0-9._:-]+/u', '-', is_string($jobname) ? $jobname : '');
        $cleaned = Js::head16((string) preg_replace('/^[^A-Za-z0-9]+/u', '', $cleaned), 100);
        return $cleaned !== '' ? $cleaned : 'pg_cron:' . Js::string($job['jobid'] ?? '');
    }

    private static function finished(mixed $status): bool
    {
        return $status === 'succeeded' || $status === 'failed';
    }

    /**
     * A timestamp as epoch milliseconds, as the SDK's driver reads one: text
     * as Postgres writes a timestamptz ("2026-01-05 03:00:00.123456+00",
     * whose fraction is taken as pg's postgres-date takes it, the
     * milliseconds 1000 * the fraction, cut to a whole number), an ISO 8601
     * string as Date parses it, a DateTimeInterface, or a number.
     */
    public static function epochMs(mixed $value): int|float
    {
        if (is_int($value) || is_float($value)) {
            return $value;
        }
        if ($value instanceof \DateTimeInterface) {
            return (int) $value->format('U') * 1000 + (int) $value->format('v');
        }
        if (!is_string($value)) {
            throw new \InvalidArgumentException('not a timestamp: ' . get_debug_type($value));
        }
        $pattern = '/^\s*(-?[0-9]{4,})-([0-9]{2})-([0-9]{2})([ T])([0-9]{2}):([0-9]{2}):([0-9]{2})(\.[0-9]+)?\s*(Z|[+-][0-9]{2}(?::?[0-9]{2})?(?::?[0-9]{2})?)?\s*$/iD';
        if (preg_match($pattern, $value, $m) !== 1) {
            throw new \InvalidArgumentException("not a timestamp: {$value}");
        }
        $fraction = $m[8] ?? '';
        if ($fraction === '') {
            $ms = 0;
        } elseif ($m[4] === 'T') {
            // Date's own parser: the first three digits.
            $ms = (int) str_pad(substr($fraction, 1, 3), 3, '0');
        } else {
            $ms = (int) (1000 * (float) $fraction);
        }
        $at = Js::dateUtc((int) $m[1], (int) $m[2] - 1, (int) $m[3], (int) $m[5], (int) $m[6], (int) $m[7], $ms);
        $zone = strtoupper($m[9] ?? '');
        if ($zone !== '' && $zone !== 'Z') {
            $digits = str_replace(':', '', substr($zone, 1));
            $offset = (int) substr($digits, 0, 2) * 3600 + (int) substr($digits, 2, 2) * 60 + (int) substr($digits, 4, 2);
            $at -= ($zone[0] === '-' ? -1 : 1) * $offset * 1000;
        }
        return $at;
    }

    /**
     * A row of cron.job_run_details as a CronWatch run, or null for one that
     * has not started (no start_time, not finished). A finished row with no
     * start_time (pg_cron writes these for runs a server restart cut off,
     * "server restarted") starts at its end_time, else at `fallbackAt` (the
     * reader passes the job's newest run's start, or now).
     *
     * @param array<string, mixed>|\stdClass $row
     */
    public static function run(array|\stdClass $row, string $job, string $idPrefix, int|float|null $fallbackAt = null): ?Run
    {
        $row = Js::fields($row);
        $status = $row['status'] ?? null;
        $finishedAt = ($row['end_time'] ?? null) === null ? null : self::epochMs($row['end_time']);
        $done = self::finished($status);
        $start = $row['start_time'] ?? null;
        if ($start === null && !$done) {
            return null;
        }
        $startedAt = $start !== null ? self::epochMs($start) : ($finishedAt ?? $fallbackAt ?? Js::nowMs());
        $message = $row['return_message'] ?? null;
        $message = $message === null ? null : (Js::trim((string) $message) !== '' ? Js::trim((string) $message) : null);
        $state = match ($status) {
            'succeeded' => RunStatus::OK,
            'failed' => RunStatus::FAILED,
            default => RunStatus::RUNNING,
        };
        $end = $done ? max($startedAt, $finishedAt ?? $startedAt) : null;
        return new Run(
            id: $idPrefix . Js::string($row['runid'] ?? ''),
            job: $job,
            status: $state,
            startedAt: $startedAt,
            finishedAt: $end,
            durationMs: $end === null ? null : Evaluate::runDuration($startedAt, $end),
            error: $state === RunStatus::FAILED ? ($message ?? 'pg_cron reported the run as failed') : null,
            output: $state === RunStatus::OK ? $message : null,
            metrics: [],
            trigger: 'pg_cron',
        );
    }

    // ------------------------------------------------------------ syncing

    public function sync(Cronwatch $host): array
    {
        $now = $host->now();
        $timezone = $this->timezone;
        if ($timezone === null || $timezone === '') {
            $tz = $this->setting('cron.timezone');
            if ($tz === null) {
                $this->warnOnce($host, 'tz', 'could not read cron.timezone; assuming UTC. Grant pg_read_all_settings or pass new PgCron($db, timezone: ...).');
            }
            $timezone = $tz === null || preg_match('/^(gmt|utc|z)$/iD', $tz) === 1 ? 'UTC' : $tz;
        }
        $recording = $this->setting('cron.log_run') !== 'off';
        if (!$recording) {
            $this->warnOnce($host, 'log_run', 'cron.log_run is off, so pg_cron records no runs: jobs are watched without their schedules and no run can fail. Turn it on to watch them.');
        }

        $rows = $this->query(self::JOBS_SQL, []);
        if ($rows === []) {
            $this->warnOnce($host, 'empty', "cron.job shows no jobs. pg_cron's row level security shows a role only the jobs it scheduled: connect as that role, or give this one BYPASSRLS.");
        }
        $all = array_map(fn (array $r) => ['jobid' => (int) $r['jobid']] + $r, $rows);
        [$names, $definitions] = $this->declare($host, $all, $timezone, $recording);
        $this->retireUnused($host, $names, $definitions, $all, $rows !== []);
        if (!$recording || $names === []) {
            return [];
        }

        $alerts = [];
        $this->startCursors($host, $names, $alerts, $now);
        $this->readNew($host, $names, $alerts, $now);
        return $alerts;
    }

    /** @return list<array<string, mixed>> */
    private function query(string $sql, array $params): array
    {
        return array_map(fn ($row) => Js::fields($row), array_values($this->db->query($sql, $params)));
    }

    private function warnOnce(Cronwatch $host, string $key, string $message): void
    {
        if (isset($this->warned[$key])) {
            return;
        }
        $this->warned[$key] = true;
        $host->onError(new \RuntimeException($message), 'source pg_cron');
    }

    /** @param array<string, mixed> $job */
    private function picks(array $job): bool
    {
        if ($this->jobs === null) {
            return true;
        }
        if ($this->jobs instanceof \Closure) {
            return (bool) ($this->jobs)($job);
        }
        foreach ($this->jobs as $j) {
            if (is_int($j) ? $j === $job['jobid'] : $j === ($job['jobname'] ?? null)) {
                return true;
            }
        }
        return false;
    }

    private function setting(string $name): ?string
    {
        try {
            $rows = $this->query(self::SETTING_SQL, [$name]);
        } catch (\Throwable) {
            return null;
        }
        $value = $rows[0]['setting'] ?? null;
        return $value === null ? null : (string) $value;
    }

    /** The pg_cron runid of a run id this source wrote, or null. */
    private function runIdOf(string $id): ?int
    {
        if (!str_starts_with($id, $this->idPrefix)) {
            return null;
        }
        $rest = substr($id, strlen($this->idPrefix));
        return preg_match('/^[0-9]{1,15}$/D', $rest) === 1 ? (int) $rest : null;
    }

    /**
     * A definition as text, to tell a changed one from the last declared.
     *
     * @param array<string, mixed> $definition
     */
    private static function keyOf(array $definition): string
    {
        $plain = function (mixed $value) use (&$plain): mixed {
            return match (true) {
                $value instanceof \Stringable => (string) $value,
                $value instanceof \Closure => 'function',
                $value instanceof \DateInterval => \Cronwatch\Duration::parse($value),
                is_array($value) => array_map($plain, $value),
                default => $value,
            };
        };
        return Js::stringify(Js::obj(array_map($plain, $definition)));
    }

    /**
     * Declares each job. A paused one (active = false) keeps its failures but
     * loses its schedule, so it is not missed.
     *
     * A callback of the app's (jobs, jobName, options) that throws, or a
     * jobName that gives no name, fails only its job, as a bad row does:
     * reported once until it works again, and the job carries on as last
     * declared (skipped when it never was), so its runs are still copied.
     *
     * @param list<array<string, mixed>> $all every cron.job row, picked here
     * @return array{array<int, string>, array<int, array<string, mixed>>} each jobid's name and definition as declared
     */
    private function declare(Cronwatch $host, array $all, string $timezone, bool $recording): array
    {
        // One forgotten since it was declared (the dashboard's forget) is declared again, though
        // unchanged: recordRun takes runs only of a declared job.
        $live = [];
        foreach ($host->definedJobs() as $defined) {
            $live[$defined->name] = true;
        }
        $names = [];
        $definitions = [];
        $used = [];
        $trouble = function (int $jobid, string $what) use ($host, &$names, &$definitions, &$used): void {
            if (!isset($this->failing[$jobid])) {
                $this->failing[$jobid] = true;
                $host->onError(new \RuntimeException("pg_cron job {$jobid}: {$what}; it keeps its last declaration until that works"), 'source pg_cron');
            }
            $last = $this->known[$jobid] ?? null;
            if ($last === null || isset($used[$last[0]])) {
                return;
            }
            $names[$jobid] = $last[0];
            $definitions[$jobid] = $last[1];
            $used[$last[0]] = true;
        };
        $threw = fn (\Throwable $e) => Output::errorName($e) . ': ' . Js::wellFormed($e->getMessage());
        foreach ($all as $job) {
            $jobid = $job['jobid'];
            try {
                $picked = $this->picks($job);
            } catch (\Throwable $error) {
                $trouble($jobid, 'the jobs callback threw ' . $threw($error));
                continue;
            }
            if (!$picked) {
                unset($this->failing[$jobid]);
                continue;
            }
            try {
                $base = $this->jobName !== null ? ($this->jobName)($job) : self::jobName($job);
            } catch (\Throwable $error) {
                $trouble($jobid, 'jobName threw ' . $threw($error));
                continue;
            }
            if (!is_string($base)) {
                $trouble($jobid, 'jobName returned ' . ($base === null ? 'null' : get_debug_type($base)) . ', not a name');
                continue;
            }
            try {
                $extra = $this->options instanceof \Closure ? ($this->options)($job) : ($this->options ?? []);
            } catch (\Throwable $error) {
                $trouble($jobid, 'the options callback threw ' . $threw($error));
                continue;
            }
            unset($this->failing[$jobid]);
            $extra = is_array($extra) ? $extra : [];
            $name = $this->prefix . $base;
            if (isset($used[$name])) {
                $name = "{$name}:{$jobid}";
            }
            $used[$name] = true;
            unset($extra['schedule'], $extra['timezone']);
            $active = self::boolean($job['active'] ?? true);
            $schedule = $active && $recording ? self::schedule((string) ($job['schedule'] ?? '')) : null;
            $definition = [
                'description' => "pg_cron job {$jobid} in " . Js::string($job['database'] ?? null) . ' as ' . Js::string($job['username'] ?? null) . ($active ? '' : ' (paused)'),
                'tags' => ['pg_cron'],
            ];
            foreach ($extra as $key => $value) {
                $definition[$key] = $value;
            }
            if ($schedule !== null && $schedule !== '') {
                $definition['schedule'] = $schedule;
                $definition['timezone'] = $timezone;
            }
            try {
                $key = self::keyOf($definition);
                if (($this->declared[$name] ?? null) !== $key || !isset($live[$name])) {
                    try {
                        $host->job($name, $definition);
                    } catch (\Throwable $error) {
                        if (!isset($definition['schedule'])) {
                            throw $error;
                        }
                        // A schedule CronWatch cannot read: watch the runs, not the cadence.
                        $host->onError(new \RuntimeException("pg_cron job {$jobid}: {$error->getMessage()}; watching it without a schedule"), 'source pg_cron');
                        unset($definition['schedule'], $definition['timezone']);
                        $host->job($name, $definition);
                    }
                    $this->declared[$name] = $key;
                }
                $names[$jobid] = $name;
                $definitions[$jobid] = $definition;
            } catch (\Throwable $error) {
                $host->onError($error, "source pg_cron: job {$jobid}");
            }
        }
        return [$names, $definitions];
    }

    private static function boolean(mixed $value): bool
    {
        return in_array($value, [true, 't', 'true', 1, '1'], true);
    }

    /**
     * Declares a name this source no longer uses for any job again, without its schedule.
     *
     * @param JobDefinition|array<string, mixed> $definition
     */
    private function retire(Cronwatch $host, string $name, JobDefinition|array $definition, string $why): void
    {
        $fields = $definition instanceof JobDefinition ? $definition->fields : $definition;
        $next = [];
        foreach (self::UNSCHEDULED as $field) {
            if (($fields[$field] ?? null) !== null) {
                $next[$field] = $fields[$field];
            }
        }
        $next['description'] = ($next['description'] ?? 'pg_cron job') . " ({$why})";
        try {
            $host->job($name, $next);
            $this->declared[$name] = self::keyOf($next);
            $this->retired[$name] = true;
        } catch (\Throwable $error) {
            $host->onError($error, "source pg_cron: job {$name}");
        }
    }

    /**
     * A name this source used for a job that has since been renamed,
     * unscheduled or dropped from `jobs` is declared again without its
     * schedule. Once per process, the same for names left scheduled in the
     * store while no process was watching.
     *
     * @param array<int, string> $names
     * @param array<int, array<string, mixed>> $definitions
     * @param list<array<string, mixed>> $all
     */
    private function retireUnused(Cronwatch $host, array $names, array $definitions, array $all, bool $any): void
    {
        $inUse = array_flip($names);
        foreach (array_keys($inUse) as $name) {
            unset($this->retired[$name]);
        }
        foreach ($this->known as $jobid => [$previous, $definition]) {
            if (isset($inUse[$previous])) {
                continue;
            }
            $renamed = $names[$jobid] ?? null;
            $this->retire($host, $previous, $definition, $renamed !== null ? "renamed to {$renamed}" : 'no longer watched');
        }
        $this->known = [];
        foreach ($names as $jobid => $name) {
            $this->known[$jobid] = [$name, $definitions[$jobid]];
        }
        if ($this->scanned || !$any) {
            return;
        }
        $this->scanned = true;
        try {
            $visible = array_flip(array_map(fn (array $j) => $j['jobid'], $all));
            foreach ($host->store->listJobs() as $stored) {
                $def = $stored->definition;
                $tags = $def->get('tags');
                if (!str_starts_with($stored->name, $this->prefix) || isset($inUse[$stored->name]) || !$def->get('schedule')
                    || !is_array($tags) || !in_array('pg_cron', $tags, true)) {
                    continue;
                }
                if (preg_match('/^pg_cron job ([0-9]+) in /', (string) $def->get('description', ''), $m) !== 1) {
                    continue;
                }
                $jobid = (int) $m[1];
                $current = $names[$jobid] ?? null;
                if (!isset($visible[$jobid])) {
                    $this->retire($host, $stored->name, $def, 'no longer in cron.job');
                } elseif ($current !== null && !str_ends_with($stored->name, substr($current, strlen($this->prefix)))) {
                    // Another pg_cron source's name for the same job ends the same way: that one is left alone.
                    $this->retire($host, $stored->name, $def, "renamed to {$current}");
                }
            }
        } catch (\Throwable $error) {
            $host->onError($error, 'source pg_cron');
        }
    }

    // ------------------------------------------------------------ copying runs

    /**
     * Copies one row. A row that cannot be recorded is reported and skipped;
     * it never stops the others.
     *
     * @param array<int, string> $names
     * @param array<string, mixed> $row
     * @param list<Alert> $alerts
     */
    private function record(Cronwatch $host, array $names, array $row, bool $evaluate, array &$alerts, int|float $now): void
    {
        $runid = (int) $row['runid'];
        $jobid = (int) $row['jobid'];
        $name = $this->pending[$runid] ?? $names[$jobid] ?? null;
        if ($name === null) {
            unset($this->held[$runid]);
            return;
        }
        if (($row['start_time'] ?? null) === null && !self::finished($row['status'] ?? null)) {
            $since = $this->held[$runid] ?? $now;
            if ($now - $since < self::HOLD_MS) {
                $this->held[$runid] = $since;
                return;
            }
            $run = self::run(['start_time' => $since] + $row, $name, $this->idPrefix);
        } else {
            $run = self::run($row, $name, $this->idPrefix, $this->lastAt[$jobid] ?? $now);
        }
        unset($this->held[$runid]);
        if ($run === null) {
            return;
        }
        try {
            array_push($alerts, ...$host->recordRun($run, evaluate: $evaluate));
        } catch (\Throwable $error) {
            $host->onError($error, "source pg_cron: run {$runid}");
            return;
        }
        if ($run->status === RunStatus::RUNNING) {
            $this->pending[$runid] = $name;
        } else {
            unset($this->pending[$runid]);
        }
        if (!isset($this->lastAt[$jobid]) || $run->startedAt > $this->lastAt[$jobid]) {
            $this->lastAt[$jobid] = $run->startedAt;
        }
    }

    /**
     * Where each job left off. Found from the store the first time, so a restart carries on.
     *
     * @param array<int, string> $names
     * @param list<Alert> $alerts
     */
    private function startCursors(Cronwatch $host, array $names, array &$alerts, int|float $now): void
    {
        foreach ($names as $jobid => $name) {
            if (isset($this->cursors[$jobid])) {
                continue;
            }
            $ours = array_values(array_filter($host->store->listRuns($name, self::BACKFILL), fn (Run $r) => $this->runIdOf($r->id) !== null));
            if ($ours !== []) {
                $this->cursors[$jobid] = max(array_map(fn (Run $r) => $this->runIdOf($r->id), $ours));
                $this->lastAt[$jobid] = max(array_map(fn (Run $r) => $r->startedAt, $ours));
                foreach ($ours as $r) {
                    if ($r->status === RunStatus::RUNNING || $r->status === RunStatus::TIMEOUT) {
                        $this->pending[(int) $this->runIdOf($r->id)] = $r->job;
                    }
                }
                continue;
            }
            // First sight: copy recent history quietly, and judge only from the newest finished run on.
            // The cursor goes to the newest row read, whatever is held, so history is never judged later.
            $ordered = array_reverse($this->query(self::NEWEST_SQL, [$jobid]));
            $lastFinished = -1;
            foreach ($ordered as $i => $r) {
                if (self::finished($r['status'] ?? null)) {
                    $lastFinished = $i;
                }
            }
            foreach ($ordered as $i => $row) {
                // Already copied under another name (the job was renamed while no process watched): left there.
                if ($host->store->getRun($this->idPrefix . Js::string($row['runid'])) !== null) {
                    continue;
                }
                $this->record($host, $names, $row, $i >= $lastFinished, $alerts, $now);
            }
            $this->cursors[$jobid] = $ordered !== [] ? (int) $ordered[count($ordered) - 1]['runid'] : 0;
        }
    }

    /**
     * New runs, runs copied while still going (or since marked timeout), and runs not yet started.
     *
     * @param array<int, string> $names
     * @param list<Alert> $alerts
     */
    private function readNew(Cronwatch $host, array $names, array &$alerts, int|float $now): void
    {
        $watched = array_flip($names) + $this->retired;
        foreach ($host->store->runningRuns() as $run) {
            $id = $this->runIdOf($run->id);
            if ($id !== null && isset($watched[$run->job])) {
                $this->pending[$id] = $run->job;
            }
        }
        $open = array_fill_keys(array_keys($this->pending), true) + array_fill_keys(array_keys($this->held), true);
        $complete = false;
        for ($page = 0; $page < self::MAX_PAGES; $page++) {
            $jobids = array_keys($names);
            $details = $this->query(self::RUNS_SQL, [$jobids, array_map(fn (int $j) => $this->cursors[$j] ?? 0, $jobids), array_keys($open)]);
            foreach ($details as $row) {
                $jobid = (int) $row['jobid'];
                $runid = (int) $row['runid'];
                unset($open[$runid]);
                $this->record($host, $names, $row, true, $alerts, $now);
                // Held or not, the cursor moves on: a held run is read again by its runid.
                if (isset($names[$jobid]) && $runid > ($this->cursors[$jobid] ?? 0)) {
                    $this->cursors[$jobid] = $runid;
                }
            }
            if (count($details) < self::PAGE) {
                $complete = true;
                break;
            }
        }
        // Every row was read and these were not among them: pg_cron no longer has them.
        if ($complete) {
            foreach (array_keys($open) as $runid) {
                unset($this->pending[$runid], $this->held[$runid]);
            }
        }
    }
}
