<?php

declare(strict_types=1);

/**
 * Posts once through NativeHttp without curl and prints "<status> <body>",
 * or the error, for ChannelsTest's TLS case: run with -d openssl.cafile=<the
 * test's own CA>, which can only be set when PHP starts.
 *
 *     php -d openssl.cafile=ca.pem post.php <url>
 */

use Cronwatch\Alerts\NativeHttp;

require __DIR__ . '/../bootstrap.php';

try {
    $response = (new NativeHttp(false))->post($argv[1], '{}', ['content-type' => 'application/json'], 5000);
    echo "{$response->status} {$response->body}";
} catch (Throwable $error) {
    echo get_class($error) . ': ' . $error->getMessage();
}
