<?php

declare(strict_types=1);

namespace Cronwatch\Symfony;

/**
 * Asks for a check. Its handler (CheckMessageHandler) declares every
 * scheduled message and runs one. The bundle's own schedule, "cronwatch",
 * sends it every five minutes; an app that would rather keep it in its own
 * schedule turns that off and adds it:
 *
 *     ->add(RecurringMessage::every('5 minutes', new CheckMessage()))
 *
 * It is never a job itself.
 */
final class CheckMessage
{
}
