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
abstract class PdoStore implements Store, UpdatesRunIf, ComparesAndSetsState
{
    public readonly string $prefix;
    /** @var array<string, string> */
    protected array $sql;
    /** @var array<string, \PDOStatement> Each statement is prepared once per open connection. */
    private array $prepared = [];

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
            Sql::bind($statement, $params);
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
        $this->run($this->sql['insertRun'], Sql::insertRunParams($run));
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
        $statement = $this->run(Sql::updateRunIfSql($this->prefix, count($fromStatuses)), Sql::updateRunIfParams($run, $fromStatuses));
        if ($statement->rowCount() > 0) {
            return true;
        }
        // MySQL counts only the rows an UPDATE changed, so a row that already
        // held these values (and matched) answers 0: it was written all the same.
        $stored = $this->getRun($run->id);
        return $stored !== null && in_array($stored->status, $fromStatuses, true)
            && Js::stringify(Sql::updateRunParams($stored)) === Js::stringify(Sql::updateRunParams($run));
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
