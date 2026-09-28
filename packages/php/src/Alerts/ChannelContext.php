<?php

declare(strict_types=1);

namespace Cronwatch\Alerts;

/** What the client hands a channel with each alert. */
final class ChannelContext
{
    /** @param \Closure(\Throwable): void $report */
    public function __construct(private readonly \Closure $report)
    {
    }

    /**
     * Report a problem that did not stop the alert going out, such as one of
     * several recipients refusing it. Goes to the client's onError.
     */
    public function onError(\Throwable $error): void
    {
        ($this->report)($error);
    }
}
