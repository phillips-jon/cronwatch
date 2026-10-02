<?php

declare(strict_types=1);

namespace Cronwatch;

/**
 * Marks a class whose work CronWatch watches, with the job's options: a
 * Laravel queued job, a Symfony Messenger message, or a message a Symfony
 * schedule sends. The options are job()'s, with `name` for the job's name
 * (default: the class's name, backslashes as dots) and `enabled: false` to
 * leave the class out.
 *
 *     #[Cronwatch\Watch(grace: '15m', expect: 'Report written', failuresBeforeAlert: 3)]
 *     final class SendNightlyReport implements ShouldQueue { ... }
 *
 * The attribute is read from the class, else from its nearest parent that
 * has one.
 */
#[\Attribute(\Attribute::TARGET_CLASS)]
final class Watch
{
    /**
     * @param array<string, int|float>|null $budget
     * @param array<string, int|float>|null $floor
     * @param list<string>|null $tags
     */
    public function __construct(
        public readonly ?string $name = null,
        public readonly ?string $schedule = null,
        public readonly ?string $timezone = null,
        public readonly string|int|null $grace = null,
        public readonly string|int|null $timeout = null,
        public readonly string|int|null $maxDuration = null,
        public readonly ?array $budget = null,
        public readonly ?string $expect = null,
        public readonly ?int $failuresBeforeAlert = null,
        public readonly ?string $description = null,
        public readonly ?array $tags = null,
        public readonly bool $enabled = true,
        public readonly ?array $floor = null,
    ) {
    }

    /** @var array<class-string, self|false> */
    private static array $found = [];

    /**
     * The job's options, in the order job() stores them, without the ones left unset.
     *
     * @return array<string, mixed>
     */
    public function options(): array
    {
        $options = [];
        foreach (JobDefinition::OPTIONS as $key) {
            if ($this->{$key} !== null) {
                $options[$key] = $this->{$key};
            }
        }
        return $options;
    }

    /** The attribute on a class (or an object's class), or its nearest parent's; null when there is none. */
    public static function of(string|object $class): ?self
    {
        $name = is_object($class) ? $class::class : ltrim($class, '\\');
        if (array_key_exists($name, self::$found)) {
            return self::$found[$name] ?: null;
        }
        $found = false;
        if (class_exists($name)) {
            for ($reflection = new \ReflectionClass($name); $reflection !== false; $reflection = $reflection->getParentClass()) {
                $attributes = $reflection->getAttributes(self::class);
                if ($attributes !== []) {
                    $found = $attributes[0]->newInstance();
                    break;
                }
            }
        }
        self::$found[$name] = $found;
        return $found ?: null;
    }
}
