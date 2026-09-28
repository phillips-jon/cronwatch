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

    /** Records a triage attempt: the diagnosis, or null when there was none. */
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
        $f = Js::fields($data);
        $run = $f['run'] ?? null;
        $details = Js::plain($f['details'] ?? []);
        $alert = new self(
            type: (string) ($f['type'] ?? ''),
            run: $run === null ? null : Run::fromJson($run),
            details: is_array($details) ? $details : [],
            job: (string) ($f['job'] ?? ''),
            definition: JobDefinition::fromJson($f['definition'] ?? []),
            title: (string) ($f['title'] ?? ''),
            message: (string) ($f['message'] ?? ''),
            at: $f['at'] ?? 0,
        );
        if (array_key_exists('triage', $f)) {
            $alert->setTriage($f['triage']);
        }
        return $alert;
    }

    /** An alert's details as JSON: an object, even when empty. */
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
        return $out;
    }
}
