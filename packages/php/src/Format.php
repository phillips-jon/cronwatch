<?php

declare(strict_types=1);

namespace Cronwatch;

/** Alert titles and messages, character for character as format.ts writes them. */
final class Format
{
    private static function when(int|float|null $at, int|float $now): string
    {
        if ($at === null) {
            return 'never';
        }
        $iso = Js::isoTime($at);
        if ($iso === null) {
            return Js::beyondDates($at);
        }
        return substr(str_replace('T', ' ', $iso), 0, 19) . ' UTC (' . Duration::relative($at, $now) . ')';
    }

    private static function firstLines(?string $text, int $n): string
    {
        if ($text === null || $text === '') {
            return '';
        }
        return implode("\n", array_slice(explode("\n", $text), 0, $n));
    }

    private static function tail(?string $text, int $n): string
    {
        if ($text === null || $text === '') {
            return '';
        }
        $lines = explode("\n", Js::trimEnd($text));
        return implode("\n", array_slice($lines, max(0, count($lines) - $n)));
    }

    /** "Error: x" for a bare message, but not "Error: TypeError: x" for one that already names itself. */
    private static function errorLine(string $error): string
    {
        $text = self::firstLines($error, 4);
        return preg_match('/^[A-Za-z_$][A-Za-z0-9_$]*: /', $text) === 1 ? $text : "Error: {$text}";
    }

    /** A value as a template literal writes it: undefined for a missing one. */
    private static function text(mixed $value): string
    {
        return $value === null ? 'undefined' : Js::string($value);
    }

    /** Turns a draft into the title and message every channel shows. */
    public static function composeAlert(AlertDraft $draft, JobDefinition $def, int|float $now): Alert
    {
        $name = (string) $def->get('name');
        $run = $draft->run;
        $d = $draft->details;
        $lines = [];

        switch ($draft->type) {
            case AlertType::MISSED:
                $title = "{$name} missed its scheduled run";
                $lines[] = 'Due ' . self::when($d['dueAt'] ?? null, $now) . ', and no run had started by ' . self::when($d['deadline'] ?? null, $now)
                    . ' (grace ' . Duration::format($d['graceMs'] ?? NAN) . ').';
                $timezone = $def->get('timezone');
                $lines[] = 'Schedule: ' . self::text($def->get('schedule')) . ($timezone !== null && $timezone !== '' ? ' (' . Js::string($timezone) . ')' : '') . '.';
                $lines[] = 'Last run: ' . ($run !== null ? "{$run->status} " . self::when($run->startedAt, $now) : 'never') . '.';
                break;
            case AlertType::FAILED:
                $title = "{$name} failed";
                $n = $d['consecutiveFailures'] ?? 0;
                if ($n > 1) {
                    $lines[] = Js::number($n) . ' consecutive failures.';
                }
                if ($run !== null) {
                    $lines[] = 'Started ' . self::when($run->startedAt, $now) . ($run->durationMs !== null ? ', ran ' . Duration::format($run->durationMs) : '') . '.';
                    if ($run->error !== null && $run->error !== '') {
                        $lines[] = self::errorLine($run->error);
                    }
                    $out = self::tail($run->output, 8);
                    if ($out !== '') {
                        $lines[] = "Output (tail):\n{$out}";
                    }
                }
                break;
            case AlertType::STUCK:
                $title = "{$name} is stuck";
                if ($run !== null) {
                    $lines[] = 'Started ' . self::when($run->startedAt, $now) . ' and never reported finishing. Marked as timed out after '
                        . Duration::format($run->durationMs ?? $now - $run->startedAt) . '.';
                    $out = self::tail($run->output, 8);
                    if ($out !== '') {
                        $lines[] = "Output so far (tail):\n{$out}";
                    }
                }
                $lines[] = 'If the process was killed mid-run (a serverless timeout, a deploy), this is what that looks like.';
                break;
            case AlertType::SLOW:
                $title = "{$name} was slow";
                $lines[] = 'Took ' . Duration::format($d['durationMs'] ?? NAN) . '; the limit is ' . Duration::format($d['thresholdMs'] ?? NAN) . ' (' . self::text($d['basis'] ?? null) . ').';
                if ($run !== null) {
                    $lines[] = 'Started ' . self::when($run->startedAt, $now) . '.';
                }
                break;
            case AlertType::OVER_BUDGET:
                $title = "{$name} went over budget";
                foreach ($d['breaches'] ?? [] as $b) {
                    $lines[] = "{$b['metric']}: " . Evaluate::formatNumber($b['value']) . ', limit ' . Evaluate::formatNumber($b['limit']) . " ({$b['basis']}).";
                }
                if ($run !== null) {
                    $lines[] = 'Started ' . self::when($run->startedAt, $now) . '.';
                }
                break;
            case AlertType::RECOVERED:
                if (($d['reason'] ?? null) === 'unscheduled') {
                    $title = "{$name} is no longer scheduled";
                    $since = array_key_exists('since', $d) ? 'Missed since ' . self::when($d['since'], $now) . '. ' : '';
                    $lines[] = "{$since}It has no schedule now, so nothing is due; the missed alert is closed.";
                    break;
                }
                $title = "{$name} recovered";
                $after = implode(', ', array_map(fn ($c) => preg_replace('/_/', ' ', (string) $c, 1), $d['after'] ?? []));
                $lines[] = 'A run ' . ($run !== null ? self::when($run->startedAt, $now) : 'just now') . ' succeeded' . ($after !== '' ? " after: {$after}" : '') . '.';
                if ($run !== null && $run->durationMs !== null) {
                    $lines[] = 'Ran ' . Duration::format($run->durationMs) . '.';
                }
                break;
            default:
                throw new \InvalidArgumentException("unknown alert type {$draft->type}");
        }

        return new Alert($draft->type, $run, $d, $name, $def, $title, implode("\n", $lines), $now);
    }
}
