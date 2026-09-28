<?php

declare(strict_types=1);

namespace Cronwatch\Laravel;

/**
 * Marks a queued job whose every attempt CronWatch records as a run, as
 * #[Cronwatch\Watch] does. The job's options come from the attribute when
 * the class has one too, and from a static cronwatch() method when it
 * defines one:
 *
 *     final class SendNightlyReport implements ShouldQueue, ShouldBeWatched
 *     {
 *         public static function cronwatch(): array
 *         {
 *             return ['name' => 'nightly-report', 'grace' => '15m', 'failuresBeforeAlert' => 3];
 *         }
 *     }
 */
interface ShouldBeWatched
{
}
