<?php

declare(strict_types=1);

namespace Cronwatch\Craft;

use yii\base\Behavior;

/**
 * Watches a console controller's actions, for a command the app writes
 * itself: each run of an action is a run of a job, with these options.
 *
 *     public function behaviors(): array
 *     {
 *         return [...parent::behaviors(), 'cronwatch' => [
 *             'class' => \Cronwatch\Craft\WatchCommand::class,
 *             'schedule' => '0 3 * * *',
 *             'grace' => '15m',
 *         ]];
 *     }
 *
 * The job is named after the route ("craft:app:reports:send" for
 * `craft app/reports/send`) unless `name` is given; `actions` limits it to
 * some of the controller's actions. The plugin's own listener records the
 * runs (see Recorder); the behavior only carries the options. A route the
 * settings' commands also list is recorded once, with the settings'
 * options: config/cronwatch.php is the operator's word over the code's.
 *
 * The check cannot see a behavior until its command runs, so a job declared
 * here keeps its schedule after the behavior is removed: forget it from the
 * dashboard then.
 */
final class WatchCommand extends Behavior
{
    public ?string $name = null;
    public ?string $schedule = null;
    public ?string $timezone = null;
    public string|int|null $grace = null;
    public string|int|null $timeout = null;
    public string|int|null $maxDuration = null;
    /** @var array<string, int|float>|null */
    public ?array $budget = null;
    /** @var array<string, int|float>|null */
    public ?array $floor = null;
    public ?string $expect = null;
    public ?int $failuresBeforeAlert = null;
    public ?string $description = null;
    /** @var list<string>|null */
    public ?array $tags = null;
    /** @var list<string>|null the action IDs watched; null for every one */
    public ?array $actions = null;

    /** Whether an action of the controller is watched. */
    public function watches(string $actionId): bool
    {
        return $this->actions === null || in_array($actionId, $this->actions, true);
    }

    /** @return array<string, mixed> the job's options, with its name when given */
    public function options(): array
    {
        $options = [];
        foreach (['name', 'schedule', 'timezone', 'grace', 'timeout', 'maxDuration', 'budget', 'floor', 'expect', 'failuresBeforeAlert', 'description', 'tags'] as $key) {
            if ($this->{$key} !== null) {
                $options[$key] = $this->{$key};
            }
        }
        return $options;
    }
}
