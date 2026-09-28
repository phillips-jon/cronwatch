<?php

declare(strict_types=1);

namespace Cronwatch\Sources;

/**
 * PgCron's queries through a pdo_pgsql PDO. The SQL is the SDK's, with $1,
 * $2 placeholders; PDO takes ? (and, preparing natively, numbers them $1,
 * $2 again for the server), so they are rewritten in the order they appear.
 * An array is bound as a Postgres array literal ("{1,2,3}"), which the
 * statements cast (::bigint[]).
 *
 * @internal
 */
final class PgCronPdo
{
    public function __construct(private readonly \PDO $pdo)
    {
    }

    /**
     * @param list<mixed> $params
     * @return list<array<string, mixed>>
     */
    public function query(string $sql, array $params): array
    {
        $order = [];
        $text = (string) preg_replace_callback('/\$([0-9]+)/', function (array $m) use (&$order): string {
            $order[] = (int) $m[1] - 1;
            return '?';
        }, $sql);
        $statement = $this->pdo->prepare($text);
        foreach ($order as $i => $index) {
            $value = $params[$index] ?? null;
            if (is_array($value)) {
                $statement->bindValue($i + 1, '{' . implode(',', array_map(fn ($v) => (string) (int) $v, $value)) . '}', \PDO::PARAM_STR);
            } elseif (is_int($value)) {
                $statement->bindValue($i + 1, $value, \PDO::PARAM_INT);
            } else {
                $statement->bindValue($i + 1, $value === null ? null : (string) $value, $value === null ? \PDO::PARAM_NULL : \PDO::PARAM_STR);
            }
        }
        $statement->execute();
        $rows = $statement->fetchAll(\PDO::FETCH_ASSOC);
        $statement->closeCursor();
        return $rows;
    }
}
