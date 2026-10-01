<?php

declare(strict_types=1);

namespace Cronwatch;

/**
 * An alert as every channel receives it.
 *
 * `triage` is the triage function's diagnosis, or null. A null triage is
 * one of two things, as in the SDK: never tried (no "triage" key in the
 * JSON), or tried and nothing came of it ("triage": null, and triageTried is
 * true). A tried alert is not triaged again.
 */
final class Alert
{
    private const KNOWN = ['type', 'run', 'details', 'job', 'definition', 'title', 'message', 'at', 'triage'];

    /** @var array<string, mixed> the stored fields this release does not know, as decoded JSON */
    private array $extra = [];

    /** @param array<string, mixed> $details see AlertDraft */
    public function __construct(
        public string $type,
        public ?Run $run,
        public array $details,
        public string $job,
        public JobDefinition $definition,
        /** One line, suitable as a notification title. */
        public string $title,
        /** A few lines of plain text with the specifics. */
        public string $message,
        public int|float $at,
        public ?string $triage = null,
        public bool $triageTried = false,
    ) {
        if ($triage !== null) {
            $this->triageTried = true;
        }
    }

    /**
     * Records a triage attempt: the diagnosis, or null when there was none.
     *
     * @internal Called by the client when triage has run.
     */
    public function setTriage(?string $diagnosis): void
    {
        $this->triage = $diagnosis;
        $this->triageTried = true;
    }

    public static function fromJson(array|\stdClass|self $data): self
    {
        if ($data instanceof self) {
            return $data;
        }
        // A queued alert may come from a foreign or hand-edited row: a field
        // of the wrong kind reads as absent rather than making the state unreadable.
        $f = Js::fields($data);
        $run = $f['run'] ?? null;
        // The details' own values stay as decoded, so an empty object in them
        // is written back as one.
        $details = $f['details'] ?? [];
        $details = $details instanceof \stdClass || is_array($details) ? Js::fields($details) : [];
        $definition = $f['definition'] ?? null;
        $alert = new self(
            type: self::text($f['type'] ?? null),
            run: $run instanceof \stdClass || $run instanceof Run || (is_array($run) && $run !== []) ? Run::fromJson($run) : null,
            details: $details,
            job: self::text($f['job'] ?? null),
            definition: JobDefinition::fromJson($definition instanceof \stdClass || $definition instanceof JobDefinition || is_array($definition) ? $definition : []),
            title: self::text($f['title'] ?? null),
            message: self::text($f['message'] ?? null),
            at: Js::isNumber($f['at'] ?? null) ? $f['at'] : 0,
        );
        if (array_key_exists('triage', $f)) {
            $alert->setTriage(is_string($f['triage']) ? $f['triage'] : null);
        }
        // Fields a newer release added are kept, so the queue keeps them and
        // a retry sends them, as the SDK carries a queued alert as it was stored.
        $alert->extra = array_diff_key($f, array_flip(self::KNOWN));
        return $alert;
    }

    private static function text(mixed $value): string
    {
        return is_scalar($value) ? (string) $value : '';
    }

    /**
     * An alert's details as JSON: an object, even when empty.
     *
     * @internal
     */
    public static function detailsJson(array $details): \stdClass
    {
        return Js::obj($details);
    }

    public function toJson(): array
    {
        $out = [
            'type' => $this->type,
            'run' => $this->run?->toJson(),
            'details' => self::detailsJson($this->details),
            'job' => $this->job,
            'definition' => $this->definition->toJson(),
            'title' => $this->title,
            'message' => $this->message,
            'at' => $this->at,
        ];
        if ($this->triageTried) {
            $out['triage'] = $this->triage;
        }
        foreach ($this->extra as $key => $value) {
            $out[$key] = $value;
        }
        return $out;
    }
}
