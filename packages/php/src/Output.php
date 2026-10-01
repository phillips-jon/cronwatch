<?php

declare(strict_types=1);

namespace Cronwatch;

/**
 * The output cap, error messages, and secret redaction (output.ts).
 *
 * Lengths are counted in UTF-16 code units and the redaction patterns match
 * exactly what the SDK's JavaScript patterns match: ASCII-only case folding
 * and word boundaries, JavaScript's whitespace class spelled out, and text
 * outside the Basic Multilingual Plane matched as two code units a character.
 */
final class Output
{
    /** Output is capped so a chatty job cannot fill the store. The tail is kept. */
    public const OUTPUT_CAP = 16 * 1024;

    public const REDACTED = '[redacted]';

    /**
     * Removes every U+0000.
     *
     * @internal
     */
    public static function stripNul(string $text): string
    {
        return str_contains($text, "\0") ? str_replace("\0", '', $text) : $text;
    }

    /**
     * Removes every U+0000 from JSON text, keys and strings alike, by
     * dropping each \u0000 escape (a NUL can appear in JSON no other way).
     * Escapes are read left to right in pairs, so an escaped backslash
     * followed by "u0000" is left as it is.
     *
     * @internal
     */
    public static function stripJsonNul(string $json): string
    {
        if (!str_contains($json, '\\u0000')) {
            return $json;
        }
        return (string) preg_replace_callback('/\\\\(u0000|[\s\S])/', fn (array $m) => $m[1] === 'u0000' ? '' : $m[0], $json);
    }

    /**
     * NUL characters are removed first, since Postgres refuses them in TEXT
     * and JSONB and the whole run row would be lost. The cap then applies to
     * what is left.
     *
     * @internal
     */
    public static function capOutput(string $text): string
    {
        $clean = self::stripNul($text);
        if (strlen($clean) <= self::OUTPUT_CAP || Js::length16($clean) <= self::OUTPUT_CAP) {
            return $clean;
        }
        return self::TRIMMED . Js::tail16($clean, self::OUTPUT_CAP);
    }

    private const TRIMMED = "[earlier output trimmed]\n";

    /**
     * How much text before the kept tail redaction reads, and never keeps:
     * three times the longest secret a default pattern can match (a PEM key's
     * 16 KB body with its header and footer, under OUTPUT_CAP + 1024), since
     * a replacement grows what it replaces at most threefold.
     */
    public const REDACT_EDGE = 3 * (self::OUTPUT_CAP + 1024);

    /**
     * Output or an error as it is stored: redacted, then capped like
     * capOutput, so the cut cannot fall inside a secret and keep what follows
     * its label. Text of at most OUTPUT_CAP + REDACT_EDGE UTF-16 units is
     * redacted whole. Longer text is cut to that many units from its end
     * first, and after redacting, the first REDACT_EDGE units are never kept:
     * a secret whose label fell before that cut is left out with them. NULs
     * go before and after `redact`.
     *
     * @param \Closure(string): string $redact
     *
     * @internal
     */
    public static function redactAndCap(string $text, \Closure $redact): string
    {
        $clean = self::stripNul($text);
        $window = self::OUTPUT_CAP + self::REDACT_EDGE;
        if (strlen($clean) <= $window || Js::length16($clean) <= $window) {
            return self::capOutput($redact($clean));
        }
        $redacted = self::stripNul($redact(Js::tail16($clean, $window)));
        return self::TRIMMED . Js::tail16($redacted, min(self::OUTPUT_CAP, Js::length16($redacted) - self::REDACT_EDGE));
    }

    /**
     * "Name: message" and the first five stack frames, capped like output.
     *
     * @internal
     */
    public static function errorMessage(mixed $error): string
    {
        return self::capOutput(self::describeError($error));
    }

    /**
     * An error as text, before the cap: a Throwable as "Name: message" and its frames, a string as it is, anything else as JSON.
     *
     * @internal
     */
    public static function describeError(mixed $error): string
    {
        if ($error instanceof \Throwable) {
            return self::describe(self::errorName($error), Js::wellFormed($error->getMessage()), self::frames($error));
        }
        if (is_string($error)) {
            return Js::wellFormed($error);
        }
        try {
            return Js::stringify($error);
        } catch (\Throwable) {
            return Js::string($error);
        }
    }

    /**
     * "Name: message", then up to five frames, each "    at <frame>", as a
     * JavaScript stack reads.
     *
     * @param list<string> $frames
     *
     * @internal
     */
    public static function describe(string $name, string $message, array $frames): string
    {
        $lines = array_map(fn (string $frame) => "    at {$frame}", array_slice($frames, 0, 5));
        return "{$name}: {$message}" . ($lines === [] ? '' : "\n" . implode("\n", $lines));
    }

    /**
     * The class's own name, without its namespace, as a JavaScript error's name has none.
     *
     * @internal
     */
    public static function errorName(\Throwable $error): string
    {
        $class = get_class($error);
        $cut = strrpos($class, '\\');
        return $cut === false ? $class : substr($class, $cut + 1);
    }

    /**
     * The innermost frames first, as a JavaScript stack lists them: where it
     * was thrown, then each caller, "function (file:line)".
     *
     * @return list<string>
     *
     * @internal
     */
    public static function frames(\Throwable $error): array
    {
        $trace = $error->getTrace();
        $frames = [];
        $file = $error->getFile();
        $line = $error->getLine();
        for ($i = 0; $i <= count($trace) && count($frames) < 5; $i++) {
            $call = $trace[$i] ?? null;
            $function = $call === null ? '{main}' : ($call['class'] ?? '') . ($call['type'] ?? '') . $call['function'];
            $frames[] = $file === '' ? $function : "{$function} ({$file}:{$line})";
            if ($call === null) {
                break;
            }
            $file = $call['file'] ?? '';
            $line = $call['line'] ?? 0;
        }
        return $frames;
    }

    /** @var list<array{string, \Closure(array<int, string>): string}>|null */
    private static ?array $patterns = null;

    /**
     * The SDK's patterns, as PCRE patterns in UTF mode that match what
     * JavaScript's match. JavaScript's \s is spelled out, \b is spelled with
     * ASCII word characters, and case-insensitive words are spelled
     * [Ss][Ee]... (ASCII-only folding, as JavaScript's /i has it here), since
     * PHP's /u makes \s, \b and /i Unicode-aware.
     *
     * @return list<array{string, \Closure(array<int, string>): string}>
     */
    private static function patterns(): array
    {
        if (self::$patterns !== null) {
            return self::$patterns;
        }
        $ws = Js::WHITESPACE;
        $word = 'A-Za-z0-9_';
        // \b, in general, and before a word character.
        $b = "(?:(?<=[{$word}])(?![{$word}])|(?<![{$word}])(?=[{$word}]))";
        $bw = "(?<![{$word}])";
        $ci = fn (string $text) => implode('', array_map(
            fn (string $c) => preg_match('/[a-z]/i', $c) === 1 ? '[' . strtoupper($c) . strtolower($c) . ']' : preg_quote($c, '/'),
            str_split($text),
        ));
        $names = implode('|', [
            $ci('secret'),
            $ci('token'),
            $ci('passw') . '(?:' . $ci('or') . ')?' . $ci('d'),
            $ci('pwd'),
            $ci('api') . '[_-]?' . $ci('key'),
            $ci('access') . '[_-]?' . $ci('key'),
            $ci('private') . '[_-]?' . $ci('key'),
            $ci('credential'),
        ]);
        $assign = '(?:=>|[=:])';
        $whole = fn (array $m): string => self::REDACTED;
        $keepFirst = fn (array $m): string => ($m[1] ?? '') . self::REDACTED;
        $keepQuoted = function (array $m): string {
            $quote = ($m[2] ?? '') !== '' ? $m[2] : ($m[3] ?? '');
            return $m[1] . $quote . self::REDACTED . $quote;
        };
        $keepUrl = fn (array $m): string => $m[1] . self::REDACTED . '@';

        // Bounded quantifiers throughout, so a long line cannot make these backtrack.
        // They apply in this order, each to the text the ones before it left.
        return self::$patterns = [
            // (A PEM private key comes first: see redactPrivateKeys().)
            // password=..., API_KEY: ..., "client_secret": "...", TOKEN='...', token=...,
            // :password=>"..." (but not max_tokens: 800). A quoted value is blanked to
            // its closing quote, spaces and all, and keeps its quotes.
            [
                "/{$b}([A-Za-z0-9_-]{0,40}(?:{$names})[A-Za-z0-9_-]{0,40}(?<![Tt][Oo][Kk][Ee][Nn][Ss])\"?[{$ws}]{0,3}{$assign}[{$ws}]{0,3})"
                . "(?:(\")[^\"\\n]{1,4096}\"|(')[^'\\n]{1,4096}'|[\"']?[^{$ws}\"',;&]{1,4096})/u",
                $keepQuoted,
            ],
            // Authorization: Basic <base64> and Authorization: Token <token>, also as a JSON or hash entry.
            [
                "/{$bw}((?:" . $ci('proxy-') . ')?' . $ci('authorization') . "[\"']?[{$ws}]{0,3}{$assign}[{$ws}]{0,3}[\"']?[{$ws}]{0,3}"
                . '(?:' . $ci('basic') . '|' . $ci('token') . ")[{$ws}]{1,3})[A-Za-z0-9._~+\\/=:-]{1,4096}/u",
                $keepFirst,
            ],
            // Credentials inside a URL: postgres://user:password@host. The password
            // runs to the last "@" before a "/" or a space, so one that contains "@"
            // is blanked whole.
            ["/({$bw}[A-Za-z][A-Za-z0-9+.-]{0,30}:\\/\\/[^{$ws}\\/:@]{0,256}:)[^{$ws}\\/]{1,256}@/u", $keepUrl],
            // Authorization: Bearer <token>
            ["/({$bw}Bearer[{$ws}]{1,3})[A-Za-z0-9._~+\\/=-]{8,4096}/u", $keepFirst],
            // A bare JWT: three base64url segments, the first starting eyJ.
            ["/{$bw}eyJ[A-Za-z0-9_-]{4,4096}\\.[A-Za-z0-9_-]{4,4096}\\.[A-Za-z0-9_-]{0,4096}/u", $whole],
            // Incoming webhook URLs carry their secret in the path.
            [
                "/({$bw}" . $ci('hooks.slack.com') . '\\/(?:' . $ci('services') . '|' . $ci('workflows') . '|' . $ci('triggers') . ')\\/)[A-Za-z0-9\\/_-]{1,255}/u',
                $keepFirst,
            ],
            [
                "/({$bw}" . $ci('discord') . '(?:' . $ci('app') . ')?' . $ci('.com') . '\\/' . $ci('api') . '\\/(?:[Vv][0-9]{1,2}\\/)?' . $ci('webhooks') . '\\/)[A-Za-z0-9\\/_-]{1,255}/u',
                $keepFirst,
            ],
            // Well-known token shapes: AWS, GitHub, Slack, Stripe, Anthropic, OpenAI and Google style keys.
            ["/{$bw}(?:AKIA|ASIA)[0-9A-Z]{16}(?![{$word}])/u", $whole],
            ["/{$bw}(?:gh[pousr]_[A-Za-z0-9]{30,255}|github_pat_[A-Za-z0-9_]{20,255})(?![{$word}])/u", $whole],
            ["/{$bw}xox[abposr]-[A-Za-z0-9-]{10,255}/u", $whole],
            ["/{$bw}[rsp]k_(?:live|test)_[A-Za-z0-9]{10,255}(?![{$word}])/u", $whole],
            ["/{$bw}whsec_[A-Za-z0-9+\\/=]{16,255}/u", $whole],
            ["/{$bw}sk-[A-Za-z0-9_-]{20,255}/u", $whole],
            ["/{$bw}AIza[0-9A-Za-z_-]{35}(?![0-9A-Za-z_-])/u", $whole],
        ];
    }

    /**
     * The default `redact`: blanks values that look like secrets (key=value
     * pairs with secret-ish names, Authorization headers, URL credentials,
     * bearer tokens, JWTs, PEM private keys, webhook URLs and well-known token
     * formats) before output or an error is stored, shown or sent anywhere.
     * Matches exactly what the SDK's redactSecrets matches.
     */
    public static function redactSecrets(string $text): string
    {
        $text = Js::wellFormed($text);
        $astral = preg_match('/[\xF0-\xF4]/', $text) === 1;
        $out = self::redactPrivateKeys($astral ? self::toUnits($text) : $text);
        foreach (self::patterns() as [$pattern, $replace]) {
            $next = preg_replace_callback($pattern, $replace, $out);
            if ($next === null) {
                throw new \RuntimeException('redaction failed: ' . preg_last_error_msg());
            }
            $out = $next;
        }
        return $astral ? self::fromUnits($out) : $out;
    }

    /**
     * The first of the SDK's patterns, a PEM private key from header to footer:
     *
     *   -----BEGIN (?:[A-Z0-9]{1,20} ){0,3}PRIVATE KEY-----(?:[A-Za-z0-9+/=\s,:]|-(?!----)){0,16384}
     *   (?:-----END (?:[A-Z0-9]{1,20} ){0,3}PRIVATE KEY-----)?
     *
     * Without a footer (the output was trimmed) it runs to the end of the
     * base64 body. A "-" that starts five dashes ends the body, so the footer
     * is never swallowed into it. PCRE writes a bounded group out once per
     * repeat, and sixteen thousand copies are too large to compile, so the
     * body is measured here instead: the longest run of body characters and
     * dashes the bound allows, cut at the first "-----". That is where the
     * greedy group stops, and since the footer is optional, JavaScript never
     * backtracks into the body.
     */
    private static function redactPrivateKeys(string $text): string
    {
        if (!str_contains($text, '-----BEGIN ')) {
            return $text;
        }
        $ws = Js::WHITESPACE;
        $out = '';
        $pos = 0;
        while (preg_match('/-----BEGIN (?:[A-Z0-9]{1,20} ){0,3}PRIVATE KEY-----/', $text, $header, PREG_OFFSET_CAPTURE, $pos) === 1) {
            $start = $header[0][1];
            $bodyAt = $start + strlen($header[0][0]);
            preg_match("/\\G[A-Za-z0-9+\\/={$ws},:-]{0,16384}/u", $text, $body, 0, $bodyAt);
            $length = strlen($body[0] ?? '');
            $dashes = strpos($text, '-----', $bodyAt);
            if ($dashes !== false && $dashes < $bodyAt + $length) {
                $length = $dashes - $bodyAt;
            }
            $end = $bodyAt + $length;
            if (preg_match('/\G-----END (?:[A-Z0-9]{1,20} ){0,3}PRIVATE KEY-----/', $text, $footer, 0, $end) === 1) {
                $end += strlen($footer[0]);
            }
            $out .= substr($text, $pos, $start - $pos) . self::REDACTED;
            $pos = $end;
        }
        return $out . substr($text, $pos);
    }

    /**
     * Each character outside the BMP written as two placeholder characters,
     * one for each of its UTF-16 surrogates, as JavaScript's patterns (no u
     * flag) see it: two characters to a negated class and to a bounded
     * quantifier. The placeholders are in plane 15 (U+F0000 to U+F07FF);
     * every character outside the BMP has been replaced, so any character
     * there afterwards is one of them.
     */
    private static function toUnits(string $text): string
    {
        return preg_replace_callback('/[\x{10000}-\x{10FFFF}]/u', function (array $m): string {
            $code = self::codePoint($m[0]) - 0x10000;
            return self::chr(0xF0000 + ($code >> 10)) . self::chr(0xF0400 + ($code & 0x3FF));
        }, $text) ?? $text;
    }

    /** The placeholders put back together; one a replacement cut from its partner becomes U+FFFD, as a lone surrogate does once written out as UTF-8. */
    private static function fromUnits(string $text): string
    {
        return preg_replace_callback('/[\x{F0000}-\x{F03FF}][\x{F0400}-\x{F07FF}]|[\x{F0000}-\x{F07FF}]/u', function (array $m): string {
            if (strlen($m[0]) === 4) {
                return "\u{FFFD}";
            }
            $high = self::codePoint(substr($m[0], 0, 4)) - 0xF0000;
            $low = self::codePoint(substr($m[0], 4)) - 0xF0400;
            return self::chr(0x10000 + ($high << 10) + $low);
        }, $text) ?? $text;
    }

    private static function codePoint(string $char): int
    {
        return ((ord($char[0]) & 0x07) << 18) | ((ord($char[1]) & 0x3F) << 12) | ((ord($char[2]) & 0x3F) << 6) | (ord($char[3]) & 0x3F);
    }

    private static function chr(int $code): string
    {
        return chr(0xF0 | ($code >> 18)) . chr(0x80 | (($code >> 12) & 0x3F)) . chr(0x80 | (($code >> 6) & 0x3F)) . chr(0x80 | ($code & 0x3F));
    }
}
