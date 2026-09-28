<?php

declare(strict_types=1);

namespace Cronwatch\Alerts;

use Cronwatch\Js;

/**
 * AWS Signature Version 4, for the SES channel (alerts/sigv4.ts).
 * Spec: https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_sigv-create-signed-request.html
 * Checked against the AWS SigV4 test suite (tests/ChannelsTest.php).
 *
 * @internal
 */
final class SigV4
{
    /**
     * The headers to send: the given ones (names lowercased) plus
     * x-amz-date, the session token when there is one, and authorization.
     * Host is signed but not returned, because the HTTP client sets it.
     *
     * @param array<string, string> $headers
     * @return array<string, string>
     */
    public static function sign(
        string $method,
        string $url,
        array $headers,
        string $body,
        string $region,
        string $service,
        int|float $now,
        string $accessKeyId,
        string $secretAccessKey,
        ?string $sessionToken = null,
    ): array {
        $parts = Shared::url($url) ?? throw new \InvalidArgumentException('SigV4 needs an absolute URL');
        $amzDate = (string) preg_replace(['/[-:]/', '/\.[0-9]{3}/'], '', Js::iso($now));
        $day = substr($amzDate, 0, 8);
        $out = [];
        foreach ($headers as $name => $value) {
            $out[strtolower((string) $name)] = $value;
        }
        $out['x-amz-date'] = $amzDate;
        if ($sessionToken !== null && $sessionToken !== '') {
            $out['x-amz-security-token'] = $sessionToken;
        }

        $signed = [...$out, 'host' => $parts['host']];
        $names = array_keys($signed);
        sort($names, SORT_STRING);
        $canonicalHeaders = '';
        foreach ($names as $name) {
            $canonicalHeaders .= $name . ':' . preg_replace('/[' . Js::WHITESPACE . ']+/u', ' ', Js::trim($signed[$name])) . "\n";
        }
        $signedHeaders = implode(';', $names);
        $canonicalRequest = implode("\n", [
            strtoupper($method),
            self::canonicalUri($parts['pathname']),
            self::canonicalQuery($parts['search']),
            $canonicalHeaders,
            $signedHeaders,
            hash('sha256', $body),
        ]);
        $scope = "{$day}/{$region}/{$service}/aws4_request";
        $stringToSign = implode("\n", ['AWS4-HMAC-SHA256', $amzDate, $scope, hash('sha256', $canonicalRequest)]);

        $key = hash_hmac('sha256', $day, "AWS4{$secretAccessKey}", true);
        $key = hash_hmac('sha256', $region, $key, true);
        $key = hash_hmac('sha256', $service, $key, true);
        $key = hash_hmac('sha256', 'aws4_request', $key, true);
        $signature = hash_hmac('sha256', $stringToSign, $key);

        $out['authorization'] = "AWS4-HMAC-SHA256 Credential={$accessKeyId}/{$scope}, SignedHeaders={$signedHeaders}, Signature={$signature}";
        return $out;
    }

    /** RFC 3986 encoding of every byte but the unreserved characters. */
    private static function uriEncode(string $text): string
    {
        return rawurlencode($text);
    }

    private static function canonicalUri(string $path): string
    {
        if ($path === '') {
            return '/';
        }
        // The path is already encoded once; every AWS service but S3 expects each segment encoded again.
        return implode('/', array_map(self::uriEncode(...), explode('/', $path)));
    }

    /** The query's pairs as URLSearchParams reads them, each encoded, sorted by name then value. */
    private static function canonicalQuery(string $search): string
    {
        $query = ltrim($search, '?');
        if ($query === '') {
            return '';
        }
        $pairs = [];
        foreach (explode('&', $query) as $piece) {
            if ($piece === '') {
                continue;
            }
            [$name, $value] = array_pad(explode('=', $piece, 2), 2, '');
            $decode = fn (string $s) => urldecode($s);
            $pairs[] = [self::uriEncode($decode($name)), self::uriEncode($decode($value))];
        }
        usort($pairs, fn (array $a, array $b) => [$a[0], $a[1]] <=> [$b[0], $b[1]]);
        return implode('&', array_map(fn (array $p) => "{$p[0]}={$p[1]}", $pairs));
    }
}
