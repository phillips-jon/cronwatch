<?php

declare(strict_types=1);

namespace Cronwatch\Cron;

/**
 * What the schedule uses of croner's Cron: an expression that schedules
 * nothing and only answers nextRuns.
 *
 * @internal
 */
final class Cron
{
    public readonly CronPattern $pattern;
    public readonly ?string $timezone;

    public function __construct(string $text, ?string $timezone = null)
    {
        if ($text !== '' && str_contains(substr($text, 1), ':')) {
            // Croner reads a string with a colon after its first character as a
            // one-time date to fire at, not as a cron expression.
            if (preg_match('/^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}/', $text) === 1) {
                throw new CronError('CronPattern: a one-time date is not supported');
            }
            throw new CronError('Invalid ISO8601 passed to timezone parser.');
        }
        $this->timezone = $timezone === null || $timezone === '' ? null : Zone::canonical($timezone) ?? $timezone;
        $this->pattern = new CronPattern($text);
    }

    /**
     * Up to `count` fires after `start` (epoch ms), each found from the one before, as nextRuns.
     *
     * @return list<int>
     */
    public function nextRuns(int $count, int $start): array
    {
        $runs = [];
        $previous = CronDate::fromMs($start, $this->timezone);
        for ($i = 0; $i < $count; $i++) {
            $found = (clone $previous)->increment($this->pattern);
            if ($found === null) {
                break;
            }
            $runs[] = $found->timeMs();
            $previous = $found;
        }
        return $runs;
    }
}
