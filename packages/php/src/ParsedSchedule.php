<?php

declare(strict_types=1);

namespace Cronwatch;

use Cronwatch\Cron\Cron;

/**
 * A schedule as Schedule::parse() reads it: a cron expression, or an interval.
 *
 * @internal
 */
final class ParsedSchedule
{
    public const CRON = 'cron';
    public const INTERVAL = 'interval';

    /**
     * @param string $kind "cron" or "interval"
     * @param string|null $timezone the IANA timezone a cron is read in, when one was given
     * @param int|float|null $everyMs for an interval, the period in milliseconds
     */
    public function __construct(
        public readonly string $kind,
        public readonly string $source,
        public readonly ?string $timezone = null,
        public readonly int|float|null $everyMs = null,
        /** @internal */
        public readonly ?Cron $cron = null,
    ) {
    }

    public function isCron(): bool
    {
        return $this->kind === self::CRON;
    }

    public function isInterval(): bool
    {
        return $this->kind === self::INTERVAL;
    }

    /** The SDK's JSON shape. */
    public function toJson(): array
    {
        $out = ['kind' => $this->kind, 'source' => $this->source];
        if ($this->timezone !== null && $this->timezone !== '') {
            $out['timezone'] = $this->timezone;
        }
        if ($this->everyMs !== null) {
            $out['everyMs'] = $this->everyMs;
        }
        return $out;
    }
}
