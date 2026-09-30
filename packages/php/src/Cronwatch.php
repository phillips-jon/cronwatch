<?php

declare(strict_types=1);

namespace Cronwatch;

use Cronwatch\Alerts\AlertChannel;
use Cronwatch\Alerts\ChannelContext;
use Cronwatch\Alerts\Console;
use Cronwatch\Alerts\Custom;
use Cronwatch\Cron\Zone;
use Cronwatch\Job\AbortSignal;
use Cronwatch\Job\JobContext;
use Cronwatch\Job\JobHandle;
use Cronwatch\Job\Outcome;
use Cronwatch\Job\RetryFinish;
use Cronwatch\Job\RunHandle;
use Cronwatch\Job\RunRecorder;
use Cronwatch\Store\ComparesAndSetsState;
use Cronwatch\Store\DeletesRunIf;
use Cronwatch\Store\MemoryStore;
use Cronwatch\Store\Store;
use Cronwatch\Store\UpdatesRunIf;

/**
 * The client (client.ts): declares jobs, records their runs, checks for
 * missed and stuck ones, and sends alerts.
 *
 * A PHP process runs one thing at a time, so a job runs in the caller, and
 * alerts and triage are sent in turn after its run is recorded. Other
 * processes sharing the store are kept in step by the store's conditional
 * writes (compareAndSetState, updateRunIf). The store failing never stops a
 * job: store errors go to onError and the job's own outcome is returned or
 * thrown.
 *
 *     $cw = new Cronwatch(store: new SqliteStore('/var/lib/app/cronwatch.db'));
 *     $nightly = $cw->job('nightly-report', ['schedule' => '0 2 * * *', 'timezone' => 'UTC']);
 *     $nightly->run(fn (JobContext $job) => build_report($job));
 *     $cw->check();   // from a crontab line every few minutes, or the framework's scheduler
 */
final class Cronwatch
{
    public const VERSION = '0.9.0';

    public const NAME_PATTERN = '/^[A-Za-z0-9][A-Za-z0-9._:-]{0,119}$/D';
    public const TRIAGE_TIMEOUT_MS = 25_000;
    public const PRUNE_INTERVAL_MS = 60 * 60_000;
    /** Undelivered alerts kept per job for retry; the oldest go first. */
    public const MAX_UNDELIVERED = Evaluate::MAX_UNDELIVERED;
    /** Wall-clock time one check spends retrying undelivered alerts, across every job. */
    public const RETRY_BUDGET_MS = 20_000;
    /** Reads and writes of one job's state before an update gives up on a store that keeps changing under it. */
    public const STATE_ATTEMPTS = 10;
    /** Runs read for a baseline, and the most read when failures crowd out the successes. */
    public const HISTORY_PAGE = Evaluate::BASELINE_WINDOW + 5;
    public const HISTORY_MAX = 200;
    /** Run ids that start with this belong to the pg_cron source. */
    public const RESERVED_RUN_ID_PREFIX = 'pgcron:';
    /** The options `defaults` may set. */
    public const DEFAULT_OPTIONS = ['grace', 'timeout', 'timezone', 'failuresBeforeAlert'];

    public readonly Store $store;
    /** @var list<AlertChannel> */
    public readonly array $alerts;
    /** @var list<Source> */
    public readonly array $sources;
    /** The secret an outside cron may present to the dashboard's check endpoint (routes()) and to a job's handler(), or null. */
    public readonly ?string $cronSecret;
    /** cronSecret was passed as false: handlers may run without a secret. */
    public readonly bool $secretOptOut;
    public readonly int|float $retentionMs;
    /** @var array<string, mixed> */
    public readonly array $defaults;

    private readonly ?\Closure $triage;
    private readonly \Closure $redact;
    private readonly ?\Closure $onError;
    private readonly \Closure $clock;
    /** Wall-clock milliseconds, monotonic, for the retry budget. Tests set it. */
    private \Closure $wall;
    /** "check": queue alerts in the store for another process's check to send. */
    private readonly bool $deferDelivery;
    private readonly bool $usingDefaultStore;
    /** @var array<string, JobDefinition> */
    private array $definitions = [];
    /** @var array<string, true> */
    private array $synced = [];
    private bool $ready = false;
    private bool $checking = false;
    private int|float $lastPruneAt = 0;
    /** @var array<int, array{JobDefinition, Run, RunRecorder, bool, bool}> Runs of execute() in progress (recorded, and whether the start's state change waits for the finish), for the shutdown hook. */
    private array $inProgress = [];
    private int $nextExecution = 0;
    private bool $shutdownHooked = false;
    private bool $warnedNoSecret = false;

    /** @var list<JobContext> The runs of execute() in progress in this process, innermost last. */
    private static array $current = [];
    /** Memory given back to PHP when a fatal error (memory exhausted, say) ends a run, so the run can still be recorded. */
    private static ?string $reserve = null;

    /**
     * @param Store|null $store where jobs, runs and state live; default an in-memory store that forgets when the process ends
     * @param list<AlertChannel|callable>|null $alerts where alerts go; default the console. A callable is a Custom channel named "custom".
     * @param callable(TriageContext): ?string|null $triage adds a short diagnosis to every alert but recoveries
     * @param list<Source> $sources where runs this process does not wrap come from; each is synced at the start of every check
     * @param string|false|null $cronSecret the secret the dashboard's check endpoint (routes()) also accepts, and a job's
     *        handler() requires; null reads CRON_SECRET, "" counts as unset, and false lets both run without one
     * @param mixed $retention how long finished runs are kept; default "30d"
     * @param array<string, mixed> $defaults grace, timeout, timezone and failuresBeforeAlert for every job that does not set its own
     * @param callable(string): string|false|null $redact applied to every run's output and error before it is stored, shown or
     *        sent. The default (Output::redactSecrets) blanks values that look like secrets. Pass your own function, or false to
     *        keep output as logged. One that throws or returns something other than a string is reported and the default is used.
     * @param string $deliver "now" sends alerts from this process; "check" queues them in the store for the next check in a
     *        process that delivers now (for a process that cannot reach the network)
     * @param callable(\Throwable, string): void|null $onError anything that goes wrong outside a job: the store failing, a
     *        channel failing. Default: PHP's error log (standard error on the command line).
     * @param callable(): (int|float)|null $now the clock, in epoch milliseconds. Tests use this.
     */
    public function __construct(
        ?Store $store = null,
        ?array $alerts = null,
        ?callable $triage = null,
        array $sources = [],
        string|false|null $cronSecret = null,
        mixed $retention = '30d',
        array $defaults = [],
        callable|false|null $redact = null,
        string $deliver = 'now',
        ?callable $onError = null,
        ?callable $now = null,
    ) {
        $this->usingDefaultStore = $store === null;
        $this->store = $store ?? new MemoryStore();
        $channels = [];
        foreach ($alerts ?? [new Console()] as $channel) {
            $channels[] = match (true) {
                $channel instanceof AlertChannel => $channel,
                is_callable($channel) => new Custom('custom', $channel),
                default => throw new \InvalidArgumentException('an alert channel must be an AlertChannel or a callable'),
            };
        }
        $this->alerts = $channels;
        $this->triage = $triage === null ? null : \Closure::fromCallable($triage);
        foreach ($sources as $source) {
            if (!$source instanceof Source) {
                throw new \InvalidArgumentException('a source must implement Cronwatch\\Source');
            }
        }
        $this->sources = array_values($sources);
        $secret = $cronSecret === null ? Env::read('CRON_SECRET') : $cronSecret;
        $this->cronSecret = is_string($secret) && $secret !== '' ? $secret : null;
        $this->secretOptOut = $cronSecret === false;
        $this->retentionMs = Duration::parse($retention ?? '30d', 'retention');
        foreach (array_keys($defaults) as $key) {
            if (!in_array($key, self::DEFAULT_OPTIONS, true)) {
                throw new \InvalidArgumentException('defaults may set ' . implode(', ', self::DEFAULT_OPTIONS) . ", not {$key}");
            }
        }
        $this->defaults = $defaults;
        $this->redact = match (true) {
            $redact === false => fn (string $text): string => $text,
            $redact === null => Output::redactSecrets(...),
            default => $this->guardedRedact(\Closure::fromCallable($redact)),
        };
        if ($deliver !== 'now' && $deliver !== 'check') {
            throw new \InvalidArgumentException('deliver must be "now" or "check", not ' . Js::quote($deliver));
        }
        $this->deferDelivery = $deliver === 'check';
        $this->onError = $onError === null ? null : \Closure::fromCallable($onError);
        $this->clock = $now === null ? Js::nowMs(...) : \Closure::fromCallable($now);
        $this->wall = fn (): float => hrtime(true) / 1e6;
    }

    // ------------------------------------------------------------ the API

    /** Epoch milliseconds, from the clock the client was given. */
    public function now(): int|float
    {
        return ($this->clock)();
    }

    /**
     * The context of the run in progress in this process (the innermost, when
     * one job runs another), or null. What a function wrapped with
     * JobHandle::wrap() logs through.
     */
    public static function current(): ?JobContext
    {
        return self::$current === [] ? null : self::$current[count(self::$current) - 1];
    }

    /**
     * Declare a job. Call it once, where the app starts, and keep the handle.
     *
     * Options, with the SDK's names: schedule (a five or six field cron
     * expression, a nickname such as "@hourly", or "every 5m"), timezone
     * (IANA; default PHP's), grace (default "10m"), timeout (default "1h"),
     * maxDuration, budget (['metric' => ceiling]), expect (a string the
     * output must contain, a Pattern it must match, or a callable),
     * failuresBeforeAlert (default 1), description, tags. Durations are
     * strings such as "1h30m", milliseconds, or a DateInterval.
     *
     * @param array<string, mixed> $options
     * @throws \InvalidArgumentException for a bad name or option, with the SDK's message
     */
    public function job(string $name, array $options = []): JobHandle
    {
        if (preg_match(self::NAME_PATTERN, $name) !== 1) {
            throw new \InvalidArgumentException("job name \"{$name}\" must be 1 to 120 characters of letters, digits, \".\", \"_\", \":\" or \"-\"");
        }
        $definition = $this->buildDefinition($name, $options);
        self::validateDefinition($definition);
        $this->definitions[$name] = $definition;
        unset($this->synced[$name]);
        return new JobHandle($this, $definition);
    }

    /**
     * Run a job by name without keeping a handle, declaring it on first use
     * (or again, when options are given). Returns what the function returns.
     *
     * @param array<string, mixed>|null $options
     */
    public function run(string $name, callable $fn, ?array $options = null): mixed
    {
        $declared = $this->definitions[$name] ?? null;
        $handle = $options !== null || $declared === null ? $this->job($name, $options ?? []) : new JobHandle($this, $declared);
        return $handle->run($fn);
    }

    /** @return list<JobDefinition> the definitions declared in this process */
    public function definedJobs(): array
    {
        return array_values($this->definitions);
    }

    /** A handle on a run started elsewhere, as job(name)->resume(runId). The job must be declared in this process. */
    public function resumeRun(string $name, string $runId): RunHandle
    {
        $definition = $this->definitions[$name] ?? throw new \InvalidArgumentException("resumeRun: job \"{$name}\" is not declared; call job() first");
        return $this->resumeHandle($definition, $runId);
    }

    /**
     * Record a run that happened outside this process, for a source. Its job
     * must be declared with job() first. Runs are keyed by id: a new one is
     * inserted, a stored one still running (or marked timeout by a check) is
     * finished when this one is not running, and anything else is left alone,
     * so recording the same run twice changes nothing. When two processes
     * record the same finish, only the one whose write lands evaluates it.
     * `evaluate: false` stores it without judging it, for history imported on
     * first sight. A metric that is not a finite number throws before
     * anything is written, as a job's metric() does. Returns the alerts it
     * sent.
     *
     * @param Run|array<string, mixed> $run
     * @return list<Alert>
     */
    public function recordRun(Run|array $run, bool $evaluate = true): array
    {
        $given = $run instanceof Run ? $run : Run::fromJson($run);
        $declared = $this->definitions[$given->job] ?? throw new \InvalidArgumentException("recordRun: job \"{$given->job}\" is not declared; call job() first");
        if (str_contains($given->id, "\0")) {
            throw new \InvalidArgumentException("recordRun: run ids cannot contain a NUL character (job \"{$given->job}\")");
        }
        // Refused as a job's metric() refuses them: a store keeps NaN and INF as null.
        foreach ($given->metrics as $metric => $value) {
            if (!Js::isFinite($value)) {
                throw new \InvalidArgumentException("recordRun: metric \"{$metric}\" must be a finite number (job \"{$given->job}\", run \"{$given->id}\")");
            }
        }
        $this->sync($declared);
        $run = clone $given;
        if ($run->status === RunStatus::OK) {
            $unmet = Serialize::checkExpectation($declared->get('expect'), $run->output);
            if ($unmet !== null) {
                $run->status = RunStatus::FAILED;
                $run->error = $unmet;
            }
        }
        if ($run->output !== null) {
            $run->output = Output::redactAndCap(Js::wellFormed($run->output), $this->redact);
        }
        if ($run->error !== null) {
            $run->error = Output::redactAndCap(Js::wellFormed($run->error), $this->redact);
        }
        $definition = Serialize::toStored($declared);

        $stored = $this->store->getRun($run->id);
        if ($stored !== null) {
            return $this->recordOver($definition, $stored, $run, $evaluate);
        }
        try {
            $this->store->insertRun($run);
        } catch (\Throwable $error) {
            // Another process recorded it first.
            $again = $this->tryGetRun($run->id);
            if ($again !== null) {
                return $this->recordOver($definition, $again, $run, $evaluate);
            }
            throw $error;
        }
        if (!$evaluate) {
            return [];
        }
        $this->updateState($run->job, fn (JobState $before) => [Evaluate::onRunStart($before), null]);
        if ($run->status === RunStatus::RUNNING) {
            return [];
        }
        return $this->finishRun($definition, $run, $this->now());
    }

    /**
     * Reports, once per client, that a handler() refused a request for want
     * of a secret.
     *
     * @internal Called by Job\Handler.
     */
    public function warnNoSecret(): void
    {
        if ($this->warnedNoSecret) {
            return;
        }
        $this->warnedNoSecret = true;
        $this->report(new \RuntimeException('handler() refused a request because no CRON_SECRET is set; pass secret: false to allow unauthenticated requests'), 'handler');
    }

    /** Hands an error to onError, as a source reports what went wrong. */
    public function onError(\Throwable $error, string $where): void
    {
        $this->report($error, $where);
    }

    /**
     * Look for missed and stuck runs across every job, send alerts, retry
     * alerts no channel accepted, and prune old runs. Call it from a crontab
     * line, the framework's scheduler or by hand, every few minutes.
     */
    public function check(): CheckResult
    {
        if ($this->checking) {
            throw new \LogicException('check() was called from inside a check (by a channel, a source or triage)');
        }
        $this->checking = true;
        try {
            return $this->runCheck();
        } finally {
            $this->checking = false;
        }
    }

    /** @return list<JobSummary> every job the store knows about, with its health. Sends no alerts. */
    public function jobs(): array
    {
        return array_map(fn (JobWithRuns $entry) => $entry->job, $this->jobsWithRuns(0));
    }

    /** @return list<JobWithRuns> every job's summary with its newest `limit` runs, read together. What the dashboard shows. */
    public function jobsWithRuns(mixed $limit = 20): array
    {
        $this->ensureReady();
        $jobs = $this->writtenJobs();
        $at = $this->now();
        $count = self::clampLimit($limit, 20, 0);
        return array_map(fn (StoredJob $stored) => $this->snapshot($stored, $at, $count), $jobs);
    }

    /** @return list<StoredJob> every job the store knows about, as stored, by name. Reads nothing else. */
    public function storedJobs(): array
    {
        $this->ensureReady();
        return $this->store->listJobs();
    }

    /** A job's summary, or null for one the store does not have. One declared here and forgotten elsewhere is written again. */
    public function jobSummary(string $name): ?JobSummary
    {
        $this->ensureReady();
        if (isset($this->definitions[$name])) {
            $this->sync($this->definitions[$name], true);
        }
        $stored = $this->store->getJob($name);
        return $stored === null ? null : $this->snapshot($stored, $this->now(), 0)->job;
    }

    /** @return list<Run> a job's runs, newest first. `limit` is a whole number from 1 to 500. */
    public function runs(string $name, mixed $limit = 50): array
    {
        $this->ensureReady();
        return $this->store->listRuns($name, self::clampLimit($limit, 50, 1));
    }

    public function getRun(string $id): ?Run
    {
        $this->ensureReady();
        return $this->store->getRun($id);
    }

    /**
     * Stop alerts for a job for a while. State keeps updating underneath. The
     * end is a whole millisecond, held at 2^53 - 1 (see Evaluate::silenceEnd).
     */
    public function silence(string $name, mixed $duration): JobState
    {
        $ms = Duration::parse($duration, 'silence duration');
        return $this->patchState($name, function (JobState $state) use ($ms): void {
            $state->silencedUntil = Evaluate::silenceEnd($this->now(), $ms);
        });
    }

    public function unsilence(string $name): JobState
    {
        return $this->patchState($name, function (JobState $state): void {
            $state->silencedUntil = null;
        });
    }

    /**
     * Remove a job and its runs from the store. A job still declared in code
     * comes back: here on its next run, and in any other process that
     * declares it on its next run there, or at that process's next check or
     * dashboard read.
     */
    public function forget(string $name): void
    {
        $this->ensureReady();
        unset($this->definitions[$name], $this->synced[$name]);
        $this->store->deleteJob($name);
    }

    public function close(): void
    {
        $this->store->close();
    }

    /**
     * The dashboard and JSON API (the SDK's cw.routes()). Call serve() on it
     * from a script, handle() with a Web\Request, or put it in a PSR-15 stack
     * with Web\PsrHandler or Web\PsrMiddleware. See Web\Dashboard.
     *
     * @param string|false|null $token null reads CRONWATCH_TOKEN, "" counts as unset, false serves the dashboard open
     * @param string|null $basePath where the dashboard is mounted; default the script of a path-info URL, else "/cronwatch"
     * @param string|null $origin the public origin, for an app behind a proxy
     * @param bool $trustProxy take the public origin from X-Forwarded-Proto and X-Forwarded-Host
     */
    public function routes(string|false|null $token = null, ?string $basePath = null, ?string $origin = null, bool $trustProxy = false): Web\Dashboard
    {
        return new Web\Dashboard($this, token: $token, basePath: $basePath, origin: $origin, trustProxy: $trustProxy);
    }

    // ------------------------------------------------------------ internals

    /** Hands an error to onError. An onError that throws is not allowed to take the job down with it. */
    private function report(\Throwable $error, string $where): void
    {
        try {
            if ($this->onError !== null) {
                ($this->onError)($error, $where);
                return;
            }
            Console::write("[cronwatch] {$where}: " . get_class($error) . ': ' . $error->getMessage());
        } catch (\Throwable $problem) {
            Console::write('[cronwatch] onError threw ' . get_class($problem) . ': ' . $problem->getMessage() . " (reporting {$where}: {$error->getMessage()})");
        }
    }

    /**
     * A custom redact, made safe: one that throws or returns something other
     * than a string is reported and the default is used instead, so a broken
     * redact neither stops the run finishing nor leaks what it was given.
     */
    private function guardedRedact(\Closure $redact): \Closure
    {
        return function (string $text) use ($redact): string {
            try {
                $out = $redact($text);
                if (!is_string($out)) {
                    throw new \TypeError('redact must return a string, not ' . ($out === null ? 'null' : get_debug_type($out)));
                }
                return Js::wellFormed($out);
            } catch (\Throwable $error) {
                $this->report($error, 'redact');
                return Output::redactSecrets($text);
            }
        };
    }

    /** @param array<string, mixed> $options */
    private function buildDefinition(string $name, array $options): JobDefinition
    {
        $unknown = array_diff(array_map('strval', array_keys($options)), JobDefinition::OPTIONS);
        if ($unknown !== []) {
            throw new \InvalidArgumentException("job \"{$name}\": unknown option " . implode(', ', $unknown));
        }
        $fields = [];
        foreach ($this->defaults as $key => $value) {
            $fields[$key] = $value;
        }
        foreach ($options as $key => $value) {
            $fields[$key] = $value;
        }
        unset($fields['name']);
        $fields['name'] = $name;
        return new JobDefinition($fields);
    }

    /** Throws a clear error for options that would otherwise quietly turn a check off. */
    private static function validateDefinition(JobDefinition $def): void
    {
        $name = (string) $def->get('name');
        $schedule = $def->get('schedule');
        $timezone = $def->get('timezone');
        if ($schedule !== null) {
            if (!is_string($schedule) || Js::trim($schedule) === '') {
                throw new \InvalidArgumentException("job \"{$name}\": schedule must be a non-empty string");
            }
            Schedule::parse($schedule, is_string($timezone) && $timezone !== '' ? $timezone : null);
        }
        if ($timezone !== null && !Zone::isValid($timezone)) {
            throw new \InvalidArgumentException("job \"{$name}\": timezone \"" . Js::string($timezone) . '" is not an IANA timezone');
        }
        if ($def->get('grace') !== null) {
            Duration::parse($def->get('grace'), 'grace');
        }
        if ($def->get('timeout') !== null && Duration::parse($def->get('timeout'), 'timeout') <= 0) {
            throw new \InvalidArgumentException("job \"{$name}\": timeout must be longer than zero");
        }
        if ($def->get('maxDuration') !== null && Duration::parse($def->get('maxDuration'), 'maxDuration') <= 0) {
            throw new \InvalidArgumentException("job \"{$name}\": maxDuration must be longer than zero");
        }
        $failures = $def->get('failuresBeforeAlert');
        if ($failures !== null && !(Js::isInteger($failures) && $failures >= 1)) {
            throw new \InvalidArgumentException("job \"{$name}\": failuresBeforeAlert must be a whole number, 1 or more (got " . Js::string($failures) . ')');
        }
        $budget = $def->get('budget');
        if ($budget !== null) {
            if (!is_array($budget)) {
                throw new \InvalidArgumentException("job \"{$name}\": budget must be an object of { metric: ceiling }");
            }
            foreach ($budget as $metric => $ceiling) {
                if (!(Js::isFinite($ceiling) && $ceiling >= 0)) {
                    throw new \InvalidArgumentException("job \"{$name}\": budget.{$metric} must be a finite number, 0 or more (got " . Js::string($ceiling) . ')');
                }
            }
        }
        $expect = $def->get('expect');
        if ($expect !== null && !is_string($expect) && !$expect instanceof Pattern && !is_callable($expect)) {
            throw new \InvalidArgumentException("job \"{$name}\": expect must be a string, a Pattern or a callable");
        }
    }

    private function ensureReady(): void
    {
        if ($this->ready) {
            return;
        }
        $this->store->init();
        if ($this->usingDefaultStore && Env::isProduction()) {
            Console::write('[cronwatch] using the in-memory store: runs and state are lost when the process ends. Pass a store such as Cronwatch\\Store\\SqliteStore or Cronwatch\\Store\\MysqlStore.');
        }
        // Only once init has gone through: a failure is tried again on the next call.
        $this->ready = true;
    }

    /**
     * Writes the declaration of `definition`'s name as it stands, unless the
     * store has it. A handle kept from an earlier declaration writes the one
     * that replaced it, never its own over it, and one forgotten since writes
     * its own. One process writes one thing at a time, so only a store that
     * calls back into the client (a hook inside it, say) can declare the name
     * again while its write is under way: the name is then still to be
     * written, whatever was written meanwhile, since this write may have
     * landed after it. A name is marked as written only while that same
     * declaration stands, so a forget that lands during the write (deleting
     * the row after it) leaves the name to be written again, as does one
     * forgotten before it.
     *
     * With `confirm`, as a run starts, a name already written is read back:
     * another process may have forgotten the job since, and a job still
     * declared here comes back on its next run.
     */
    private function sync(JobDefinition $definition, bool $confirm = false): void
    {
        $this->ensureReady();
        $name = (string) $definition->get('name');
        if (isset($this->synced[$name])) {
            if (!$confirm || $this->store->getJob($name) !== null) {
                return;
            }
            unset($this->synced[$name]);
        }
        $standing = $this->definitions[$name] ?? $definition;
        $this->store->upsertJob(Serialize::toStored($standing), $this->now());
        if (($this->definitions[$name] ?? null) === $standing) {
            $this->synced[$name] = true;
        } else {
            unset($this->synced[$name]);
        }
    }

    /**
     * Every stored job, once each declaration has been written. A job
     * declared here that the store no longer has was forgotten by another
     * process after this one wrote it: it is written again, as its next run
     * would, so it is checked and shown while any process still declares it.
     *
     * @return list<StoredJob>
     */
    private function writtenJobs(): array
    {
        foreach ($this->definitions as $definition) {
            $this->sync($definition);
        }
        $jobs = $this->store->listJobs();
        $listed = [];
        foreach ($jobs as $job) {
            $listed[$job->name] = true;
        }
        $missing = array_filter($this->definitions, fn (JobDefinition $d) => !isset($listed[(string) $d->get('name')]));
        if ($missing === []) {
            return $jobs;
        }
        foreach ($missing as $name => $definition) {
            // Not one forgotten or declared again meanwhile.
            if (($this->definitions[$name] ?? null) !== $definition) {
                continue;
            }
            unset($this->synced[$name]);
            $this->sync($definition);
        }
        return $this->store->listJobs();
    }

    private function readState(string $job): JobState
    {
        return Evaluate::normalizeState($this->store->getState($job), $job);
    }

    private static function sameState(JobState $a, JobState $b): bool
    {
        return Js::stringify($a) === Js::stringify($b);
    }

    /**
     * Every read-modify-write of a job's state goes through here. It reads
     * the state, asks `change` for the next one, and writes it with the
     * version one higher, only if the stored version is still the one read.
     * When another process wrote in between, the write is refused and it
     * starts again from a fresh read, up to STATE_ATTEMPTS times. So `change`
     * may run more than once and must only compute. Nothing is written when
     * the state is unchanged. Returns the state as stored and what `change`
     * returned.
     *
     * @param \Closure(JobState): array{JobState, mixed} $change
     * @return array{JobState, mixed}
     */
    private function updateState(string $job, \Closure $change): array
    {
        for ($attempt = 1; ; $attempt++) {
            $current = $this->readState($job);
            [$state, $result] = $change($current);
            if (self::sameState($state, $current)) {
                return [$current, $result];
            }
            $version = Evaluate::stateVersion($current);
            $next = clone $state;
            $next->version = $version + 1;
            if ($this->writeState($next, $version)) {
                return [$next, $result];
            }
            if ($attempt >= self::STATE_ATTEMPTS) {
                throw new \RuntimeException("the state of {$job} changed under " . self::STATE_ATTEMPTS . ' attempts in a row to update it; gave up');
            }
        }
    }

    /** A conditional write, or for a store without compareAndSetState, a plain one that always succeeds. */
    private function writeState(JobState $state, int|float $expectedVersion): bool
    {
        if ($this->store instanceof ComparesAndSetsState) {
            return $this->store->compareAndSetState($state, $expectedVersion);
        }
        $this->store->setState($state);
        return true;
    }

    /**
     * Read, change and write one job's state, in turn with every other update to it.
     *
     * @param \Closure(JobState): void $change
     */
    private function patchState(string $name, \Closure $change): JobState
    {
        $this->ensureReady();
        [$state] = $this->updateState($name, function (JobState $current) use ($name, $change): array {
            $next = Evaluate::normalizeState($current, $name);
            $change($next);
            return [$next, null];
        });
        return $state;
    }

    /**
     * Runs a function as a recorded run. The function always runs, whatever
     * the store is doing: store errors go to onError. Returns what it returns
     * and throws what it throws, after the run is recorded.
     *
     * @internal Called by JobHandle::run() and wrap().
     */
    public function execute(JobDefinition $definition, string $trigger, callable $fn): mixed
    {
        $outcome = $this->executeOutcome($definition, $trigger, $fn);
        if ($outcome->threw) {
            throw $outcome->error;
        }
        return $outcome->result;
    }

    /**
     * execute() without throwing: the run as recorded and how the function
     * ended, for a caller that answers with the run (a job's handler()).
     *
     * @internal
     */
    public function executeOutcome(JobDefinition $definition, string $trigger, callable $fn): Outcome
    {
        $key = $this->startExecution($definition, $trigger);
        $context = self::$current[count(self::$current) - 1];
        try {
            $result = $fn($context);
        } catch (\Throwable $error) {
            return new Outcome($this->endExecution($key, null, $error, true), null, $error, true);
        }
        return new Outcome($this->endExecution($key, $result, null, false), $result, null, false);
    }

    /**
     * The first half of execute(), for an integration that sees a run begin
     * and end in two calls (a scheduler's or a queue's events): the run is
     * recorded as running, and Cronwatch::current() is its context until
     * finishExecution() is called with the key returned. A process that ends
     * in between records the run as interrupted, as execute() does.
     *
     * `mayDiscard` is for a run that may turn out not to have happened (a
     * queued job released back onto the queue, a scheduled task skipped for
     * overlapping): the start's effect on the job's state (missed and stuck
     * closed) waits for the finish, which applies it just before judging the
     * run, so discardExecution() leaves the state as it was. A check while
     * the run is going sees its running row either way.
     *
     * @internal For the framework integrations.
     */
    public function startExecution(JobDefinition $definition, string $trigger, ?string $id = null, bool $mayDiscard = false): int
    {
        $name = (string) $definition->get('name');
        $startedAt = $this->now();
        $run = new Run($id ?? self::uuid(), $name, RunStatus::RUNNING, $startedAt, trigger: $trigger);
        $recorded = false;
        try {
            $this->sync($definition, true);
            $this->store->insertRun(clone $run);
            $recorded = true;
        } catch (\Throwable $error) {
            $this->report($error, "recording {$name}");
        }
        // The SDK closes missed and stuck beside the running job; here it is
        // done just before the job runs. The result is the same.
        if ($recorded && !$mayDiscard) {
            try {
                $this->updateState($name, fn (JobState $before) => [Evaluate::onRunStart($before), null]);
            } catch (\Throwable $error) {
                $this->report($error, "starting {$name}");
            }
        }
        $recorder = new RunRecorder($run, Evaluate::timeoutMs($definition));
        $key = $this->nextExecution++;
        $this->inProgress[$key] = [$definition, $run, $recorder, $recorded, $recorded && $mayDiscard];
        $this->hookShutdown();
        self::$current[] = $recorder->context;
        return $key;
    }

    /**
     * The second half: the run finished, judged and recorded, as execute()
     * records one that returned `result` or, with `threw`, threw `error` (a
     * Throwable, or a string written as it is). `output` is text the run
     * wrote elsewhere (a command's output file), added to what it logged.
     * Returns the run as judged, or null for a key already finished (or
     * never started).
     *
     * @internal For the framework integrations.
     */
    public function finishExecution(int $key, mixed $result = null, mixed $error = null, bool $threw = false, ?string $output = null): ?Run
    {
        if (!isset($this->inProgress[$key])) {
            return null;
        }
        if ($output !== null && $output !== '') {
            $this->inProgress[$key][2]->log(Js::wellFormed($output));
        }
        return $this->endExecution($key, $result, $error, $threw);
    }

    /**
     * The other end of startExecution(): the attempt neither failed nor
     * succeeded (a queued job released back onto the queue without an
     * exception, a scheduled task skipped for overlapping), so its run is
     * taken back rather than judged. The running row is deleted while it is
     * still running and of this job (a store that implements DeletesRunIf;
     * every store here does), and nothing is alerted. The job's state is
     * left as it was when the run was started with `mayDiscard` (without it,
     * the start already closed missed and stuck). A store that cannot delete
     * a run, or a row a check already marked stuck, is reported to onError
     * and left as it is. Returns whether the run was taken back.
     *
     * @internal For the framework integrations.
     */
    public function discardExecution(int $key): bool
    {
        if (!isset($this->inProgress[$key])) {
            return false;
        }
        [$definition, $run, $recorder, $recorded, $startPending] = $this->inProgress[$key];
        unset($this->inProgress[$key]);
        $at = array_search($recorder->context, self::$current, true);
        if ($at !== false) {
            array_splice(self::$current, $at, 1);
        }
        $recorder->signal->settle();
        if (!$recorded) {
            return true;
        }
        $name = (string) $definition->get('name');
        try {
            if (!$this->store instanceof DeletesRunIf) {
                throw new \LogicException('the store cannot take back a run (implement Cronwatch\\Store\\DeletesRunIf); it is left running');
            }
            if (!$this->store->deleteRunIf($run->id, $name, RunStatus::RUNNING)) {
                throw new \RuntimeException("run {$run->id} of {$name} is no longer running; left as it is");
            }
            return true;
        } catch (\Throwable $error) {
            $this->report($error, "discarding {$name}");
            return false;
        }
    }

    /** The end of one execute(): the run finished, judged and recorded. */
    private function endExecution(int $key, mixed $result, mixed $error, bool $threw): Run
    {
        [$definition, $run, $recorder, $recorded, $startPending] = $this->inProgress[$key];
        unset($this->inProgress[$key]);
        $at = array_search($recorder->context, self::$current, true);
        if ($at !== false) {
            array_splice(self::$current, $at, 1);
        }
        $recorder->signal->settle();
        $name = (string) $definition->get('name');
        $finishedAt = $this->now();
        $run->finishedAt = $finishedAt;
        $run->durationMs = Evaluate::runDuration($run->startedAt, $finishedAt);
        $run->metrics = $recorder->metrics();
        $run->output = $recorder->output() ?? (is_string($result) ? Js::wellFormed($result) : null);
        $expectText = $recorder->expectText() ?? (is_string($result) ? Js::wellFormed($result) : null);
        $this->conclude($definition, $run, $result, $error, $threw, $expectText);
        try {
            $ignored = $this->recordFinish($definition, $run, $recorded, $finishedAt, $startPending);
            if ($ignored !== null) {
                $this->report(new \RuntimeException("run {$run->id} of {$name} {$ignored}; ignored"), "finishing {$name}");
            }
        } catch (\Throwable $problem) {
            $this->report($problem, "recording {$name}");
        }
        return $run;
    }

    /**
     * A run in progress when the process ends (exit() inside a job, or a
     * fatal error such as memory running out, which no catch sees) is
     * recorded as a failed run, "Interrupted: ...", so no run is left
     * running to be reported stuck later.
     */
    private function hookShutdown(): void
    {
        if ($this->shutdownHooked) {
            return;
        }
        $this->shutdownHooked = true;
        self::$reserve ??= str_repeat(' ', 256 * 1024);
        $client = \WeakReference::create($this);
        register_shutdown_function(static function () use ($client): void {
            self::$reserve = null;
            $cw = $client->get();
            if ($cw === null || $cw->inProgress === []) {
                return;
            }
            $fatal = error_get_last();
            if ($fatal !== null && !in_array($fatal['type'], [E_ERROR, E_PARSE, E_CORE_ERROR, E_COMPILE_ERROR, E_USER_ERROR, E_RECOVERABLE_ERROR], true)) {
                $fatal = null;
            }
            if ($fatal !== null && str_starts_with($fatal['message'], 'Allowed memory size')) {
                // Room to record the run in, past the limit the job ran into.
                @ini_set('memory_limit', (string) (memory_get_usage(true) + 32 * 1024 * 1024)); // phpcs:ignore Squiz.PHP.DiscouragedFunctions.Discouraged -- the process is ending; room to record the failed run.
            }
            $describe = $fatal !== null
                ? Output::describe('Interrupted', 'Fatal error: ' . $fatal['message'], ["{$fatal['file']}:{$fatal['line']}"])
                : 'Interrupted: the process exited during the run';
            foreach (array_reverse(array_keys($cw->inProgress), true) as $key) {
                $cw->endExecution($key, null, $describe, true);
            }
        });
    }

    /**
     * Sets a finished run's status and error from how it ended, then redacts
     * its output and error and caps them, in that order. An HTTP response of
     * 400 or more that the function returned fails the run, as a fetch
     * Response does in the SDK (see Web\ResponseStatus for the kinds it reads).
     */
    private function conclude(JobDefinition $definition, Run $run, mixed $result, mixed $error, bool $threw, ?string $expectText): void
    {
        $http = $threw ? null : Web\ResponseStatus::of($result);
        if ($threw) {
            $run->status = RunStatus::FAILED;
            $run->error = Output::describeError($error);
        } elseif ($http !== null && $http[0] >= 400) {
            $run->status = RunStatus::FAILED;
            $run->error = "HTTP {$http[0]}" . ($http[1] !== '' ? " {$http[1]}" : '');
        } else {
            $unmet = Serialize::checkExpectation($definition->get('expect'), $expectText);
            if ($unmet !== null) {
                $run->status = RunStatus::FAILED;
                $run->error = $unmet;
            } else {
                $run->status = RunStatus::OK;
            }
        }
        // Redacted after the expect check, so a rule can still match what was
        // logged, and before the cap, so the cut cannot keep half a secret. NULs go
        // last, so not even a custom redact can store one.
        if ($run->output !== null) {
            $run->output = Output::redactAndCap(Js::wellFormed($run->output), $this->redact);
        }
        if ($run->error !== null) {
            $run->error = Output::redactAndCap(Js::wellFormed($run->error), $this->redact);
        }
    }

    /**
     * Writes a finished run and evaluates it. `recorded` says whether its
     * start was written; if not, it is inserted now. Returns why nothing was
     * recorded (another process finished the run first, say), or null.
     * Throws when the store does, so a handle can be finished again.
     */
    private function recordFinish(JobDefinition $definition, Run $run, bool $recorded, int|float $finishedAt, bool $startPending = false): ?string
    {
        if (!$recorded) {
            // The start was never written; the store may be back by now.
            $this->sync($definition);
            try {
                $this->store->insertRun($run);
                $this->finishRun(Serialize::toStored($definition), $run, $finishedAt, $startPending);
                return null;
            } catch (\Throwable $error) {
                // Another process may have recorded a run with this id meanwhile.
                $stored = $this->tryGetRun($run->id);
                if ($stored === null) {
                    throw $error;
                }
                if ($stored->job !== $run->job) {
                    return "belongs to job \"{$stored->job}\"";
                }
            }
        }
        [$late, $ignored] = $this->claimFinish($run);
        if ($ignored !== null) {
            return $ignored;
        }
        if (!$late || $run->status === RunStatus::OK) {
            $this->finishRun(Serialize::toStored($definition), $run, $finishedAt, $startPending);
        }
        return null;
    }

    private function tryGetRun(string $id): ?Run
    {
        try {
            return $this->store->getRun($id);
        } catch (\Throwable) {
            return null;
        }
    }

    /**
     * A conditional write (updateRunIf), or for a store without one, a read
     * then a plain write, which is safe only while one process at a time
     * finishes a given run.
     *
     * @param list<string> $fromStatuses
     */
    private function writeRunIf(Run $run, array $fromStatuses): bool
    {
        if ($this->store instanceof UpdatesRunIf) {
            return $this->store->updateRunIf($run, $fromStatuses);
        }
        $stored = $this->store->getRun($run->id);
        if ($stored === null || !in_array($stored->status, $fromStatuses, true)) {
            return false;
        }
        $this->store->updateRun($run);
        return true;
    }

    /**
     * Writes a finished run over its stored row, only while that row is still
     * running, or else still marked timeout by a check. Only the process
     * whose write lands goes on to evaluate the run. Returns [lateAfterTimeout,
     * null] once written, or [false, why] when nothing was: lateAfterTimeout
     * means a check already counted the run as a stuck failure, so a late
     * failure must not count twice while a late success still closes stuck
     * and recovers. Throws when the store does.
     *
     * @return array{bool, ?string}
     */
    private function claimFinish(Run $run): array
    {
        if ($this->writeRunIf($run, [RunStatus::RUNNING])) {
            return [false, null];
        }
        if ($this->writeRunIf($run, [RunStatus::TIMEOUT])) {
            return [true, null];
        }
        $stored = $this->store->getRun($run->id);
        return [false, $stored !== null ? "was already finished as {$stored->status}" : 'was not found'];
    }

    /** Throws for a run id no store could hold, or one reserved for the pg_cron source. */
    private static function checkRunId(string $job, string $id, string $method): void
    {
        $length = Js::length16($id);
        if ($id === '' || $length > 200) {
            throw new \InvalidArgumentException("job \"{$job}\": {$method}() needs a run id of 1 to 200 characters (got {$length} characters)");
        }
        // Postgres refuses NUL in text, so no store could hold such an id.
        if (str_contains($id, "\0")) {
            throw new \InvalidArgumentException("job \"{$job}\": {$method}() cannot take a run id containing a NUL character");
        }
        if (str_starts_with($id, self::RESERVED_RUN_ID_PREFIX)) {
            throw new \InvalidArgumentException("job \"{$job}\": {$method}() cannot take a run id starting with \"" . self::RESERVED_RUN_ID_PREFIX . '", which the pg_cron source uses for its runs');
        }
    }

    /**
     * $job->start(): records a running run and returns a handle to finish it.
     *
     * @internal Called by JobHandle::start().
     */
    public function startRun(JobDefinition $definition, ?string $trigger, ?string $id): RunHandle
    {
        $trigger ??= 'start';
        if ($id !== null) {
            self::checkRunId((string) $definition->get('name'), $id, 'start');
        }
        return $this->recordStart($definition, $trigger, $id);
    }

    /**
     * The start of a run without the function: the run is inserted and missed
     * and stuck close (onRunStart). A store that fails is reported and the
     * handle inserts the finished run instead.
     */
    private function recordStart(JobDefinition $definition, string $trigger, ?string $id): RunHandle
    {
        $name = (string) $definition->get('name');
        if ($id !== null) {
            $stored = null;
            try {
                $this->ensureReady();
                $stored = $this->store->getRun($id);
            } catch (\Throwable $error) {
                $this->report($error, "recording {$name}");
            }
            if ($stored !== null) {
                return $this->existingHandle($definition, $stored);
            }
        }
        $run = new Run($id ?? self::uuid(), $name, RunStatus::RUNNING, $this->now(), trigger: $trigger);
        $recorded = false;
        try {
            $this->sync($definition, true);
            $this->store->insertRun(clone $run);
            $recorded = true;
        } catch (\Throwable $error) {
            // Another process may have started a run with this id first.
            $again = $id === null ? null : $this->tryGetRun($id);
            if ($again !== null) {
                return $this->existingHandle($definition, $again);
            }
            $this->report($error, "recording {$name}");
        }
        if ($recorded) {
            try {
                $this->updateState($name, fn (JobState $before) => [Evaluate::onRunStart($before), null]);
            } catch (\Throwable $error) {
                $this->report($error, "starting {$name}");
            }
        }
        return new RunHandle($this, $definition, $run->id, $run, $recorded, null);
    }

    /**
     * $job->resume() and resumeRun(). A store that cannot be read is reported, and finish() reads it again.
     *
     * @internal Called by JobHandle::resume().
     */
    public function resumeHandle(JobDefinition $definition, string $runId): RunHandle
    {
        $name = (string) $definition->get('name');
        self::checkRunId($name, $runId, 'resume');
        try {
            $this->ensureReady();
            $stored = $this->store->getRun($runId);
        } catch (\Throwable $error) {
            $this->report($error, "resuming {$name}");
            return new RunHandle($this, $definition, $runId, null, true, null);
        }
        if ($stored === null) {
            return new RunHandle($this, $definition, $runId, null, true, 'was not found');
        }
        return $this->existingHandle($definition, $stored);
    }

    /** A handle on a stored run. One still running, or marked timeout by a check, can be finished. */
    private function existingHandle(JobDefinition $definition, Run $stored): RunHandle
    {
        $name = (string) $definition->get('name');
        if ($stored->job !== $name) {
            throw new \InvalidArgumentException("run \"{$stored->id}\" belongs to job \"{$stored->job}\", not \"{$name}\"");
        }
        $finished = in_array($stored->status, [RunStatus::OK, RunStatus::FAILED], true);
        return new RunHandle($this, $definition, $stored->id, $stored, true, $finished ? "already finished as {$stored->status}" : null);
    }

    /**
     * A finish that records nothing, reported rather than thrown.
     *
     * @internal Called by RunHandle.
     */
    public function ignoreFinish(string $runId, string $name, string $why): void
    {
        $this->report(new \RuntimeException("run {$runId} of {$name} {$why}; ignored"), "finishing {$name}");
    }

    /**
     * RunHandle::finish(): the stored run, read again, with the handle's lines
     * and metrics added, judged like any run. Returns the run as recorded, or
     * null when nothing was. A store that fails is reported and throws
     * RetryFinish, which leaves the handle active to be finished again.
     *
     * @internal Called by RunHandle.
     */
    public function finishHandle(RunHandle $handle, RunRecorder $recorder, bool $failed, mixed $result, mixed $error, ?string $head): ?Run
    {
        $definition = $handle->definition;
        $name = $handle->job;
        $source = $handle->base;
        if ($handle->recorded) {
            try {
                $source = $this->store->getRun($handle->id) ?? $handle->base;
            } catch (\Throwable $problem) {
                $this->report($problem, "finishing {$name}");
                throw new RetryFinish('', 0, $problem);
            }
        }
        if ($source === null) {
            $this->ignoreFinish($handle->id, $name, 'was not found');
            return null;
        }
        if ($source->job !== $name) {
            $this->ignoreFinish($handle->id, $name, "belongs to job \"{$source->job}\"");
            return null;
        }
        if (in_array($source->status, [RunStatus::OK, RunStatus::FAILED], true)) {
            $this->ignoreFinish($handle->id, $name, "was already finished as {$source->status}");
            return null;
        }
        $finishedAt = $this->now();
        $added = $recorder->output() ?? (is_string($result) ? Js::wellFormed($result) : null);
        $run = clone $source;
        $run->status = RunStatus::RUNNING;
        $run->finishedAt = $finishedAt;
        $run->durationMs = Evaluate::runDuration($source->startedAt, $finishedAt);
        $run->error = null;
        // Capped by conclude(), after it is redacted.
        $run->output = self::joinLines($source->output, $added);
        $run->metrics = array_replace($source->metrics, $recorder->metrics());
        $seen = $recorder->expectText() ?? (is_string($result) ? Js::wellFormed($result) : null);
        $expectText = self::joinLines($head, self::joinLines($source->output, $seen));
        $this->conclude($definition, $run, $result, $error, $failed, $expectText);
        try {
            $why = $this->recordFinish($definition, $run, $handle->recorded, $finishedAt);
        } catch (\Throwable $problem) {
            $this->report($problem, "finishing {$name}");
            throw new RetryFinish('', 0, $problem);
        }
        if ($why !== null) {
            $this->ignoreFinish($handle->id, $name, $why);
            return null;
        }
        return $run;
    }

    /**
     * RunHandle::flush(): appends lines and metrics to the stored run while it
     * is still running and belongs to this job, written only over a row still
     * running, so a flush never undoes a finish. True once written; false when
     * the handle should keep them for finish().
     *
     * @internal Called by RunHandle.
     * @param array<string, int|float> $metrics
     */
    public function flushHandle(RunHandle $handle, ?string $lines, array $metrics): bool
    {
        $name = $handle->job;
        try {
            $stored = $this->store->getRun($handle->id);
            // Not running: the lines stay in the handle for finish, which reports why it cannot record them.
            if ($stored === null || $stored->status !== RunStatus::RUNNING) {
                return false;
            }
            if ($stored->job !== $name) {
                $this->report(new \RuntimeException("run {$handle->id} of {$name} belongs to job \"{$stored->job}\"; ignored"), "flushing {$name}");
                return false;
            }
            $updated = clone $stored;
            if ($lines !== null) {
                $updated->output = self::joinOutput($stored->output, Output::redactAndCap(Js::wellFormed($lines), $this->redact));
            }
            $updated->metrics = array_replace($stored->metrics, $metrics);
            return $this->writeRunIf($updated, [RunStatus::RUNNING]);
        } catch (\Throwable $error) {
            $this->report($error, "flushing {$name}");
            return false;
        }
    }

    /**
     * recordRun() for a run already stored.
     *
     * @return list<Alert>
     */
    private function recordOver(JobDefinition $definition, Run $stored, Run $run, bool $evaluate): array
    {
        if ($stored->job !== $run->job) {
            $this->report(new \RuntimeException("run {$run->id} of {$run->job} belongs to job \"{$stored->job}\"; ignored"), "recording {$run->job}");
            return [];
        }
        if (!in_array($stored->status, [RunStatus::RUNNING, RunStatus::TIMEOUT], true) || $run->status === RunStatus::RUNNING) {
            return [];
        }
        [$late, $ignored] = $this->claimFinish($run);
        if ($ignored !== null) {
            $this->report(new \RuntimeException("run {$run->id} of {$run->job} {$ignored}; ignored"), "recording {$run->job}");
            return [];
        }
        if (!$evaluate || ($late && $run->status !== RunStatus::OK)) {
            return [];
        }
        return $this->finishRun($definition, $run, $this->now());
    }

    /**
     * Evaluate a finished run (ok, failed, or timed out by a check), already
     * written, against the job's state and send what that produces. The
     * alerts are written with that state (see outbox()). Never throws.
     *
     * @return list<Alert>
     */
    private function finishRun(JobDefinition $definition, Run $run, int|float $at, bool $startPending = false): array
    {
        $history = null;
        try {
            [, $held] = $this->updateState($run->job, function (JobState $previous) use ($definition, $run, $at, $startPending, &$history): array {
                $history ??= $this->history($run);
                $started = $startPending ? Evaluate::onRunStart($previous) : $previous;
                $settled = Evaluate::applySilence($previous, Evaluate::onRunFinish($definition, $run, $started, $history, $at), $at);
                return $this->outbox($settled, $definition, $at);
            });
        } catch (\Throwable $error) {
            $this->report($error, "evaluating {$run->job}");
            return [];
        }
        $this->reportDropped($run->job, $held['dropped']);
        return $this->dispatch($run->job, $held['alerts'], $at);
    }

    /**
     * An evaluation as it is written: its drafts composed into alerts and
     * held in the same state (Evaluate::holdAlerts), so the write that opens
     * a condition also keeps its alerts, and a process that stops before
     * sending them does not lose them. Called inside updateState(), so it
     * only computes.
     *
     * @return array{JobState, array{alerts: list<Alert>, dropped: int}}
     */
    private function outbox(Evaluation $settled, JobDefinition $definition, int|float $at): array
    {
        $alerts = array_map(fn (AlertDraft $draft) => Format::composeAlert($draft, $definition, $at), $settled->alerts);
        $held = Evaluate::holdAlerts($settled->state, $alerts, $this->now() + Evaluate::SEND_LEASE_MS, $this->deferDelivery);
        return [$held['state'], ['alerts' => $alerts, 'dropped' => $held['dropped']]];
    }

    /** Reports alerts let go because a job's queue was full. */
    private function reportDropped(string $name, int $dropped): void
    {
        if ($dropped <= 0) {
            return;
        }
        $this->report(
            new \RuntimeException("{$dropped} undelivered alert" . ($dropped === 1 ? '' : 's') . " for {$name} dropped: only the newest " . self::MAX_UNDELIVERED . ' are kept for retry'),
            "alert queue for {$name}",
        );
    }

    /**
     * The runs before `run`, newest first, with up to BASELINE_WINDOW
     * successful ones when the store has them. One small read normally; a
     * larger one only when failures crowd the successes out of it.
     *
     * @return list<Run>
     */
    private function history(Run $run): array
    {
        $others = fn (array $runs) => array_values(array_filter($runs, fn (Run $r) => $r->id !== $run->id));
        $runs = $this->store->listRuns($run->job, self::HISTORY_PAGE);
        if (count($runs) === self::HISTORY_PAGE && !Evaluate::hasFullBaseline($others($runs))) {
            $runs = $this->store->listRuns($run->job, self::HISTORY_MAX);
        }
        return $others($runs);
    }

    private function runCheck(): CheckResult
    {
        $this->ensureReady();
        $alerts = [];
        // Sources first, so what they record is evaluated in this check.
        foreach ($this->sources as $source) {
            try {
                array_push($alerts, ...array_values($source->sync($this)));
            } catch (\Throwable $error) {
                $this->report($error, "source {$source->name()}");
            }
        }
        foreach ($this->definitions as $definition) {
            $this->sync($definition);
        }
        $at = $this->now();

        // Runs that never reported back. One that cannot be judged (its job's
        // stored timeout no longer parses, say) is reported and skipped.
        foreach ($this->store->runningRuns() as $listed) {
            try {
                $declared = $this->definitions[$listed->job] ?? null;
                $judged = $declared !== null ? Serialize::toStored($declared) : $this->store->getJob($listed->job)?->definition;
                if ($judged === null || !Evaluate::isStuck($judged, $listed, $at)) {
                    continue;
                }
                // Read again just before the write: lines and metrics flushed since the
                // list was read (while earlier stuck runs were sent, say) are kept.
                $run = $this->store->getRun($listed->id);
                if ($run === null || $run->status !== RunStatus::RUNNING || $run->job !== $listed->job) {
                    continue;
                }
                $timeout = Evaluate::timeoutMs($judged);
                $run->status = RunStatus::TIMEOUT;
                $run->finishedAt = $at;
                $run->durationMs = Evaluate::runDuration($run->startedAt, $at);
                $run->error = 'Still running after ' . Duration::format($timeout) . '; marked as timed out';
                // Only over a row still running: a finish that landed meanwhile wins.
                if (!$this->writeRunIf($run, [RunStatus::RUNNING])) {
                    continue;
                }
                array_push($alerts, ...$this->finishRun($judged, $run, $at));
            } catch (\Throwable $error) {
                $this->report($error, "checking {$listed->job}");
            }
        }

        // Each job on its own: one that cannot be evaluated is reported, shown
        // as failing (see Evaluate::unevaluableSummary) and does not stop the others.
        $jobs = [];
        $spent = 0.0;
        foreach ($this->writtenJobs() as $stored) {
            try {
                $recent = $this->store->listRuns($stored->name, Evaluate::BASELINE_WINDOW);
                $nextExpectedAt = null;
                [$state, $held] = $this->updateState($stored->name, function (JobState $previous) use ($stored, $recent, $at, &$nextExpectedAt): array {
                    $evaluation = Evaluate::onCheck($stored->definition, $stored, $recent[0] ?? null, $previous, $at);
                    $nextExpectedAt = $evaluation->nextExpectedAt;
                    $settled = Evaluate::applySilence($previous, $evaluation, $at);
                    // Alerts a process stopped sending part way go back to the retry queue.
                    $released = Evaluate::releaseSending($settled->state, $this->now());
                    [$next, $out] = $this->outbox(new Evaluation($released['state'], $settled->alerts), $stored->definition, $at);
                    return [$next, ['alerts' => $out['alerts'], 'dropped' => $released['dropped'] + $out['dropped']]];
                });
                $this->reportDropped($stored->name, $held['dropped']);
                array_push($alerts, ...$this->retryUndelivered($stored->name, $state, $at, $spent));
                array_push($alerts, ...$this->dispatch($stored->name, $held['alerts'], $at));
                $jobs[] = Evaluate::summarize($stored, $recent, $state, $nextExpectedAt, $at);
            } catch (\Throwable $error) {
                $this->report($error, "checking {$stored->name}");
                $jobs[] = $this->unevaluable($stored, $at);
            }
        }

        $pruned = 0;
        if ($at - $this->lastPruneAt > self::PRUNE_INTERVAL_MS) {
            $this->lastPruneAt = $at;
            try {
                $pruned = $this->store->prune($at - $this->retentionMs);
            } catch (\Throwable $error) {
                $this->report($error, 'pruning');
            }
        }
        return new CheckResult($at, $jobs, $alerts, $pruned);
    }

    /** A job's summary and its newest runs, without alerting. A job that cannot be evaluated is reported and shown as failing. */
    private function snapshot(StoredJob $stored, int|float $at, int $count): JobWithRuns
    {
        $recent = [];
        try {
            $recent = $this->store->listRuns($stored->name, max($count, Evaluate::BASELINE_WINDOW));
            $state = $this->readState($stored->name);
            $nextExpectedAt = Evaluate::onCheck($stored->definition, $stored, $recent[0] ?? null, $state, $at)->nextExpectedAt;
            return new JobWithRuns(Evaluate::summarize($stored, $recent, $state, $nextExpectedAt, $at), array_slice($recent, 0, $count));
        } catch (\Throwable $error) {
            $this->report($error, "reading {$stored->name}");
            return new JobWithRuns($this->unevaluable($stored, $at), array_slice($recent, 0, $count));
        }
    }

    /** The summary of a job whose evaluation failed, from whatever can still be read. */
    private function unevaluable(StoredJob $stored, int|float $at): JobSummary
    {
        try {
            $recent = $this->store->listRuns($stored->name, Evaluate::BASELINE_WINDOW);
        } catch (\Throwable) {
            $recent = [];
        }
        try {
            $state = $this->readState($stored->name);
        } catch (\Throwable) {
            $state = Evaluate::emptyState($stored->name);
        }
        return Evaluate::unevaluableSummary($stored, $recent, $state, $at);
    }

    /**
     * Triage and send each alert the outbox holds (see outbox()). The state,
     * with the alerts in it, was saved before this, so afterwards only the
     * delivery fields are written back, onto a fresh read of the state, and
     * the alerts leave `sending`. Triage is made here, never stored with the
     * held alert: the write that opens a condition cannot wait for it, and a
     * retry triages an alert that has none. With deliver: "check" the alerts
     * were queued for a check elsewhere instead.
     *
     * @param list<Alert> $alerts
     * @return list<Alert>
     */
    private function dispatch(string $name, array $alerts, int|float $at): array
    {
        if ($alerts === [] || $this->deferDelivery) {
            return $alerts;
        }
        self::holdOn();
        $delivered = [];
        $failed = [];
        foreach ($alerts as $alert) {
            if ($this->triage !== null && $alert->type !== AlertType::RECOVERED) {
                $this->addTriage($alert, self::TRIAGE_TIMEOUT_MS);
            }
            if ($this->deliver($alert)) {
                $delivered[] = $alert;
            } else {
                $failed[] = $alert;
            }
        }
        $this->recordDelivery($name, $delivered, $failed, [], $at);
        return $alerts;
    }

    /**
     * Alerts are about to go out, one channel after another (triage up to 25
     * seconds, each channel up to 10), perhaps from a web request (a handler,
     * the dashboard's check, WordPress's wp-cron.php). They are saved in the
     * state already, so a request cut short now (max_execution_time, the
     * caller hanging up) leaves them to a check once their lease runs out,
     * five minutes on. Outside the command line the request is kept going, so
     * they go out now: a caller that hangs up no longer stops it, and a time
     * limit is moved on to leave two minutes for delivery.
     */
    private static function holdOn(): void
    {
        if (\PHP_SAPI === 'cli') {
            return;
        }
        ignore_user_abort(true);
        $limit = (int) ini_get('max_execution_time');
        if ($limit > 0 && function_exists('set_time_limit')) {
            set_time_limit(max($limit, 120)); // phpcs:ignore Squiz.PHP.DiscouragedFunctions.Discouraged -- alerts must not be lost to the request's time limit.
        }
    }

    /**
     * Send the alerts that no channel accepted last time, once each, oldest
     * first. An alert that no longer describes the job (Evaluate::staleAlert)
     * is dropped instead. Retries across a check share RETRY_BUDGET_MS of
     * wall-clock time; once it is spent the rest stay queued for the next check.
     *
     * @return list<Alert>
     */
    private function retryUndelivered(string $name, JobState $state, int|float $at, float &$spent): array
    {
        $pending = $state->undelivered ?? [];
        if ($pending === [] || Evaluate::isSilenced($state, $at) || $this->deferDelivery) {
            return [];
        }
        self::holdOn();
        $delivered = [];
        $failed = [];
        $dropped = array_values(array_filter($pending, fn (Alert $alert) => Evaluate::staleAlert($alert, $state)));
        foreach ($pending as $alert) {
            if (in_array($alert, $dropped, true)) {
                continue;
            }
            $left = self::RETRY_BUDGET_MS - $spent;
            if ($left <= 0) {
                break;
            }
            $started = ($this->wall)();
            // An alert queued by a process that delivers at check time was never
            // triaged. One that was tried (triage: null) is not tried again.
            if ($this->triage !== null && $alert->type !== AlertType::RECOVERED && !$alert->triageTried) {
                $this->addTriage($alert, min(self::TRIAGE_TIMEOUT_MS, $left));
            }
            if ($this->deliver($alert)) {
                $delivered[] = $alert;
            } else {
                $failed[] = $alert;
            }
            $spent += max(0.0, ($this->wall)() - $started);
        }
        $this->recordDelivery($name, $delivered, $failed, $dropped, $at);
        return $delivered;
    }

    /**
     * Mark delivered alerts done, drop stale ones, and keep failed ones for
     * the next check, taking them all out of `sending`
     * (Evaluate::recordSent). A failed alert replaces its stored copy, so a
     * triage made on this attempt is kept. lastAlertAt moves only on a
     * delivery. When this write fails, alerts still in `sending` are retried
     * once their lease runs out.
     *
     * @param list<Alert> $delivered
     * @param list<Alert> $failed
     * @param list<Alert> $dropped
     */
    private function recordDelivery(string $name, array $delivered, array $failed, array $dropped, int|float $at): void
    {
        try {
            [, $trimmed] = $this->updateState($name, function (JobState $previous) use ($name, $delivered, $failed, $dropped, $at): array {
                $sent = Evaluate::recordSent(Evaluate::normalizeState($previous, $name), $delivered, $failed, $dropped, $at);
                return [$sent['state'], $sent['dropped']];
            });
            $this->reportDropped($name, $trimmed);
        } catch (\Throwable $error) {
            $this->report($error, "recording alert delivery for {$name}");
        }
    }

    /** Send to every channel, one after another. True when at least one accepted it, or there are none. */
    private function deliver(Alert $alert): bool
    {
        if ($this->alerts === []) {
            return true;
        }
        $any = false;
        foreach ($this->alerts as $channel) {
            $name = $channel->name();
            try {
                $channel->send($alert, new ChannelContext(fn (\Throwable $error) => $this->report($error, "alert channel {$name}")));
                $any = true;
            } catch (\Throwable $error) {
                $this->report($error, "alert channel {$name}");
            }
        }
        return $any;
    }

    /**
     * Sets the alert's triage to the diagnosis, or to null (JSON null) when
     * there is none (it threw, or answered null or ""), so it is tried once
     * per alert. The signal it is given aborts after `timeout`; PHP cannot
     * stop the call itself, so a triage function passes what is left to its
     * request as a timeout.
     */
    private function addTriage(Alert $alert, int|float $timeout): void
    {
        $signal = new AbortSignal($timeout);
        try {
            $recent = $this->store->listRuns($alert->job, 5);
            $diagnosis = ($this->triage)(new TriageContext($alert, $recent, $signal));
            $alert->setTriage(is_string($diagnosis) && $diagnosis !== '' ? Js::wellFormed($diagnosis) : null);
        } catch (\Throwable $error) {
            $signal->abort();
            $alert->setTriage(null);
            $this->report($error, "triage for {$alert->job}");
        } finally {
            $signal->settle();
        }
    }

    /** Two stretches of text as one, a line apart; either may be null. */
    private static function joinLines(?string $before, ?string $after): ?string
    {
        if ($before === null || $before === '') {
            return $after;
        }
        if ($after === null) {
            return $before;
        }
        return "{$before}\n{$after}";
    }

    /** Output appended to stored output, capped like any run's. */
    private static function joinOutput(?string $before, ?string $after): ?string
    {
        $joined = self::joinLines($before, $after);
        return $joined === null ? null : Output::capOutput($joined);
    }

    /** A whole number in range, or the fallback for anything that is not a number. */
    private static function clampLimit(mixed $limit, int $fallback, int $min): int
    {
        $n = Js::isFinite($limit) ? (int) $limit : $fallback;
        return min(500, max($min, $n));
    }

    /** A random (version 4) UUID, as crypto.randomUUID() makes. */
    private static function uuid(): string
    {
        $bytes = random_bytes(16);
        $bytes[6] = chr((ord($bytes[6]) & 0x0F) | 0x40);
        $bytes[8] = chr((ord($bytes[8]) & 0x3F) | 0x80);
        return vsprintf('%s%s-%s-%s-%s-%s%s%s', str_split(bin2hex($bytes), 4));
    }
}
