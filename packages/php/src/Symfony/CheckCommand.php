<?php

declare(strict_types=1);

namespace Cronwatch\Symfony;

use Symfony\Component\Console\Attribute\AsCommand;
use Symfony\Component\Console\Command\Command;
use Symfony\Component\Console\Input\InputInterface;
use Symfony\Component\Console\Input\InputOption;
use Symfony\Component\Console\Output\OutputInterface;

/**
 * `bin/console cronwatch:check`: declares every scheduled message (and
 * declares messages no longer scheduled again without their schedule),
 * runs a check, and prints the line every port prints, `cronwatch: checked
 * 3 jobs, sent 1 alert` (nothing with --quiet). Anything that goes wrong is
 * one line on standard error and exit status 1. The bundle puts the check
 * in the app's "default" schedule, so the worker that runs the app's
 * scheduled messages (messenger:consume scheduler_default) runs it every
 * five minutes; with check.schedule: false, run this from a crontab.
 *
 * `--status` checks nothing: it says where the check is scheduled and which
 * transport a worker must consume for it to run, and lists the schedules
 * and their watched messages.
 */
#[AsCommand(name: 'cronwatch:check', description: 'Look for missed, failed, stuck, and slow jobs and send alerts')]
final class CheckCommand extends Command
{
    /**
     * @param string|false|null $schedule the schedule the bundle put the check in, false for none, null without the Scheduler and Messenger
     */
    public function __construct(
        private readonly CheckMessageHandler $check,
        private readonly string|false|null $schedule = null,
        private readonly string $frequency = '5 minutes',
        private readonly ?ScheduledMessages $scheduled = null,
    ) {
        parent::__construct('cronwatch:check');
    }

    protected function configure(): void
    {
        $this->setDescription('Look for missed, failed, stuck, and slow jobs and send alerts');
        $this->addOption('status', null, InputOption::VALUE_NONE, 'Say where the check is scheduled and what a worker must consume, without checking');
    }

    protected function execute(InputInterface $input, OutputInterface $output): int
    {
        if ($input->getOption('status')) {
            foreach ($this->status() as $line) {
                $output->writeln($line, OutputInterface::OUTPUT_RAW);
            }
            return Command::SUCCESS;
        }
        try {
            $result = ($this->check)(new CheckMessage());
        } catch (\Throwable $error) {
            $stderr = method_exists($output, 'getErrorOutput') ? $output->getErrorOutput() : $output;
            $stderr->writeln('cronwatch: ' . $error->getMessage());
            return Command::FAILURE;
        }
        $output->writeln($result->summary());
        return Command::SUCCESS;
    }

    /** @return list<string> */
    public function status(): array
    {
        $status = $this->scheduled?->status() ?? ['schedules' => [], 'check' => []];
        $lines = [];
        if ($this->schedule === null) {
            $lines[] = 'cronwatch: the check is not scheduled (the bundle schedules it when symfony/scheduler and symfony/messenger are installed): run bin/console cronwatch:check every five minutes from a crontab';
        } elseif ($this->schedule === false && $status['check'] === []) {
            $lines[] = 'cronwatch: the check is not scheduled (check.schedule: false): run bin/console cronwatch:check every five minutes from a crontab, or add RecurringMessage::every(\'5 minutes\', new Cronwatch\Symfony\CheckMessage()) to a schedule';
        } else {
            $in = $status['check'] !== [] ? $status['check'] : [(string) $this->schedule];
            $how = $this->schedule !== false && in_array($this->schedule, $in, true) ? " every {$this->frequency}" : '';
            $lines[] = 'cronwatch: the check runs' . $how . ' in the ' . self::names($in) . ' schedule' . (count($in) === 1 ? '' : 's')
                . ', only while a worker consumes it: bin/console messenger:consume ' . implode(' ', array_map(fn ($s) => "scheduler_{$s}", $in));
        }
        foreach ($status['schedules'] as $name => $count) {
            $lines[] = "cronwatch: schedule \"{$name}\" (scheduler_{$name}): {$count} " . ($count === 1 ? 'message' : 'messages') . ' watched' . (in_array($name, $status['check'], true) ? ', and the check' : '');
        }
        return $lines;
    }

    /** @param list<string> $names */
    private static function names(array $names): string
    {
        $quoted = array_map(fn ($n) => "\"{$n}\"", $names);
        return count($quoted) < 2 ? implode('', $quoted) : implode(', ', array_slice($quoted, 0, -1)) . ' and ' . end($quoted);
    }
}
