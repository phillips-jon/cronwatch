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
    ) {
    }

    public static function fromJson(array|\stdClass|self $data): self
    {
        if ($data instanceof self) {
            return $data;
        }
        $f = Js::fields($data);
        $pending = $f['pendingRecovery'] ?? null;
        $undelivered = $f['undelivered'] ?? null;
        return new self(
            job: (string) ($f['job'] ?? ''),
            open: Js::fields($f['open'] ?? []),
            consecutiveFailures: $f['consecutiveFailures'] ?? 0,
            silencedUntil: $f['silencedUntil'] ?? null,
            lastAlertAt: $f['lastAlertAt'] ?? null,
            pendingRecovery: is_array($pending) ? array_values(array_map('strval', $pending)) : null,
            undelivered: is_array($undelivered) ? array_values(array_map(fn ($a) => Alert::fromJson($a), $undelivered)) : null,
            version: $f['version'] ?? null,
        );
    }

    /**
     * pendingRecovery, undelivered and version are left out when unset, as in
     * state written before they existed. The version comes last, where the
     * SDK's spread of a normalized state puts it.
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
        return $out;
    }
}
