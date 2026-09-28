<?php

declare(strict_types=1);

namespace Cronwatch\Symfony;

use Symfony\Component\Console\Attribute\AsCommand;
use Symfony\Component\Console\Command\Command;
use Symfony\Component\Console\Input\InputInterface;
use Symfony\Component\Console\Output\OutputInterface;

/**
 * `bin/console cronwatch:check`: declares every scheduled message (and
 * declares messages no longer scheduled again without their schedule),
 * runs a check, and prints the line every port prints, `cronwatch: checked
 * 3 jobs, sent 1 alert` (nothing with --quiet). Anything that goes wrong is
 * one line on standard error and exit status 1. Run it every five minutes:
 * from the bundle's own schedule (messenger:consume scheduler_cronwatch),
 * your schedule (RecurringMessage::every('5 minutes', new CheckMessage())),
 * or a crontab line.
 */
#[AsCommand(name: 'cronwatch:check', description: 'Look for missed, failed, stuck and slow jobs and send alerts')]
final class CheckCommand extends Command
{
    public function __construct(private readonly CheckMessageHandler $check)
    {
        parent::__construct('cronwatch:check');
    }

    protected function configure(): void
    {
        $this->setDescription('Look for missed, failed, stuck and slow jobs and send alerts');
    }

    protected function execute(InputInterface $input, OutputInterface $output): int
    {
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
}
