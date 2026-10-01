<?php

declare(strict_types=1);

namespace Cronwatch;

/**
 * An alert in JobState's `sending` (SendingAlert): `until` (epoch
 * milliseconds) is when its sender's lease runs out. Read leniently, as
 * Evaluate::releaseSending() treats an entry: one whose `until` is not a
 * number counts as run out, and one without an alert object is dropped when
 * it is released, so a malformed entry never makes the state unreadable.
 * An entry read from a state is written back as it was stored, malformed
 * or holding keys this release does not know, as the SDK keeps it.
 *
 * @internal
 */
final class SendingAlert
{
    /** Whether the entry was read from a state, and so is written back as $stored. */
    private bool $read = false;
    private mixed $stored = null;

    public function __construct(
        public mixed $until,
        public ?Alert $alert,
    ) {
    }

    public static function fromJson(mixed $data): self
    {
        if ($data instanceof self) {
            return $data;
        }
        $f = Js::fields($data);
        $alert = $f['alert'] ?? null;
        $entry = new self(
            until: Js::isNumber($f['until'] ?? null) ? $f['until'] : null,
            alert: $alert instanceof \stdClass || (is_array($alert) && !array_is_list($alert)) || $alert instanceof Alert ? Alert::fromJson($alert) : null,
        );
        $entry->read = true;
        $entry->stored = $data;
        return $entry;
    }

    public function toJson(): mixed
    {
        if ($this->read) {
            return $this->stored;
        }
        return ['until' => $this->until, 'alert' => $this->alert?->toJson()];
    }
}
