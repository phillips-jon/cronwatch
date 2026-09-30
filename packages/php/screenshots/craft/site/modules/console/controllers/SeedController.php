<?php

namespace modules\console\controllers;

use Cronwatch\Craft\LogChannel;
use Cronwatch\Craft\Plugin;
use Cronwatch\Craft\Recorder;
use Cronwatch\Craft\Storage;
use Cronwatch\Cronwatch;
use Craft;
use craft\console\Controller;
use craft\elements\User;
use modules\Demo;
use modules\jobs\SendNewsletter;
use modules\jobs\SyncInventory;
use yii\base\Event;
use yii\console\ExitCode;
use yii\queue\Queue;

/**
 * The screenshot site's week, for the Plugin Store screenshots.
 *
 * `craft app/seed --now=<epoch ms>` runs the week before that moment through
 * the plugin: each command by its route (Craft::$app->runAction, so the
 * plugin's EVENT_BEFORE_ACTION and EVENT_AFTER_ACTION handlers record it,
 * and a thrown exception is handed to the plugin as the console error
 * handler would), each queue job pushed onto Craft's queue and run from it.
 * The plugin's client is swapped for one on a clock the seed sets: to the
 * run's start before it runs, and to its end just before the plugin records
 * the end. Everything else (declaring, judging, alerting, the rows written)
 * is the plugin's and the library's own.
 *
 * `craft app/seed/settings` fills in the plugin's settings with made-up
 * channels and names the admin user.
 */
class SeedController extends Controller
{
    /** @var int|string the moment the week ends, in epoch milliseconds */
    public $now = 0;

    private const M = 60_000;
    private const H = 3_600_000;

    public function options($actionID): array
    {
        return [...parent::options($actionID), 'now'];
    }

    public function actionIndex(): int
    {
        $end = (int) $this->now;
        if ($end <= 0) {
            $this->stderr("--now is required\n");
            return ExitCode::USAGE;
        }
        mt_srand(20260930);
        $clock = null;
        $recorder = Plugin::getInstance()->getRecorder();
        $client = new Cronwatch(
            store: Storage::store(),
            alerts: [new LogChannel()],
            defaults: ['grace' => '10m'],
            onError: $recorder->report(...),
            now: function () use (&$clock): int {
                return $clock ?? (int) floor(microtime(true) * 1000);
            },
        );
        (new \ReflectionProperty(Recorder::class, 'client'))->setValue($recorder, $client);

        // The run's end, set just before the plugin's own handlers record it.
        $finish = null;
        $ends = function () use (&$clock, &$finish): void {
            if ($finish !== null) {
                $clock = $finish;
            }
        };
        Event::on(\yii\console\Controller::class, \yii\base\Controller::EVENT_AFTER_ACTION, $ends, null, false);
        Event::on(Queue::class, Queue::EVENT_AFTER_EXEC, $ends, null, false);
        Event::on(Queue::class, Queue::EVENT_AFTER_ERROR, $ends, null, false);

        $runs = $this->week($end);
        $queue = Craft::$app->getQueue();
        $failed = 0;
        foreach ($runs as [$at, $kind, $what, $takes, $scenario]) {
            $clock = $at;
            $finish = $at + $takes;
            Demo::$scenario = $scenario;
            if ($kind === 'command') {
                try {
                    Craft::$app->runAction($what);
                } catch (\Throwable $error) {
                    // What the console error handler hands the plugin when a command throws.
                    $clock = $finish;
                    $recorder->commandFailed($error);
                    $failed++;
                }
            } else {
                $queue->push(new $what());
                $queue->run();
            }
        }
        // Failed queue jobs stay in Craft's queue as failed; the site has dealt with them.
        $queue->releaseAll();
        $finish = null;
        $clock = null;
        Demo::$scenario = [];
        $this->stdout(sprintf("seeded %d runs (%d commands failed), up to %s\n", count($runs), $failed, gmdate('Y-m-d H:i', intdiv($end, 1000))));
        return ExitCode::OK;
    }

    /**
     * The week's runs, oldest first: [start ms, "command" or "queue", route or class, how long ms, scenario].
     *
     * @return list<array{int, string, string, int, array<string, mixed>}>
     */
    private function week(int $end): array
    {
        $start = $end - 7 * 24 * self::H;
        $runs = [];
        $add = function (int $at, string $kind, string $what, int $takes, array $scenario = []) use (&$runs, $start, $end): void {
            if ($at >= $start && $at + $takes < $end) {
                $runs[] = [$at, $kind, $what, $takes, $scenario];
            }
        };
        $jitter = fn (int $ms): int => (int) round($ms * (0.85 + mt_rand(0, 300) / 1000));
        // A crontab starts its commands a moment after the minute.
        $late = fn (): int => mt_rand(150, 1400);

        // send-reports, every 15 minutes.
        foreach ($this->every($start, $end, 15 * self::M, 0) as $t) {
            $london = $this->london($t);
            $due = [];
            if ((int) $london->format('i') === 0 && (int) $london->format('G') % 3 === 0) {
                $due[] = 'the low-stock report (2 recipients)';
            }
            if ($london->format('H:i') === '09:00') {
                $due[] = 'the daily sales summary (4 recipients)';
            }
            $add($t + $late(), 'command', 'app/reports/send', $jitter($due === [] ? 900 : 3_800), ['due' => $due]);
        }

        // The supplier feed, hourly at :20: its last four runs fail.
        $feed = $this->every($start, $end, self::H, 20 * self::M);
        foreach ($feed as $i => $t) {
            $down = $i >= count($feed) - 4;
            $add($t + $late(), 'command', 'app/feeds/import', $down ? 31_000 + mt_rand(0, 2_000) : $jitter(11_000), $down ? ['down' => true] : [
                'products' => 1_281 + mt_rand(0, 9), 'prices' => mt_rand(4, 60), 'stock' => mt_rand(60, 180),
            ]);
        }

        // Exchange rates, hourly at :05, until the crontab line was lost five hours ago.
        foreach ($this->every($start, $end - 5 * self::H, self::H, 5 * self::M) as $t) {
            $add($t + $late(), 'command', 'app/rates/fetch', $jitter(1_600), [
                'eur' => number_format(1.18 + mt_rand(0, 150) / 10_000, 4), 'usd' => number_format(1.33 + mt_rand(0, 180) / 10_000, 4),
            ]);
        }

        // The sitemap, hourly at :45.
        foreach ($this->every($start, $end, self::H, 45 * self::M) as $t) {
            $add($t + $late(), 'command', 'app/sitemap/rebuild', $jitter(6_200), ['urls' => 2_400 + mt_rand(0, 12), 'products' => 1_281 + mt_rand(0, 9)]);
        }

        // Nightly, in the site's own time zone: asset cleanup at 02:30 and the resave at 03:00, which ran slow last night.
        $cleanup = $this->daily($start, $end, 2, 30);
        foreach ($cleanup as $t) {
            $add($t + $late(), 'command', 'app/assets/cleanup', $jitter(24_000), [
                'transforms' => mt_rand(12, 70), 'freed' => mt_rand(40, 260) . ' MB', 'uploads' => mt_rand(0, 6),
            ]);
        }
        $resave = $this->daily($start, $end, 3, 0);
        foreach ($resave as $i => $t) {
            $add($t + $late(), 'command', 'resave/entries', $i === count($resave) - 1 ? 552_000 + mt_rand(0, 9_000) : $jitter(48_000));
        }

        // Inventory, queued every half hour: three attempts in a row failed yesterday, then it recovered.
        $inventory = $this->every($start, $end, 30 * self::M, 10 * self::M);
        $firstDown = null;
        foreach ($inventory as $i => $t) {
            if ($firstDown === null && $t >= $end - 27 * self::H) {
                $firstDown = $i;
            }
        }
        foreach ($inventory as $i => $t) {
            $down = $firstDown !== null && $i >= $firstDown && $i < $firstDown + 3;
            $add($t + mt_rand(2_000, 9_000), 'queue', SyncInventory::class, $down ? 30_000 + mt_rand(100, 900) : $jitter(14_000), $down ? ['down' => true] : ['levels' => mt_rand(40, 400)]);
        }

        // The newsletter, queued each weekday morning.
        $editions = ['New in this week', 'The autumn layering guide', 'Back in stock: trail boots', 'Weekend deals', 'Staff picks for October'];
        foreach ($this->daily($start, $end, 9, 0) as $t) {
            if ((int) $this->london($t)->format('N') <= 5) {
                $add($t + mt_rand(20_000, 90_000), 'queue', SendNewsletter::class, $jitter(84_000), [
                    'sent' => 12_400 + mt_rand(0, 200), 'edition' => $editions[mt_rand(0, count($editions) - 1)],
                ]);
            }
        }

        usort($runs, fn (array $a, array $b): int => $a[0] <=> $b[0]);
        return $runs;
    }

    /** @return list<int> every `step` ms from `offset` past a UTC hour, within [start, end) */
    private function every(int $start, int $end, int $step, int $offset): array
    {
        $out = [];
        for ($t = intdiv($start, self::H) * self::H + $offset; $t < $end; $t += $step) {
            if ($t >= $start) {
                $out[] = $t;
            }
        }
        return $out;
    }

    /** @return list<int> the day's hh:mm in Europe/London, each day within [start, end) */
    private function daily(int $start, int $end, int $hour, int $minute): array
    {
        $out = [];
        $day = $this->london($start - 24 * self::H)->setTime(0, 0);
        while ($day->getTimestamp() * 1000 < $end) {
            $t = $day->setTime($hour, $minute)->getTimestamp() * 1000;
            if ($t >= $start && $t < $end) {
                $out[] = $t;
            }
            $day = $day->modify('+1 day');
        }
        return $out;
    }

    private function london(int $ms): \DateTimeImmutable
    {
        return (new \DateTimeImmutable('@' . intdiv($ms, 1000)))->setTimezone(new \DateTimeZone('Europe/London'));
    }

    public function actionSettings(): int
    {
        $plugin = Plugin::getInstance();
        $saved = Craft::$app->getPlugins()->savePluginSettings($plugin, [
            'emailTo' => 'ops@example.com, dev@example.com',
            'slackWebhookUrl' => '$SLACK_WEBHOOK_URL',
            'webhookUrl' => '$ALERTS_WEBHOOK_URL',
            'webhookSecret' => '$ALERTS_WEBHOOK_SECRET',
            'grace' => '10m',
        ]);
        if (!$saved) {
            $this->stderr('the settings were not saved: ' . json_encode($plugin->getSettings()->getErrors()) . "\n");
            return ExitCode::UNSPECIFIED_ERROR;
        }
        $user = User::find()->username('admin')->status(null)->one();
        if ($user !== null) {
            $user->fullName = 'Sam Porter';
            Craft::$app->getElements()->saveElement($user, false);
        }
        $this->stdout("saved the settings\n");
        return ExitCode::OK;
    }
}
