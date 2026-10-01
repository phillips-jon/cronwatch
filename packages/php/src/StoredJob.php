<?php

declare(strict_types=1);

namespace Cronwatch;

/** A job as a store holds it: its stored definition and when it was first and last declared. */
final class StoredJob
{
    /** False for a job whose stored definition was not a JSON object (see unreadable()). */
    private bool $readable = true;

    public function __construct(
        public string $name,
        public JobDefinition $definition,
        public int|float $createdAt,
        public int|float $updatedAt,
    ) {
    }

    /**
     * A job whose stored definition is not a JSON object (a foreign,
     * hand-edited or damaged row's): its definition reads as just its name,
     * and the client does not evaluate it. A check reports it, and the
     * dashboard shows it as failing, while the other jobs carry on.
     *
     * @internal For the stores' row readers.
     */
    public static function unreadable(string $name, int|float $createdAt, int|float $updatedAt): self
    {
        $job = new self($name, new JobDefinition(['name' => $name]), $createdAt, $updatedAt);
        $job->readable = false;
        return $job;
    }

    /**
     * A stored definition as the client reads it: as stored, unknown fields
     * included, except `tags`, kept only when it is a list of strings.
     *
     * @internal For the stores' row readers.
     */
    public static function readDefinition(\stdClass|array $definition): JobDefinition
    {
        $fields = Js::fields($definition);
        if (array_key_exists('tags', $fields)) {
            $tags = $fields['tags'];
            if (!is_array($tags) || !array_is_list($tags) || array_filter($tags, fn (mixed $tag) => !is_string($tag)) !== []) {
                unset($fields['tags']);
            }
        }
        return JobDefinition::fromJson($fields);
    }

    /** Whether the stored definition was a JSON object, so the job can be evaluated. */
    public function isReadable(): bool
    {
        return $this->readable;
    }

    public static function fromJson(array|\stdClass|self $data): self
    {
        if ($data instanceof self) {
            return $data;
        }
        $f = Js::fields($data);
        return new self(
            (string) ($f['name'] ?? ''),
            JobDefinition::fromJson($f['definition'] ?? []),
            $f['createdAt'] ?? 0,
            $f['updatedAt'] ?? 0,
        );
    }

    public function toJson(): array
    {
        return ['name' => $this->name, 'definition' => $this->definition->toJson(), 'createdAt' => $this->createdAt, 'updatedAt' => $this->updatedAt];
    }
}
