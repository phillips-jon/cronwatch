<?php

declare(strict_types=1);

namespace Cronwatch;

/**
 * A regular expression for `expect`: a successful run's output must match
 * it. A plain string is always a substring to look for, so a pattern is
 * marked by this class: `'expect' => new Pattern('/wrote \d+ files/i')`. It
 * is stored and shown as JavaScript writes a RegExp, "/source/flags", so a
 * definition written by PHP reads the same as one written by Node.
 */
final class Pattern implements \Stringable
{
    /** JavaScript's flags, in the order RegExp#flags lists them. */
    private const JS_FLAGS = 'dgimsuvy';

    public readonly string $source;
    public readonly string $flags;

    /** @param string $pattern a PCRE pattern with its delimiters, as preg_match takes it */
    public function __construct(public readonly string $pattern)
    {
        set_error_handler(static fn () => true); // phpcs:ignore WordPress.PHP.DevelopmentFunctions.error_log_set_error_handler -- keeps an invalid pattern's warning quiet while it is tested; restored below.
        try {
            $valid = preg_match($pattern, '') !== false;
        } finally {
            restore_error_handler();
        }
        if (!$valid || strlen($pattern) < 2) {
            throw new \InvalidArgumentException("expect pattern {$pattern} is not a valid PCRE pattern: " . preg_last_error_msg());
        }
        $open = $pattern[0];
        $close = ['(' => ')', '[' => ']', '{' => '}', '<' => '>'][$open] ?? $open;
        $end = strrpos($pattern, $close);
        $source = substr($pattern, 1, $end - 1);
        $modifiers = substr($pattern, $end + 1);
        if ($open !== '/') {
            // Escaped as RegExp#source escapes it: a "/" not already escaped.
            $source = preg_replace('/(?<!\\\\)((?:\\\\\\\\)*)\//', '$1\\/', $source) ?? $source;
        }
        $this->source = $source === '' ? '(?:)' : str_replace(["\n", "\r"], ['\\n', '\\r'], $source);
        $this->flags = implode('', array_filter(str_split(self::JS_FLAGS), fn (string $f) => str_contains($modifiers, $f) && $f !== 'u'));
    }

    /** From a JavaScript RegExp's source and flags. */
    public static function fromJs(string $source, string $flags = ''): self
    {
        $pcre = implode('', array_filter(str_split($flags), fn (string $f) => str_contains('ims', $f)));
        return new self('/' . str_replace('/', '\\/', str_replace('\\/', '/', $source)) . '/' . $pcre . 'u');
    }

    public function matches(string $text): bool
    {
        return preg_match($this->pattern, $text) === 1;
    }

    /** As RegExp#toString: /source/flags. */
    public function __toString(): string
    {
        return "/{$this->source}/{$this->flags}";
    }

    /** As JSON.stringify writes a RegExp: an empty object. */
    public function toJson(): \stdClass
    {
        return new \stdClass();
    }
}
