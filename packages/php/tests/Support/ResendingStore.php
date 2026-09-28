<?php

declare(strict_types=1);

namespace Cronwatch\Tests\Support;

use Cronwatch\JobState;
use Cronwatch\Store\PdoStore;
use Cronwatch\Store\Sql;

/**
 * A SQL store (SQLite in memory, through PdoStore) whose connection breaks
 * just after the server committed a write and before its answer came back,
 * as MySQL's error 2013 and a dropped Postgres socket can: the statements
 * named in $breakAfter are run, then sent again, as MysqlStore and
 * PostgresStore send one again on a new connection.
 */
final class ResendingStore extends PdoStore
{
    /** @var list<string> statement keys (casUpdate, casInsert, updateRunIf, deleteRunIf) that break once after landing */
    public array $breakAfter = [];
    public int $resends = 0;

    public function __construct()
    {
        parent::__construct(Sql::DEFAULT_PREFIX, 'sqlite', new \PDO('sqlite::memory:', null, null, [\PDO::ATTR_ERRMODE => \PDO::ERRMODE_EXCEPTION]), true);
    }

    protected function open(): \PDO
    {
        return $this->db ?? throw new \LogicException('closed');
    }

    protected function run(string $text, array $params = []): \PDOStatement
    {
        foreach ($this->breakAfter as $i => $key) {
            $sql = match ($key) {
                'updateRunIf' => Sql::updateRunIfSql($this->prefix, 1),
                'deleteRunIf' => Sql::deleteRunIfSql($this->prefix),
                default => $this->sql[$key],
            };
            if ($sql === $text) {
                unset($this->breakAfter[$i]);
                parent::run($text, $params);
                $this->resent = true;
                $this->resends++;
                break;
            }
        }
        return parent::run($text, $params);
    }

    public function init(): void
    {
        $this->open()->exec(Sql::sqliteSchema($this->prefix));
    }

    public function compareAndSetState(JobState $state, int|float $expectedVersion): bool
    {
        $this->resent = false;
        $statement = $expectedVersion == 0
            ? $this->run($this->sql['casInsert'], Sql::stateParams($state))
            : $this->run($this->sql['casUpdate'], Sql::casUpdateParams($state, $expectedVersion));
        return $statement->rowCount() > 0 || $this->stateLanded($state);
    }
}
