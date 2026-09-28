<?php

declare(strict_types=1);

namespace Cronwatch\Alerts;

/** The request took longer than its deadline. fetch's message for it. */
final class RequestTimeout extends \RuntimeException
{
    public function __construct(string $message = 'The operation was aborted due to timeout')
    {
        parent::__construct($message);
    }
}
