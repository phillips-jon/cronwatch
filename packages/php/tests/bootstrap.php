<?php

declare(strict_types=1);

// The conformance fixtures are generated with TZ=UTC; a cron without a
// timezone is read in PHP's default zone, so the tests fix it.
date_default_timezone_set('UTC');
error_reporting(E_ALL);

require __DIR__ . '/../vendor/autoload.php';
