<?php

declare(strict_types=1);

namespace Cronwatch\WordPress;

\defined('ABSPATH') || exit;

use Cronwatch\Alerts\Slack;
use Cronwatch\Alerts\Webhook;
use Cronwatch\CheckResult;
use Cronwatch\Cronwatch;
use Cronwatch\Duration;
use Cronwatch\Job\RunHandle;

/**
 * The plugin: one client per request on the site's database, the WP-Cron
 * watcher, its own check event, the settings page and the WP-CLI command.
 * Nothing here runs on an ordinary page view but the two cron filters, which
 * only note an event while WP-Cron is running one.
 */
final class Plugin
{
    /** The plugin's own WP-Cron event, which runs the check. It is not watched. */
    public const CHECK_HOOK = 'cronwatch_check';
    public const CHECK_SCHEDULE = 'cronwatch_five_minutes';
    public const SETTINGS = 'cronwatch_settings';
    public const DEFAULTS = ['email_to' => '', 'slack_webhook_url' => '', 'webhook_url' => '', 'webhook_secret' => '', 'grace' => '10m'];

    private static ?Watcher $watcher = null;
    private static ?Cronwatch $client = null;

    public static function boot(): void
    {
        self::watcher()->register();
        add_filter('cron_schedules', [self::class, 'schedules']);
        add_action(self::CHECK_HOOK, [self::class, 'runCheck']);
        if (is_admin()) {
            Admin::register();
        }
        if (defined('WP_CLI') && WP_CLI) {
            \WP_CLI::add_command('cronwatch', Cli::class);
        }
    }

    public static function watcher(): Watcher
    {
        return self::$watcher ??= new Watcher();
    }

    /** @param array<string, array{interval: int, display: string}> $schedules */
    public static function schedules(array $schedules): array
    {
        $schedules[self::CHECK_SCHEDULE] ??= ['interval' => 300, 'display' => __('Every five minutes (CronWatch)', 'cronwatch')];
        return $schedules;
    }

    /** Activation: the tables, and the check every five minutes. Refuses a database too old for them. */
    public static function activate(): void
    {
        global $wpdb;
        $why = WpdbStore::unsupported((string) $wpdb->db_server_info());
        if ($why !== null) {
            deactivate_plugins(plugin_basename(CRONWATCH_PLUGIN_FILE));
            wp_die(esc_html($why), '', ['back_link' => true]);
        }
        (new WpdbStore($wpdb))->install();
        add_option(self::SETTINGS, self::DEFAULTS, '', false);
        if (!wp_next_scheduled(self::CHECK_HOOK)) {
            add_filter('cron_schedules', [self::class, 'schedules']);
            wp_schedule_event(time() + 60, self::CHECK_SCHEDULE, self::CHECK_HOOK);
        }
    }

    /** Deactivation: the check event goes; the tables and settings stay until the plugin is deleted. */
    public static function deactivate(): void
    {
        wp_clear_scheduled_hook(self::CHECK_HOOK);
    }

    /** @return array<string, string> */
    public static function settings(): array
    {
        $saved = get_option(self::SETTINGS, []);
        return array_replace(self::DEFAULTS, is_array($saved) ? array_intersect_key($saved, self::DEFAULTS) : []);
    }

    /**
     * The alert channels the settings name, and any added through the
     * cronwatch_alerts filter. Nothing is sent anywhere unless one is set:
     * with none, alerts go to PHP's error log.
     *
     * @return list<mixed>
     */
    public static function channels(?array $settings = null): array
    {
        $settings ??= self::settings();
        $link = fn (\Cronwatch\Alert $alert): string => admin_url('tools.php?page=cronwatch');
        $channels = [];
        if ($settings['email_to'] !== '') {
            $channels[] = new WpMail($settings['email_to'], null, '[' . wp_specialchars_decode((string) get_bloginfo('name'), ENT_QUOTES) . ']', $link);
        }
        if ($settings['slack_webhook_url'] !== '') {
            $channels[] = new Slack($settings['slack_webhook_url'], $link, new WpHttp());
        }
        if ($settings['webhook_url'] !== '') {
            $channels[] = new Webhook($settings['webhook_url'], [], $settings['webhook_secret'] !== '' ? $settings['webhook_secret'] : null, new WpHttp());
        }
        $channels = apply_filters('cronwatch_alerts', $channels);
        return is_array($channels) ? array_values($channels) : [];
    }

    /** The client for this request, on the site's database. */
    public static function client(): Cronwatch
    {
        if (self::$client !== null) {
            return self::$client;
        }
        global $wpdb;
        $settings = self::settings();
        $channels = self::channels($settings);
        $args = [
            'store' => new WpdbStore($wpdb),
            'alerts' => $channels === [] ? null : $channels,
            'defaults' => ['grace' => self::grace($settings['grace'])],
            'cronSecret' => false,
            'onError' => [self::class, 'report'],
        ];
        $args = apply_filters('cronwatch_client_args', $args);
        return self::$client = new Cronwatch(...(is_array($args) ? $args : []));
    }

    /** A grace that parses, or the library's default. */
    private static function grace(string $grace): string
    {
        try {
            Duration::parse($grace, 'grace');
            return $grace;
        } catch (\Throwable) {
            return '10m';
        }
    }

    /** Forgets the client, so the next call reads the settings again. For tests and the settings page. */
    public static function reset(): void
    {
        self::$client = null;
    }

    /** Anything that goes wrong outside a job: PHP's error log, as the library's default does. */
    public static function report(\Throwable $error, string $where): void
    {
        error_log("[cronwatch] {$where}: " . $error->getMessage()); // phpcs:ignore WordPress.PHP.DevelopmentFunctions.error_log_error_log
    }

    /**
     * Every event now in the cron array as a job, the plugin's own check left out.
     *
     * @return array<string, array{hook: string, args: array, recurrence: ?string, interval: ?int}>
     */
    public static function cronJobs(): array
    {
        $crons = function_exists('_get_cron_array') ? _get_cron_array() : [];
        $jobs = Jobs::fromCron(is_array($crons) ? $crons : [], wp_get_schedules());
        return array_filter($jobs, fn (array $job) => $job['hook'] !== self::CHECK_HOOK
            && apply_filters('cronwatch_watch_event', true, $job['hook'], $job['args'], $job['recurrence']));
    }

    /**
     * Declares one job, with the cronwatch_job_options filter applied. The
     * library's defaults (grace from the settings) fill what it leaves out.
     *
     * @param array{hook: string, args: array, recurrence: ?string, interval: ?int} $job
     */
    private static function declare(Cronwatch $cw, string $name, array $job): \Cronwatch\Job\JobHandle
    {
        $options = apply_filters('cronwatch_job_options', Jobs::options($job), $job['hook'], $job['args'], $job['recurrence']);
        return $cw->job($name, is_array($options) ? $options : Jobs::options($job));
    }

    /**
     * Starts the run of the event WP-Cron is about to run. A recurring event
     * of the same name still in the cron array gives the definition, so a
     * single event of a hook that also recurs does not take its schedule away.
     *
     * @param array{hook: string, args: array, recurrence: ?string, interval: ?int} $event
     */
    public static function startRun(array $event): RunHandle
    {
        $jobs = self::cronJobs();
        $name = Jobs::add($jobs, $event['hook'], $event['args'], $event['recurrence'], $event['interval']);
        return self::declare(self::client(), $name, $jobs[$name])->start(trigger: 'wp-cron');
    }

    /**
     * One check: every event in the cron array declared as a job, names no
     * longer in it declared again without their schedule (so an event that
     * went away with its plugin is never reported missed), then the library's
     * check.
     */
    public static function check(): CheckResult
    {
        $cw = self::client();
        $jobs = self::cronJobs();
        foreach ($jobs as $name => $job) {
            self::declare($cw, $name, $job);
        }
        foreach ($cw->store->listJobs() as $stored) {
            $definition = $stored->definition;
            $tags = $definition->get('tags');
            if (isset($jobs[$stored->name]) || !is_array($tags) || !in_array(Jobs::TAG, $tags, true) || !$definition->has('schedule')) {
                continue;
            }
            $options = [];
            foreach (['tags', 'grace', 'timeout', 'maxDuration', 'budget', 'failuresBeforeAlert'] as $key) {
                if ($definition->has($key)) {
                    $options[$key] = $definition->get($key);
                }
            }
            $options = ['description' => ((string) ($definition->get('description') ?? 'WP-Cron event')) . ' (no longer scheduled)'] + $options;
            try {
                $cw->job($stored->name, $options);
            } catch (\Throwable $error) {
                self::report($error, "job {$stored->name}");
            }
        }
        return $cw->check();
    }

    /** The check event's callback. */
    public static function runCheck(): void
    {
        try {
            self::check();
        } catch (\Throwable $error) {
            self::report($error, 'check');
        }
    }
}
