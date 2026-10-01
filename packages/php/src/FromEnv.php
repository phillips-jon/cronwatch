<?php

declare(strict_types=1);

namespace Cronwatch;

/**
 * The default of the client's cronSecret and the dashboard's token: read the
 * value from the environment (CRON_SECRET, CRONWATCH_TOKEN). Leaving the
 * argument out does the same; pass it to say so, or from a wrapper that
 * passes every argument on. null turns the secret or the token off, as it
 * does in every other language.
 *
 *     new Cronwatch(cronSecret: FromEnv::Read);   // CRON_SECRET, the default
 *     new Cronwatch(cronSecret: null);            // no secret, on purpose
 */
enum FromEnv
{
    case Read;
}
