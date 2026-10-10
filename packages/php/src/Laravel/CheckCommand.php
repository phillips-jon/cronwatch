<?php

declare(strict_types=1);

namespace Cronwatch\Laravel;

use Illuminate\Console\Command;

/**
 * `php artisan cronwatch:check`: declares every scheduled task (and
 * declares tasks no longer scheduled again without their schedule), runs a
 * check, and prints the line every port prints, `cronwatch: checked 3 jobs,
 * sent 1 alert` (nothing with --quiet). Anything that goes wrong is one
 * line on standard error and exit status 1. The service provider schedules
 * it every five minutes; a crontab line can run it too.
 */
final class CheckCommand extends Command
{
    /** @var string */
    protected $signature = 'cronwatch:check';

    /** @var string */
    protected $description = 'Look for missed, failed, stuck, and slow jobs and send alerts';

    public function handle(ScheduledTasks $tasks): int
    {
        try {
            $result = $tasks->prepare()->check();
        } catch (\Throwable $error) {
            // One line on standard error, as every port's check command writes it.
            $this->getOutput()->getErrorStyle()->writeln('cronwatch: ' . $error->getMessage());
            return self::FAILURE;
        }
        $this->line($result->summary());
        return self::SUCCESS;
    }
}
