<?php

declare(strict_types=1);

namespace Cronwatch\Alerts;

use Cronwatch\Alert;
use Cronwatch\AlertType;

/**
 * Writes alerts to standard error from the command line, or to PHP's error
 * log elsewhere (a web request has no terminal). The default channel.
 */
final class Console implements AlertChannel
{
    public function name(): string
    {
        return 'console';
    }

    public function send(Alert $alert, ChannelContext $context): void
    {
        $line = "[cronwatch] {$alert->title}\n{$alert->message}" . ($alert->triage !== null && $alert->triage !== '' ? "\nTriage: {$alert->triage}" : '');
        self::write($line, $alert->type === AlertType::RECOVERED);
    }

    /** A line to standard error (or standard output, for good news) on the command line, else to the error log. */
    public static function write(string $line, bool $good = false): void
    {
        if (PHP_SAPI === 'cli' && defined('STDERR')) {
            fwrite($good ? STDOUT : STDERR, $line . "\n"); // phpcs:ignore WordPress.WP.AlternativeFunctions.file_system_operations_fwrite -- standard error on the command line, not a file.
            return;
        }
        error_log($line); // phpcs:ignore WordPress.PHP.DevelopmentFunctions.error_log_error_log -- the default channel: an alert with nowhere else to go is logged, not debug output.
    }
}
