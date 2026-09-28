<?php

declare(strict_types=1);

namespace Cronwatch\Job;

/** Thrown by AbortSignal::throwIfAborted() once the signal has aborted. */
final class AbortError extends \RuntimeException
{
}
