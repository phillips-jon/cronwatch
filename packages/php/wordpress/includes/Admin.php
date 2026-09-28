<?php

declare(strict_types=1);

namespace Cronwatch\WordPress;

\defined('ABSPATH') || exit;

use Cronwatch\Alert;
use Cronwatch\Alerts\AlertChannel;
use Cronwatch\Alerts\ChannelContext;
use Cronwatch\Alerts\Custom;
use Cronwatch\Duration;
use Cronwatch\JobDefinition;

/**
 * Tools > CronWatch: where alerts go, the grace a run is given, a test
 * alert, and the watched events' health. Every action checks the
 * manage_options capability and a nonce. The full dashboard comes to
 * wp-admin in a later release.
 */
final class Admin
{
    public const PAGE = 'cronwatch';

    public static function register(): void
    {
        add_action('admin_menu', [self::class, 'menu']);
        add_action('admin_post_cronwatch_save', [self::class, 'save']);
        add_action('admin_post_cronwatch_test', [self::class, 'test']);
    }

    public static function menu(): void
    {
        add_management_page(__('CronWatch', 'cronwatch'), __('CronWatch', 'cronwatch'), 'manage_options', self::PAGE, [self::class, 'render']);
    }

    private static function pageUrl(array $query = []): string
    {
        return add_query_arg(['page' => self::PAGE] + $query, admin_url('tools.php'));
    }

    /** Stops unless the user may manage options and the request carries this action's nonce. */
    public static function authorize(string $action): void
    {
        if (!current_user_can('manage_options')) {
            wp_die(esc_html__('Sorry, you are not allowed to change CronWatch settings.', 'cronwatch'), 403);
        }
        check_admin_referer($action);
    }

    /** admin-post.php?action=cronwatch_save */
    public static function save(): void
    {
        self::authorize('cronwatch_save');
        // Each field is sanitized in saveSettings().
        $posted = isset($_POST['cronwatch']) && is_array($_POST['cronwatch']) ? wp_unslash($_POST['cronwatch']) : []; // phpcs:ignore WordPress.Security.ValidatedSanitizedInput.InputNotSanitized
        $notice = self::saveSettings($posted);
        wp_safe_redirect(self::pageUrl(['cronwatch_notice' => $notice]));
        exit;
    }

    /**
     * Sanitizes and saves the posted settings. Returns the notice to show:
     * "saved", or "grace" when the grace did not parse (the rest is saved).
     *
     * @param array<string, mixed> $posted
     */
    public static function saveSettings(array $posted): string
    {
        $old = Plugin::settings();
        $text = fn (string $key): string => isset($posted[$key]) && is_string($posted[$key]) ? trim($posted[$key]) : '';
        $emails = array_filter(array_map(fn (string $a) => sanitize_email(trim($a)), explode(',', $text('email_to'))), fn (string $a) => $a !== '' && is_email($a));
        $new = [
            'email_to' => implode(', ', $emails),
            'slack_webhook_url' => esc_url_raw($text('slack_webhook_url'), ['https']),
            'webhook_url' => esc_url_raw($text('webhook_url'), ['http', 'https']),
            // A secret is never shown again: left blank, the saved one stays.
            'webhook_secret' => !empty($posted['webhook_secret_clear']) ? '' : ($text('webhook_secret') !== '' ? sanitize_text_field($text('webhook_secret')) : $old['webhook_secret']),
            'grace' => $old['grace'],
        ];
        $notice = 'saved';
        $grace = sanitize_text_field($text('grace'));
        if ($grace !== '') {
            try {
                Duration::parse($grace, 'grace');
                $new['grace'] = $grace;
            } catch (\Throwable) {
                $notice = 'grace';
            }
        }
        update_option(Plugin::SETTINGS, $new, false);
        Plugin::reset();
        return $notice;
    }

    /** admin-post.php?action=cronwatch_test */
    public static function test(): void
    {
        self::authorize('cronwatch_test');
        $results = self::sendTest();
        set_transient('cronwatch_test_' . get_current_user_id(), $results, 120);
        wp_safe_redirect(self::pageUrl(['cronwatch_notice' => 'tested']));
        exit;
    }

    /**
     * Sends a test alert to every configured channel.
     *
     * @return list<array{channel: string, ok: bool, message: string}>
     */
    public static function sendTest(): array
    {
        $now = (int) floor(microtime(true) * 1000);
        $alert = new Alert(
            type: 'failed',
            run: null,
            details: [],
            job: 'cronwatch-test',
            definition: new JobDefinition(['name' => 'cronwatch-test']),
            title: 'CronWatch test alert',
            message: 'A test alert from ' . home_url() . '. If you can read this, CronWatch alerts reach you.',
            at: $now,
        );
        $results = [];
        foreach (Plugin::channels() as $channel) {
            $channel = $channel instanceof AlertChannel ? $channel : new Custom('custom', $channel);
            $problems = [];
            try {
                $channel->send($alert, new ChannelContext(function (\Throwable $e) use (&$problems): void {
                    $problems[] = $e->getMessage();
                }));
                $results[] = ['channel' => $channel->name(), 'ok' => true, 'message' => implode('; ', $problems)];
            } catch (\Throwable $error) {
                $results[] = ['channel' => $channel->name(), 'ok' => false, 'message' => $error->getMessage()];
            }
        }
        return $results;
    }

    public static function render(): void
    {
        if (!current_user_can('manage_options')) {
            wp_die(esc_html__('Sorry, you are not allowed to see this page.', 'cronwatch'), 403);
        }
        $settings = Plugin::settings();
        $notice = isset($_GET['cronwatch_notice']) ? sanitize_key(wp_unslash($_GET['cronwatch_notice'])) : ''; // phpcs:ignore WordPress.Security.NonceVerification.Recommended -- only picks which notice to show.
        echo '<div class="wrap"><h1>' . esc_html__('CronWatch', 'cronwatch') . '</h1>';
        if ($notice === 'saved') {
            echo '<div class="notice notice-success"><p>' . esc_html__('Settings saved.', 'cronwatch') . '</p></div>';
        } elseif ($notice === 'grace') {
            echo '<div class="notice notice-error"><p>' . esc_html__('The grace was not a duration such as 10m or 1h30m, so it was left as it was. The rest was saved.', 'cronwatch') . '</p></div>';
        } elseif ($notice === 'tested') {
            $results = get_transient('cronwatch_test_' . get_current_user_id());
            delete_transient('cronwatch_test_' . get_current_user_id());
            if (!is_array($results) || $results === []) {
                echo '<div class="notice notice-warning"><p>' . esc_html__('No alert channel is set, so the test alert went to the PHP error log only.', 'cronwatch') . '</p></div>';
            } else {
                foreach ($results as $r) {
                    $class = $r['ok'] ? 'notice-success' : 'notice-error';
                    $line = $r['ok'] ? sprintf(__('Sent through %s.', 'cronwatch'), $r['channel']) : sprintf(__('%1$s failed: %2$s', 'cronwatch'), $r['channel'], $r['message']);
                    echo '<div class="notice ' . esc_attr($class) . '"><p>' . esc_html($line) . '</p></div>';
                }
            }
        }

        echo '<p>' . esc_html__('CronWatch records every WP-Cron event as it runs and alerts you when one is missed, fails, gets stuck or runs slow. WP-Cron only runs when someone visits the site, so for reliable checks run WP-Cron and the check from the system crontab (see the plugin\'s readme). The full dashboard comes to wp-admin in a later release.', 'cronwatch') . '</p>';
        if (defined('DISABLE_WP_CRON') && DISABLE_WP_CRON) {
            echo '<p>' . esc_html__('DISABLE_WP_CRON is set: make sure a system cron runs wp-cron.php or `wp cron event run --due-now`, and `wp cronwatch check`.', 'cronwatch') . '</p>';
        }

        echo '<h2>' . esc_html__('Alerts', 'cronwatch') . '</h2>';
        echo '<p>' . esc_html__('Alerts are sent only where you set one up below. With none set they go to the PHP error log.', 'cronwatch') . '</p>';
        echo '<form method="post" action="' . esc_url(admin_url('admin-post.php')) . '">';
        echo '<input type="hidden" name="action" value="cronwatch_save">';
        wp_nonce_field('cronwatch_save');
        echo '<table class="form-table" role="presentation"><tbody>';
        self::row('email_to', __('Email to', 'cronwatch'), '<input type="text" class="regular-text" id="cronwatch-email_to" name="cronwatch[email_to]" value="' . esc_attr($settings['email_to']) . '" placeholder="' . esc_attr((string) get_option('admin_email')) . '">', __('One address or several, separated by commas. Sent with wp_mail(), the way the site sends its other mail.', 'cronwatch'));
        self::row('slack_webhook_url', __('Slack webhook URL', 'cronwatch'), '<input type="url" class="regular-text" id="cronwatch-slack_webhook_url" name="cronwatch[slack_webhook_url]" value="' . esc_attr($settings['slack_webhook_url']) . '">', __('An incoming webhook URL from api.slack.com/messaging/webhooks.', 'cronwatch'));
        self::row('webhook_url', __('Webhook URL', 'cronwatch'), '<input type="url" class="regular-text" id="cronwatch-webhook_url" name="cronwatch[webhook_url]" value="' . esc_attr($settings['webhook_url']) . '">', __('Each alert is POSTed there as JSON.', 'cronwatch'));
        $secret = $settings['webhook_secret'] !== '' ? __('A secret is saved. Leave blank to keep it.', 'cronwatch') : __('Optional. Each request is signed with it in the X-CronWatch-Signature header (HMAC-SHA256 of the body).', 'cronwatch');
        self::row('webhook_secret', __('Webhook secret', 'cronwatch'), '<input type="password" class="regular-text" id="cronwatch-webhook_secret" name="cronwatch[webhook_secret]" value="" autocomplete="new-password">'
            . ($settings['webhook_secret'] !== '' ? ' <label><input type="checkbox" name="cronwatch[webhook_secret_clear]" value="1"> ' . esc_html__('Remove it', 'cronwatch') . '</label>' : ''), $secret);
        self::row('grace', __('Grace', 'cronwatch'), '<input type="text" class="small-text" id="cronwatch-grace" name="cronwatch[grace]" value="' . esc_attr($settings['grace']) . '">', __('How late an event may run before it counts as missed, such as 10m or 1h.', 'cronwatch'));
        echo '</tbody></table>';
        submit_button(__('Save', 'cronwatch'));
        echo '</form>';

        echo '<form method="post" action="' . esc_url(admin_url('admin-post.php')) . '">';
        echo '<input type="hidden" name="action" value="cronwatch_test">';
        wp_nonce_field('cronwatch_test');
        submit_button(__('Send a test alert', 'cronwatch'), 'secondary');
        echo '</form>';

        self::renderJobs();
        echo '</div>';
    }

    private static function row(string $key, string $label, string $field, string $help): void
    {
        // $field is built above with every value escaped.
        echo '<tr><th scope="row"><label for="cronwatch-' . esc_attr($key) . '">' . esc_html($label) . '</label></th><td>'
            . $field // phpcs:ignore WordPress.Security.EscapeOutput.OutputNotEscaped
            . '<p class="description">' . esc_html($help) . '</p></td></tr>';
    }

    private static function renderJobs(): void
    {
        echo '<h2>' . esc_html__('Watched events', 'cronwatch') . '</h2>';
        try {
            $jobs = Plugin::client()->jobs();
        } catch (\Throwable $error) {
            echo '<p>' . esc_html(sprintf(__('The jobs could not be read: %s', 'cronwatch'), $error->getMessage())) . '</p>';
            return;
        }
        if ($jobs === []) {
            echo '<p>' . esc_html__('Nothing recorded yet. Events appear here once WP-Cron runs them or the first check has run.', 'cronwatch') . '</p>';
            return;
        }
        $now = time();
        echo '<table class="widefat striped"><thead><tr><th>' . esc_html__('Job', 'cronwatch') . '</th><th>' . esc_html__('Health', 'cronwatch') . '</th><th>'
            . esc_html__('Last run', 'cronwatch') . '</th><th>' . esc_html__('Next due', 'cronwatch') . '</th></tr></thead><tbody>';
        foreach ($jobs as $job) {
            $last = $job->lastRun === null ? '' : $job->lastRun->status . ', ' . sprintf(__('%s ago', 'cronwatch'), human_time_diff((int) ($job->lastRun->startedAt / 1000), $now));
            $next = $job->nextExpectedAt === null ? '' : wp_date('Y-m-d H:i', (int) ($job->nextExpectedAt / 1000));
            echo '<tr><td><code>' . esc_html($job->name) . '</code><br><span class="description">' . esc_html((string) ($job->definition->get('description') ?? '')) . '</span></td><td>'
                . esc_html($job->health) . '</td><td>' . esc_html($last) . '</td><td>' . esc_html((string) $next) . '</td></tr>';
        }
        echo '</tbody></table>';
    }
}
