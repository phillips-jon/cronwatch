<?php

declare(strict_types=1);

namespace Cronwatch;

/**
 * A job's state. `version` goes up by one on every write, so a store can
 * refuse a write made from a stale read (see compareAndSetState); null
 * counts as 0.
 */
final class JobState
{
    /**
     * @param array<string, int|float> $open conditions currently open, with the time each one opened
     * @param int|float|null $lastAlertAt when an alert last reached at least one channel
     * @param list<string>|null $pendingRecovery conditions that alerted and have since closed, waiting for the recovered message
     * @param list<Alert>|null $undelivered alerts that no channel accepted; each check retries them once
     * @param list<SendingAlert>|null $sending the outbox: alerts written with the state that opened their
     *        condition, while the process that wrote them sends them (see Evaluate::holdAlerts); null when empty
     */
    public function __construct(
        public string $job,
        public array $open = [],
        public int|float $consecutiveFailures = 0,
        public int|float|null $silencedUntil = null,
        public int|float|null $lastAlertAt = null,
        public ?array $pendingRecovery = null,
        public ?array $undelivered = null,
        public int|float|null $version = null,
        public ?array $sending = null,
    ) {
    }

    /**
     * A state as stored. A foreign or hand-edited row may hold anything, so
     * the fields are read leniently: a time that is not a number, a
     * condition name that is not a string or a queued alert that is not an
     * object reads as absent, so one odd value never makes the job
     * unevaluable, or its silence impossible to change.
     */
    public static function fromJson(array|\stdClass|self $data): self
    {
        if ($data instanceof self) {
            return $data;
        }
        $f = Js::fields($data);
        $pending = $f['pendingRecovery'] ?? null;
        $undelivered = $f['undelivered'] ?? null;
        $sending = $f['sending'] ?? null;
        return new self(
            job: is_scalar($f['job'] ?? null) ? (string) $f['job'] : '',
            open: Js::fields($f['open'] ?? []),
            // A foreign row's count may be anything; one that is not a number
            // reads as none. Evaluate::failureCount() says what it counts as.
            consecutiveFailures: Js::isNumber($f['consecutiveFailures'] ?? null) ? $f['consecutiveFailures'] : 0,
            silencedUntil: Js::isNumber($f['silencedUntil'] ?? null) ? $f['silencedUntil'] : null,
            lastAlertAt: Js::isNumber($f['lastAlertAt'] ?? null) ? $f['lastAlertAt'] : null,
            pendingRecovery: is_array($pending) ? array_values(array_filter($pending, 'is_string')) : null,
            undelivered: is_array($undelivered) ? array_values(array_map(Alert::fromJson(...), array_filter($undelivered, self::isObject(...)))) : null,
            // A foreign row's version may be anything; one that is not a
            // number reads as none. Evaluate::stateVersion() says what it counts as.
            version: Js::isNumber($f['version'] ?? null) ? $f['version'] : null,
            // Kept only when it is a list holding something; each entry is read leniently (see SendingAlert).
            sending: is_array($sending) && $sending !== [] && array_is_list($sending) ? array_map(SendingAlert::fromJson(...), $sending) : null,
        );
    }

    /** A decoded JSON object (or an array standing for one), or one of this package's alerts. */
    private static function isObject(mixed $value): bool
    {
        return $value instanceof \stdClass || $value instanceof Alert || (is_array($value) && ($value === [] || !array_is_list($value)));
    }

    /**
     * pendingRecovery, undelivered and version are left out when unset, as in
     * state written before they existed, and sending when it holds nothing.
     * The version comes after the others and sending last, where the SDK's
     * spread of a normalized state puts them.
     */
    public function toJson(): array
    {
        $out = [
            'job' => $this->job,
            'open' => Js::obj($this->open),
            'consecutiveFailures' => $this->consecutiveFailures,
            'silencedUntil' => $this->silencedUntil,
            'lastAlertAt' => $this->lastAlertAt,
        ];
        if ($this->pendingRecovery !== null) {
            $out['pendingRecovery'] = array_values($this->pendingRecovery);
        }
        if ($this->undelivered !== null) {
            $out['undelivered'] = array_map(fn (Alert $a) => $a->toJson(), array_values($this->undelivered));
        }
        if ($this->version !== null) {
            $out['version'] = $this->version;
        }
        if ($this->sending !== null && $this->sending !== []) {
            $out['sending'] = array_map(fn (SendingAlert $s) => $s->toJson(), array_values($this->sending));
        }
        return $out;
    }
}
