<?php

declare(strict_types=1);

namespace Cronwatch;

/**
 * Stored definitions and expect rules (serialize.ts).
 *
 * @internal
 */
final class Serialize
{
    private const DURATIONS = ['grace', 'timeout', 'maxDuration'];

    /**
     * A definition as a store can hold it: `expect` becomes a description and
     * moves to the end, as it does in the SDK. A DateInterval is stored as the
     * milliseconds it means, the unit every reader takes a plain number in.
     */
    public static function toStored(JobDefinition $def): JobDefinition
    {
        $fields = $def->fields;
        foreach (self::DURATIONS as $key) {
            if (($fields[$key] ?? null) instanceof \DateInterval) {
                $fields[$key] = Duration::parse($fields[$key], $key);
            }
        }
        $expect = $fields['expect'] ?? null;
        unset($fields['expect']);
        if ($expect !== null) {
            $fields['expect'] = match (true) {
                is_string($expect) => 'contains ' . Js::quote($expect),
                $expect instanceof Pattern => "matches {$expect}",
                default => 'custom function',
            };
        }
        return new JobDefinition($fields);
    }

    /** Null when the output satisfies `expect`, or why it does not. */
    public static function checkExpectation(mixed $expect, ?string $output): ?string
    {
        if ($expect === null) {
            return null;
        }
        $text = $output ?? '';
        if (is_string($expect)) {
            return str_contains($text, $expect) ? null : 'Output did not contain ' . Js::quote($expect);
        }
        if ($expect instanceof Pattern) {
            if ($expect->matches($text)) {
                return null;
            }
            // PCRE gave up (its backtrack limit, say) rather than finding no match: say so.
            $why = preg_last_error() !== PREG_NO_ERROR ? ' (' . preg_last_error_msg() . ')' : '';
            return "Output did not match {$expect}{$why}";
        }
        try {
            $ok = $expect($text);
        } catch (\Throwable $error) {
            // The rule is the app's code; its failure is the run's.
            return 'Output check threw: ' . Js::wellFormed($error->getMessage());
        }
        return self::truthy($ok) ? null : 'Output did not pass the expect() check';
    }

    /** JavaScript's truthiness, since the SDK tests the rule's answer with `ok ? ... : ...`. */
    private static function truthy(mixed $value): bool
    {
        return !($value === false || $value === null || $value === 0 || $value === '' || (is_float($value) && ($value == 0.0 || is_nan($value))));
    }
}
