<?php

declare(strict_types=1);

namespace Cronwatch;

/** A job as a store holds it: its stored definition and when it was first and last declared. */
final class StoredJob
{
    public function __construct(
        public string $name,
        public JobDefinition $definition,
        public int|float $createdAt,
        public int|float $updatedAt,
    ) {
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
