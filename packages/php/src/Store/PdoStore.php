<?php

declare(strict_types=1);

namespace Cronwatch\Store;

use Cronwatch\JobDefinition;
use Cronwatch\JobState;
use Cronwatch\Js;
use Cronwatch\Run;
use Cronwatch\StoredJob;

/**
 * What the SQL stores share: the statements of Sql, prepared once per
 * connection, bound with their types, and the rows read back as the SDK
 * reads them.
 *
 * @internal
 */
abstract class PdoStore implements Store, UpdatesRunIf, ComparesAndSetsState, DeletesRunIf
{
    public readonly string $prefix;
    /** @var array<string, string> */
    protected array $sql;
    /** @var array<string, \PDOStatement> Each statement is prepared once per open connection. */
    private array $prepared = [];
    /** Set by a store that sent a statement again on a new connection after the old one broke: its first send may have landed. */
    protected bool $resent = false;

    protected function __construct(string $prefix, string $dialect, protected ?\PDO $db, protected readonly bool $own)
    {
        $this->prefix = Sql::tablePrefix($prefix);
        $this->sql = Sql::statements($dialect, $this->prefix);
    }

    /** The connection, opened on first use. */
    abstract protected function open(): \PDO;

    /** Runs a statement with its parameters bound by type. */
    protected function run(string $text, array $params = []): \PDOStatement
    {
        $db = $this->open();
        $statement = $this->prepared[$text] ??= $db->prepare($text);
        try {
            self::bind($statement, $params);
            $statement->execute();
        } catch (\Throwable $error) {
            // A statement that failed part way (SQLite's busy answer leaves it
            // unreset, so the next bind would be refused) is prepared afresh.
            unset($this->prepared[$text]);
            try {
                $statement->closeCursor();
            } catch (\Throwable) {
            }
            throw $error;
        }
        return $statement;
    }

    /**
     * Binds each value with the type it has: an int (or a float with no
     * fraction) as an integer, null as NULL. It lives here, not in Sql, so
     * Sql (which the WordPress plugin's $wpdb store shares) names no PDO.
     */
    public static function bind(\PDOStatement $statement, array $params): void
    {
        foreach (array_values($params) as $i => $value) {
            if (is_float($value) && Js::isInteger($value) && abs($value) <= Js::MAX_SAFE_INTEGER) {
                $value = (int) $value;
            }
            $type = match (true) {
                $value === null => \PDO::PARAM_NULL,
                is_int($value) => \PDO::PARAM_INT,
                is_bool($value) => \PDO::PARAM_BOOL,
                default => \PDO::PARAM_STR,
            };
            $statement->bindValue($i + 1, is_float($value) ? Js::number($value) : $value, $type);
        }
    }

    /** @return list<array<string, mixed>> */
    protected function all(string $text, array $params = []): array
    {
        $statement = $this->run($text, $params);
        $rows = $statement->fetchAll(\PDO::FETCH_ASSOC);
        $statement->closeCursor();
        return $rows;
    }

    /** @return array<string, mixed>|null */
    protected function one(string $text, array $params = []): ?array
    {
        $statement = $this->run($text, $params);
        $row = $statement->fetch(\PDO::FETCH_ASSOC);
        $statement->closeCursor();
        return $row === false ? null : $row;
    }

    /** Forgets the connection's prepared statements, for a connection closed or opened again. */
    protected function forgetStatements(): void
    {
        $this->prepared = [];
    }

    public function upsertJob(JobDefinition $definition, int|float $now): void
    {
        $this->run($this->sql['upsertJob'], Sql::upsertJobParams($definition, $now));
    }

    public function getJob(string $name): ?StoredJob
    {
        $row = $this->one($this->sql['getJob'], [$name]);
        return $row === null ? null : Sql::rowToJob($row);
    }

    public function listJobs(): array
    {
        return array_map(Sql::rowToJob(...), $this->all($this->sql['listJobs']));
    }

    /** One transaction, or a part of the caller's when their connection already has one open. */
    public function deleteJob(string $name): void
    {
        $db = $this->open();
        $own = !$db->inTransaction();
        if ($own) {
            $db->beginTransaction();
        }
        try {
            $this->run($this->sql['deleteRuns'], [$name]);
            $this->run($this->sql['deleteState'], [$name]);
            $this->run($this->sql['deleteJob'], [$name]);
            if ($own) {
                $db->commit();
            }
        } catch (\Throwable $error) {
            if ($own && $db->inTransaction()) {
                $db->rollBack();
            }
            throw $error;
        }
    }

    public function insertRun(Run $run): void
    {
        $this->resent = false;
        try {
            $this->run($this->sql['insertRun'], Sql::insertRunParams($run));
        } catch (\PDOException $error) {
            // Sent again after the connection broke, it finds the row its
            // first send wrote before the break: that row is this one, not
            // another process's, so the insert went through.
            if ($this->resent) {
                $stored = $this->getRun($run->id);
                if ($stored !== null && self::canonical(Sql::insertRunParams($stored)) === self::canonical(Sql::insertRunParams($run))) {
                    return;
                }
            }
            throw $error;
        }
    }

    public function updateRun(Run $run): void
    {
        $this->run($this->sql['updateRun'], Sql::updateRunParams($run));
    }

    public function updateRunIf(Run $run, array $fromStatuses): bool
    {
        if ($fromStatuses === []) {
            return false;
        }
        $this->resent = false;
        $statement = $this->run(Sql::updateRunIfSql($this->prefix, count($fromStatuses)), Sql::updateRunIfParams($run, $fromStatuses));
        if ($statement->rowCount() > 0) {
            return true;
        }
        // MySQL counts only the rows an UPDATE changed, so a row that already
        // held these values (and matched) answers 0: it was written all the same.
        // And a statement sent again after the connection broke finds its own
        // first send's write, which landed before the break.
        $stored = $this->getRun($run->id);
        return $stored !== null && (in_array($stored->status, $fromStatuses, true) || $this->resent)
            && self::canonical(Sql::updateRunParams($stored)) === self::canonical(Sql::updateRunParams($run));
    }

    public function deleteRunIf(string $id, string $job, string $status): bool
    {
        $this->resent = false;
        return $this->run(Sql::deleteRunIfSql($this->prefix), [$id, $job, $status])->rowCount() > 0
            || ($this->resent && $this->getRun($id) === null);
    }

    /**
     * After a conditional state write that answered "not written": whether it
     * was sent again after the connection broke and its first send had in fact
     * landed (the stored state is the one written). Without this a lost answer
     * would read as another process having written first, and the job's
     * update would be worked out and applied twice.
     */
    protected function stateLanded(JobState $state): bool
    {
        if (!$this->resent) {
            return false;
        }
        $stored = $this->getState($state->job);
        return $stored !== null && self::canonical(Js::stringify($stored)) === self::canonical(Js::stringify($state));
    }

    /** Values compared whatever order a JSON column (Postgres's JSONB) gave an object's keys back in. */
    private static function canonical(mixed $value): string
    {
        $sort = function (mixed $v) use (&$sort): mixed {
            if (is_string($v) && ($v === '' || $v[0] === '{' || $v[0] === '[')) {
                $decoded = json_decode($v, true);
                $v = json_last_error() === JSON_ERROR_NONE && is_array($decoded) ? ['json' => $decoded] : $v;
            }
            if (is_array($v)) {
                if (!array_is_list($v)) {
                    ksort($v, SORT_STRING);
                }
                return array_map($sort, $v);
            }
            return $v;
        };
        return (string) json_encode($sort($value), JSON_PARTIAL_OUTPUT_ON_ERROR);
    }

    public function getRun(string $id): ?Run
    {
        $row = $this->one($this->sql['getRun'], [$id]);
        return $row === null ? null : Sql::rowToRun($row);
    }

    public function listRuns(string $job, int $limit): array
    {
        return array_map(Sql::rowToRun(...), $this->all($this->sql['listRuns'], [$job, max(0, $limit)]));
    }

    public function lastRun(string $job): ?Run
    {
        $row = $this->one($this->sql['listRuns'], [$job, 1]);
        return $row === null ? null : Sql::rowToRun($row);
    }

    public function runningRuns(): array
    {
        return array_map(Sql::rowToRun(...), $this->all($this->sql['runningRuns']));
    }

    public function getState(string $job): ?JobState
    {
        $row = $this->one($this->sql['getState'], [$job]);
        return $row === null ? null : Sql::rowToState($row);
    }

    public function setState(JobState $state): void
    {
        $this->run($this->sql['setState'], Sql::stateParams($state));
    }

    public function prune(int|float $before): int
    {
        return $this->run($this->sql['prune'], [$before])->rowCount();
    }

    public function close(): void
    {
        $this->forgetStatements();
        if ($this->own) {
            $this->db = null;
        }
    }
}
