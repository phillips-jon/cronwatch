<?php

declare(strict_types=1);

namespace Cronwatch;

/**
 * A job's options, kept as an ordered set of fields with the SDK's camelCase
 * names, so its JSON has the same keys in the same order as the SDK writes:
 * defaults, then options as given, then name, and a stored `expect` last.
 * Fields this version does not know (written by a newer one) are kept as
 * they came.
 *
 * @property-read string|null $name
 * @property-read string|null $schedule
 * @property-read string|null $timezone
 * @property-read mixed $grace
 * @property-read mixed $timeout
 * @property-read mixed $maxDuration
 * @property-read array<string, int|float>|null $budget
 * @property-read mixed $expect
 * @property-read mixed $failuresBeforeAlert
 * @property-read string|null $description
 * @property-read list<string>|null $tags
 */
final class JobDefinition
{
    /** The options job() takes, in the SDK's order. */
    public const OPTIONS = ['schedule', 'timezone', 'grace', 'timeout', 'maxDuration', 'budget', 'expect', 'failuresBeforeAlert', 'description', 'tags'];

    /** @param array<string, mixed> $fields */
    public function __construct(public readonly array $fields = [])
    {
    }

    /** A definition from its JSON shape, or a decoded object. */
    public static function fromJson(array|\stdClass|self|null $data): self
    {
        if ($data instanceof self) {
            return $data;
        }
        $fields = Js::fields($data ?? []);
        if (isset($fields['budget']) && ($fields['budget'] instanceof \stdClass || is_array($fields['budget']))) {
            $fields['budget'] = Js::fields($fields['budget']);
        }
        if (isset($fields['tags']) && is_array($fields['tags'])) {
            $fields['tags'] = array_values($fields['tags']);
        }
        return new self($fields);
    }

    public function get(string $key, mixed $default = null): mixed
    {
        return $this->fields[$key] ?? $default;
    }

    public function has(string $key): bool
    {
        return isset($this->fields[$key]);
    }

    public function __get(string $key): mixed
    {
        return $this->fields[$key] ?? null;
    }

    public function __isset(string $key): bool
    {
        return isset($this->fields[$key]);
    }

    /**
     * A copy with some fields changed, or added at the end as in JavaScript.
     *
     * @param array<string, mixed> $changes
     */
    public function with(array $changes): self
    {
        $fields = $this->fields;
        foreach ($changes as $key => $value) {
            $fields[$key] = $value;
        }
        return new self($fields);
    }

    /** A copy without a field. */
    public function without(string $key): self
    {
        $fields = $this->fields;
        unset($fields[$key]);
        return new self($fields);
    }

    /** The JSON shape: fields set to null are left out, as undefined is. */
    public function toJson(): \stdClass
    {
        $out = [];
        foreach ($this->fields as $key => $value) {
            if ($value === null || $value instanceof \Closure) {
                continue;
            }
            $out[$key] = $key === 'budget' && is_array($value) ? Js::obj($value) : $value;
        }
        return Js::obj($out);
    }
}
