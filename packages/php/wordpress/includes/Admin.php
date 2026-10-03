<?php

declare(strict_types=1);

namespace Cronwatch\WordPress;

\defined('ABSPATH') || exit;

use Cronwatch\Alert;
use Cronwatch\Alerts\ChannelContext;
use Cronwatch\Bridge\ChannelSettings;
use Cronwatch\Duration;
use Cronwatch\Js;
use Cronwatch\JobDefinition;

/**
 * The CronWatch menu in wp-admin: the dashboard (AdminDashboard) and
 * CronWatch, Settings: where alerts go, the grace a run is given, a test
 * alert, the JSON API for @cronwatch/mcp (off unless turned on with a
 * token), and the watched events' health. Every page and action checks the
 * manage_options capability, and every action a nonce.
 */
final class Admin
{
    public const PAGE = 'cronwatch-settings';
    /** The least a token the owner types in may be; one the plugin makes is 40. */
    public const TOKEN_MIN = 24;
    /** What an API token typed in may hold. */
    public const TOKEN_PATTERN = '/^[A-Za-z0-9._~+\/=-]{24,200}$/D';

    public static function register(): void
    {
        add_action('admin_menu', [self::class, 'menu']);
        add_action('admin_post_cronwatch_save', [self::class, 'save']);
        add_action('admin_post_cronwatch_test', [self::class, 'test']);
        add_action('admin_enqueue_scripts', [AdminDashboard::class, 'styles']);
    }

    public static function menu(): void
    {
        $hook = add_menu_page(__('CronWatch', 'cronwatch'), __('CronWatch', 'cronwatch'), 'manage_options', AdminDashboard::PAGE, [AdminDashboard::class, 'render'], 'dashicons-clock', 80);
        add_submenu_page(AdminDashboard::PAGE, __('CronWatch', 'cronwatch'), __('Dashboard', 'cronwatch'), 'manage_options', AdminDashboard::PAGE, [AdminDashboard::class, 'render']);
        add_submenu_page(AdminDashboard::PAGE, __('CronWatch settings', 'cronwatch'), __('Settings', 'cronwatch'), 'manage_options', self::PAGE, [self::class, 'render']);
        if (is_string($hook) && $hook !== '') {
            // The dashboard's own pages (?cw=) are answered before wp-admin writes anything.
            add_action("load-{$hook}", [AdminDashboard::class, 'load']);
        }
    }

    private static function pageUrl(array $query = []): string
    {
        return add_query_arg(['page' => self::PAGE] + $query, admin_url('admin.php'));
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
        // authorize(), written out, so the nonce check sits where the form is read.
        if (!current_user_can('manage_options')) {
            wp_die(esc_html__('Sorry, you are not allowed to change CronWatch settings.', 'cronwatch'), 403);
        }
        check_admin_referer('cronwatch_save');
        // Each field is sanitized by saveSettings(), by its kind: an email list, a URL, a duration, a token.
        $posted = isset($_POST['cronwatch']) && is_array($_POST['cronwatch']) ? wp_unslash($_POST['cronwatch']) : []; // phpcs:ignore WordPress.Security.ValidatedSanitizedInput.InputNotSanitized -- sanitized field by field in saveSettings().
        $notice = self::saveSettings($posted);
        wp_safe_redirect(self::pageUrl(['cronwatch_notice' => $notice]));
        exit;
    }

    /**
     * Sanitizes and saves the posted settings. Returns the notice to show:
     * "saved", or the fields refused, joined by "-" in this order: "grace"
     * when the grace did not parse, "secret" when a webhook secret typed in
     * held a control character, "token" when a token typed in was refused,
     * "channels" when another channel is only partly filled in or refused
     * (its problems kept for the page to show; it sends nothing until they
     * are fixed) ("grace-token" when two were; the rest is saved either way). A token the plugin makes is kept for the page to
     * show once.
     *
     * @param array<string, mixed> $posted
     */
    public static function saveSettings(array $posted): string
    {
        $old = Plugin::settings();
        $refused = [];
        $text = fn (string $key): string => isset($posted[$key]) && is_string($posted[$key]) ? trim($posted[$key]) : '';
        $emails = array_filter(array_map(fn (string $a) => sanitize_email(trim($a)), explode(',', $text('email_to'))), fn (string $a) => $a !== '' && is_email($a));
        $new = [
            'email_to' => implode(', ', $emails),
            'slack_webhook_url' => esc_url_raw($text('slack_webhook_url'), ['https']),
            'webhook_url' => esc_url_raw($text('webhook_url'), ['http', 'https']),
            'webhook_secret' => $old['webhook_secret'],
            'grace' => $old['grace'],
            'api_enabled' => !empty($posted['api_enabled']) ? '1' : '',
            'api_token' => $old['api_token'],
        ] + self::channelSettings($posted, $old, $refused);
        // The webhook's signing secret: never shown again, so left blank the saved one stays. One typed in is
        // saved exactly as typed, since the receiver signs with the same bytes (sanitize_text_field() would
        // escape "<", strip "%XX" and collapse spaces); one holding a control character is refused.
        $secret = isset($posted['webhook_secret']) && is_string($posted['webhook_secret']) ? $posted['webhook_secret'] : '';
        if (!empty($posted['webhook_secret_clear'])) {
            $new['webhook_secret'] = '';
        } elseif (Js::trim($secret) !== '') {
            if (preg_match('/[\x00-\x1F\x7F]/', $secret) === 1 || preg_match('//u', $secret) !== 1) {
                $refused[] = 'secret';
            } else {
                $new['webhook_secret'] = $secret;
            }
        }
        // The API's token: one typed in (never shown again), a new one made on request, or one made when the API is first turned on.
        $token = preg_replace('/\s+/', '', $text('api_token')) ?? '';
        if ($token !== '') {
            // Checked as typed, and saved as typed: letters, digits and . _ ~ + / = -, which
            // no sanitizing changes, so the token saved is the one the owner gives the client.
            if (preg_match(self::TOKEN_PATTERN, $token) === 1) {
                $new['api_token'] = $token;
            } else {
                $refused[] = 'token';
            }
        } elseif (!empty($posted['api_token_new']) || ($new['api_enabled'] === '1' && $new['api_token'] === '')) {
            $new['api_token'] = wp_generate_password(40, false);
            set_transient('cronwatch_new_token_' . get_current_user_id(), $new['api_token'], 600);
        }
        $grace = sanitize_text_field($text('grace'));
        if ($grace !== '') {
            try {
                Duration::parse($grace, 'grace');
                $new['grace'] = $grace;
            } catch (\Throwable) {
                $refused[] = 'grace';
            }
        }
        update_option(Plugin::SETTINGS, $new, false);
        Plugin::reset();
        $problems = ChannelSettings::problems(fn (string $key): string => (string) ($new[$key] ?? ''));
        if ($problems !== []) {
            set_transient('cronwatch_channels_' . get_current_user_id(), $problems, 600);
            $refused[] = 'channels';
        }
        // "grace" first, then "secret", "token" and "channels", as the page reads them.
        usort($refused, fn (string $a, string $b): int => array_search($a, self::REFUSALS, true) <=> array_search($b, self::REFUSALS, true));
        return $refused === [] ? 'saved' : implode('-', array_unique($refused));
    }

    /** What a save can refuse, in the order its notice names them. */
    private const REFUSALS = ['grace', 'secret', 'token', 'channels'];

    /**
     * The other channels' fields (ChannelSettings), each sanitized by its
     * kind. A secret is never shown again, so one left blank keeps the saved
     * one, and its "Remove it" box clears it; one typed in is saved exactly
     * as typed, unless it holds a control character, which is refused
     * ("secret") and the saved one kept.
     *
     * @param array<string, mixed> $posted
     * @param array<string, string> $old
     * @param list<string> $refused
     * @return array<string, string>
     */
    private static function channelSettings(array $posted, array $old, array &$refused): array
    {
        $new = [];
        foreach (ChannelSettings::providers() as $provider => $spec) {
            foreach ($spec['fields'] as $field => $f) {
                $key = "{$provider}_{$field}";
                $value = isset($posted[$key]) && is_string($posted[$key]) ? $posted[$key] : '';
                switch ($f['kind']) {
                    case 'secret':
                        $new[$key] = $old[$key] ?? '';
                        if (!empty($posted["{$key}_clear"])) {
                            $new[$key] = '';
                        } elseif (Js::trim($value) !== '') {
                            if (preg_match('/[\x00-\x1F\x7F]/', $value) === 1 || preg_match('//u', $value) !== 1) {
                                $refused[] = 'secret';
                            } else {
                                $new[$key] = Js::trim($value);
                            }
                        }
                        break;
                    case 'url':
                        $new[$key] = esc_url_raw(trim($value), ['https']);
                        break;
                    case 'choice':
                        $new[$key] = array_key_exists($value, $f['options'] ?? []) ? $value : '';
                        break;
                    default:
                        // A from address keeps its "Name <address>" form, which sanitize_text_field() would take for a tag.
                        $new[$key] = $field === 'from'
                            ? trim((string) preg_replace('/[\x00-\x1F\x7F]+/', ' ', wp_check_invalid_utf8($value)))
                            : sanitize_text_field($value);
                }
            }
        }
        return $new;
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
     * Sends a test alert where a real one would go: every channel the client
     * has, which with none set is the library's default, PHP's error log.
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
        foreach (Plugin::client()->alerts as $channel) {
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
        // A save that refused more than one field names each: "grace-token".
        $refused = array_intersect(explode('-', $notice), self::REFUSALS);
        if ($notice === 'saved') {
            echo '<div class="notice notice-success"><p>' . esc_html__('Settings saved.', 'cronwatch') . '</p></div>';
        } elseif ($refused !== []) {
            if (in_array('grace', $refused, true)) {
                echo '<div class="notice notice-error"><p>' . esc_html__('The grace was not a duration such as 10m or 1h30m, so it was left as it was. The rest was saved.', 'cronwatch') . '</p></div>';
            }
            if (in_array('secret', $refused, true)) {
                echo '<div class="notice notice-error"><p>' . esc_html__('A secret was not saved: it may not hold a line break, a tab or another control character. The saved one was kept, and the rest was saved.', 'cronwatch') . '</p></div>';
            }
            if (in_array('token', $refused, true)) {
                /* translators: %d: the least number of characters an API token may have. */
                echo '<div class="notice notice-error"><p>' . esc_html(sprintf(__('The API token was not saved: it needs at least %d characters, each a letter, a digit or one of . _ ~ + / = -. The rest was saved.', 'cronwatch'), self::TOKEN_MIN)) . '</p></div>';
            }
            if (in_array('channels', $refused, true)) {
                $problems = get_transient('cronwatch_channels_' . get_current_user_id());
                delete_transient('cronwatch_channels_' . get_current_user_id());
                echo '<div class="notice notice-warning"><p>' . esc_html__('Saved, but these channels send nothing until they are fixed:', 'cronwatch') . '</p><ul>';
                foreach (is_array($problems) ? $problems : [] as $problem) {
                    echo '<li>' . esc_html((string) $problem) . '</li>';
                }
                echo '</ul></div>';
            }
        } elseif ($notice === 'tested') {
            $results = get_transient('cronwatch_test_' . get_current_user_id());
            delete_transient('cronwatch_test_' . get_current_user_id());
            if (!is_array($results) || $results === []) {
                echo '<div class="notice notice-warning"><p>' . esc_html__('The test alert went nowhere: no alert channel is set up.', 'cronwatch') . '</p></div>';
            } elseif (count($results) === 1 && $results[0]['channel'] === 'console' && $results[0]['ok']) {
                echo '<div class="notice notice-warning"><p>' . esc_html__('No alert channel is set, so the test alert was written to the PHP error log, where alerts go until you set one up below.', 'cronwatch') . '</p></div>';
            } else {
                foreach ($results as $r) {
                    $class = $r['ok'] ? 'notice-success' : 'notice-error';
                    $line = $r['ok']
                        ? ($r['channel'] === 'console'
                            ? __('Written to the PHP error log.', 'cronwatch')
                            /* translators: %s: an alert channel's name, such as email or slack. */
                            : sprintf(__('Sent through %s.', 'cronwatch'), $r['channel']))
                        /* translators: 1: an alert channel's name, such as email or slack; 2: why sending failed. */
                        : sprintf(__('%1$s failed: %2$s', 'cronwatch'), $r['channel'], $r['message']);
                    if ($r['ok'] && $r['message'] !== '') {
                        // Sent, but a channel reported a partial failure (one recipient of several refused it, say): show it, as Drupal's form does.
                        $line .= ' ' . $r['message'];
                    }
                    echo '<div class="notice ' . esc_attr($class) . '"><p>' . esc_html($line) . '</p></div>';
                }
            }
        }

        $made = get_transient('cronwatch_new_token_' . get_current_user_id());
        if (is_string($made) && $made !== '') {
            delete_transient('cronwatch_new_token_' . get_current_user_id());
            echo '<div class="notice notice-info"><p>' . esc_html__('The new API token is below. Copy it now: it is not shown again.', 'cronwatch') . '</p><p><code>' . esc_html($made) . '</code></p></div>';
        }

        echo '<p>' . esc_html__('CronWatch records every WP-Cron event as it runs and alerts you when one is missed, fails, gets stuck or runs slow. WP-Cron only runs when someone visits the site, so for reliable checks run WP-Cron and the check from the system crontab (see the plugin\'s readme).', 'cronwatch') . '</p>';
        echo '<p><a class="button" href="' . esc_url(admin_url('admin.php?page=' . AdminDashboard::PAGE)) . '">' . esc_html__('Open the dashboard', 'cronwatch') . '</a> '
            . esc_html__('Each event\'s health, its last day and week, and every run with its output.', 'cronwatch') . '</p>';
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
        self::renderChannels($settings);

        echo '<h2>' . esc_html__('JSON API', 'cronwatch') . '</h2>';
        echo '<p>' . esc_html__('Off unless you turn it on. When on, CronWatch\'s JSON API (the jobs, their runs, silencing and the check) answers at the address below to anyone who sends the token, so an MCP server (@cronwatch/mcp) or a script can reach this site. The dashboard itself stays in wp-admin.', 'cronwatch') . '</p>';
        echo '<table class="form-table" role="presentation"><tbody>';
        /* translators: %s: the JSON API's base URL. */
        $base = sprintf(__('Base URL: %s', 'cronwatch'), Api::baseUrl());
        self::row('api_enabled', __('Allow the JSON API', 'cronwatch'), '<label><input type="checkbox" id="cronwatch-api_enabled" name="cronwatch[api_enabled]" value="1"' . checked($settings['api_enabled'], '1', false) . '> '
            . esc_html__('Answer API requests that carry the token', 'cronwatch') . '</label>', $base);
        $tokenHelp = $settings['api_token'] !== ''
            ? __('A token is saved. Leave blank to keep it, or type a new one.', 'cronwatch')
            /* translators: %d: the least number of characters an API token may have. */
            : sprintf(__('Leave blank and one is made when you turn the API on, or type one of at least %d letters, digits and . _ ~ + / = -.', 'cronwatch'), self::TOKEN_MIN);
        self::row('api_token', __('API token', 'cronwatch'), '<input type="password" class="regular-text" id="cronwatch-api_token" name="cronwatch[api_token]" value="" autocomplete="new-password">'
            . ($settings['api_token'] !== '' ? ' <label><input type="checkbox" name="cronwatch[api_token_new]" value="1"> ' . esc_html__('Make a new one', 'cronwatch') . '</label>' : ''), $tokenHelp);
        echo '</tbody></table>';
        if (Api::enabled($settings)) {
            echo '<p>' . esc_html__('Add it to Claude Code with:', 'cronwatch') . '</p><p><code>' . esc_html('claude mcp add cronwatch -e CRONWATCH_URL=' . Api::baseUrl() . ' -e CRONWATCH_TOKEN=<token> -- npx -y @cronwatch/mcp') . '</code></p>';
        }
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

    /**
     * The other channels, by section, each folded away until one of its
     * fields is set.
     *
     * @param array<string, string> $settings
     */
    private static function renderChannels(array $settings): void
    {
        $sections = [
            ChannelSettings::CHAT => __('Chat', 'cronwatch'),
            ChannelSettings::EMAIL => __('Email through a provider', 'cronwatch'),
            ChannelSettings::SMS => __('Text messages', 'cronwatch'),
            ChannelSettings::TRACKERS => __('Error trackers', 'cronwatch'),
        ];
        $intro = [
            ChannelSettings::EMAIL => __('Email to, above, already sends through the site\'s own mail. Use a provider when the site cannot send mail reliably.', 'cronwatch'),
        ];
        echo '<h2>' . esc_html__('More channels', 'cronwatch') . '</h2>';
        echo '<p>' . esc_html__('Each channel sends once all of its required fields are set. Keys and tokens are never shown again: leave one blank to keep it.', 'cronwatch') . '</p>';
        $providers = ChannelSettings::providers();
        foreach ($sections as $section => $title) {
            echo '<h3>' . esc_html($title) . '</h3>';
            if (isset($intro[$section])) {
                echo '<p>' . esc_html($intro[$section]) . '</p>';
            }
            foreach ($providers as $provider => $spec) {
                if ($spec['section'] !== $section) {
                    continue;
                }
                $set = false;
                foreach (array_keys($spec['fields']) as $field) {
                    $set = $set || ($settings["{$provider}_{$field}"] ?? '') !== '';
                }
                echo '<details class="cronwatch-channel"' . ($set ? ' open' : '') . '><summary><strong>' . esc_html($spec['label']) . '</strong>'
                    . ($set ? ' ' . esc_html__('(set)', 'cronwatch') : '') . '</summary>';
                echo '<table class="form-table" role="presentation"><tbody>';
                foreach ($spec['fields'] as $field => $f) {
                    $key = "{$provider}_{$field}";
                    $value = $settings[$key] ?? '';
                    $attrs = ' id="cronwatch-' . esc_attr($key) . '" name="cronwatch[' . esc_attr($key) . ']"';
                    $help = isset($f['help']) ? self::text($f['help']) : '';
                    switch ($f['kind']) {
                        case 'secret':
                            $input = '<input type="password" class="regular-text"' . $attrs . ' value="" autocomplete="new-password">';
                            if ($value !== '') {
                                $input .= ' <label><input type="checkbox" name="cronwatch[' . esc_attr($key) . '_clear]" value="1"> ' . esc_html__('Remove it', 'cronwatch') . '</label>';
                                $help = trim(__('One is saved. Leave blank to keep it.', 'cronwatch') . ' ' . $help);
                            }
                            break;
                        case 'choice':
                            $input = '<select' . $attrs . '>';
                            foreach ($f['options'] ?? [] as $option => $label) {
                                $input .= '<option value="' . esc_attr((string) $option) . '"' . selected($value, (string) $option, false) . '>' . esc_html(self::text($label)) . '</option>';
                            }
                            $input .= '</select>';
                            break;
                        default:
                            $input = '<input type="' . ($f['kind'] === 'url' ? 'url' : 'text') . '" class="regular-text"' . $attrs . ' value="' . esc_attr($value) . '">';
                    }
                    $label = self::text($f['label']) . ($f['required'] ? '' : ' ' . __('(optional)', 'cronwatch'));
                    self::row($key, $label, $input, $help);
                }
                echo '</tbody></table></details>';
            }
        }
    }

    /** A label or help line from ChannelSettings in the site's language (each written out, so it is found for translation). */
    private static function text(string $english): string
    {
        return match ($english) {
            'Webhook URL' => __('Webhook URL', 'cronwatch'),
            'API key' => __('API key', 'cronwatch'),
            'From' => __('From', 'cronwatch'),
            'To' => __('To', 'cronwatch'),
            'Server token' => __('Server token', 'cronwatch'),
            'Message stream' => __('Message stream', 'cronwatch'),
            'Region' => __('Region', 'cronwatch'),
            'Domain' => __('Domain', 'cronwatch'),
            'Access key ID' => __('Access key ID', 'cronwatch'),
            'Secret access key' => __('Secret access key', 'cronwatch'),
            'Account SID' => __('Account SID', 'cronwatch'),
            'Auth token' => __('Auth token', 'cronwatch'),
            'DSN' => __('DSN', 'cronwatch'),
            'Environment' => __('Environment', 'cronwatch'),
            'Site' => __('Site', 'cronwatch'),
            'Access token' => __('Access token', 'cronwatch'),
            'Release stage' => __('Release stage', 'cronwatch'),
            'Account ID' => __('Account ID', 'cronwatch'),
            'License key' => __('License key', 'cronwatch'),
            'US' => __('US', 'cronwatch'),
            'EU' => __('EU', 'cronwatch'),
            'A channel webhook, from the server\'s Settings, Integrations, Webhooks.' => __('A channel webhook, from the server\'s Settings, Integrations, Webhooks.', 'cronwatch'),
            'A sender address on a domain the provider has verified, such as CronWatch <alerts@example.com>.' => __('A sender address on a domain the provider has verified, such as CronWatch <alerts@example.com>.', 'cronwatch'),
            'One or more addresses, separated by commas.' => __('One or more addresses, separated by commas.', 'cronwatch'),
            'Such as production.' => __('Such as production.', 'cronwatch'),
            'Empty is the server\'s default transactional stream.' => __('Empty is the server\'s default transactional stream.', 'cronwatch'),
            'The sending domain, such as mg.example.com.' => __('The sending domain, such as mg.example.com.', 'cronwatch'),
            'The AWS region the from address is verified in, such as us-east-1.' => __('The AWS region the from address is verified in, such as us-east-1.', 'cronwatch'),
            'For an IAM user allowed ses:SendEmail.' => __('For an IAM user allowed ses:SendEmail.', 'cronwatch'),
            'A Twilio number such as +15005550006, or a messaging service SID (MG...).' => __('A Twilio number such as +15005550006, or a messaging service SID (MG...).', 'cronwatch'),
            'One or more numbers such as +15551110000, separated by commas. Recoveries are not texted.' => __('One or more numbers such as +15551110000, separated by commas. Recoveries are not texted.', 'cronwatch'),
            'The project\'s DSN, from its Client Keys.' => __('The project\'s DSN, from its Client Keys.', 'cronwatch'),
            'Such as datadoghq.eu. Empty is datadoghq.com.' => __('Such as datadoghq.eu. Empty is datadoghq.com.', 'cronwatch'),
            'A project token with the post_server_item scope.' => __('A project token with the post_server_item scope.', 'cronwatch'),
            'An ingest license key.' => __('An ingest license key.', 'cronwatch'),
            default => $english,
        };
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
            /* translators: %s: the error the database gave. */
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
            /* translators: %s: a length of time, such as 5 mins. */
            $ago = $job->lastRun === null ? '' : sprintf(__('%s ago', 'cronwatch'), human_time_diff((int) ($job->lastRun->startedAt / 1000), $now));
            $last = $job->lastRun === null ? '' : $job->lastRun->status . ', ' . $ago;
            $next = $job->nextExpectedAt === null ? '' : wp_date('Y-m-d H:i', (int) ($job->nextExpectedAt / 1000));
            echo '<tr><td><code>' . esc_html($job->name) . '</code><br><span class="description">' . esc_html((string) ($job->definition->get('description') ?? '')) . '</span></td><td>'
                . esc_html($job->health) . '</td><td>' . esc_html($last) . '</td><td>' . esc_html((string) $next) . '</td></tr>';
        }
        echo '</tbody></table>';
    }
}
