<?php

declare(strict_types=1);

namespace Cronwatch\Craft\models;

use Cronwatch\Bridge\ChannelSettings;
use Cronwatch\Duration;
use craft\base\Model;
use craft\helpers\App;

/**
 * The plugin's settings: the Control Panel's form sets the channels and the
 * grace, and config/cronwatch.php sets anything (it wins over the form, as
 * every plugin's config file does), including what only it can hold: the
 * console commands and queue jobs to watch, with their options. Every
 * string may name an environment variable ("$SLACK_WEBHOOK_URL"), so a
 * credential need not be in project config.
 */
final class Settings extends Model
{
    /** Where email alerts go, comma separated. Sent through Craft's mailer. */
    public string $emailTo = '';

    public string $slackWebhookUrl = '';

    public string $webhookUrl = '';

    /** When set, webhook requests are signed (X-CronWatch-Signature). */
    public string $webhookSecret = '';

    /*
     * Discord, the email providers, Twilio, and the error trackers: each
     * setting of ChannelSettings in camel case (discord_webhook_url is
     * discordWebhookUrl). A provider sends once its required fields are set.
     */

    // Discord
    public string $discordWebhookUrl = '';

    // Resend
    public string $resendApiKey = '';
    public string $resendFrom = '';
    public string $resendTo = '';

    // Postmark
    public string $postmarkServerToken = '';
    public string $postmarkFrom = '';
    public string $postmarkTo = '';
    public string $postmarkMessageStream = '';

    // SendGrid
    public string $sendgridApiKey = '';
    public string $sendgridFrom = '';
    public string $sendgridTo = '';
    public string $sendgridRegion = '';

    // Mailgun
    public string $mailgunApiKey = '';
    public string $mailgunDomain = '';
    public string $mailgunFrom = '';
    public string $mailgunTo = '';
    public string $mailgunRegion = '';

    // Amazon SES
    public string $sesRegion = '';
    public string $sesAccessKeyId = '';
    public string $sesSecretAccessKey = '';
    public string $sesFrom = '';
    public string $sesTo = '';

    // Twilio
    public string $twilioAccountSid = '';
    public string $twilioAuthToken = '';
    public string $twilioFrom = '';
    public string $twilioTo = '';

    // Sentry
    public string $sentryDsn = '';
    public string $sentryEnvironment = '';

    // Honeybadger
    public string $honeybadgerApiKey = '';
    public string $honeybadgerEnvironment = '';

    // Datadog
    public string $datadogApiKey = '';
    public string $datadogSite = '';

    // Rollbar
    public string $rollbarAccessToken = '';
    public string $rollbarEnvironment = '';

    // Bugsnag
    public string $bugsnagApiKey = '';
    public string $bugsnagReleaseStage = '';

    // New Relic
    public string $newrelicAccountId = '';
    public string $newrelicLicenseKey = '';
    public string $newrelicRegion = '';

    /** How late a run may be before it is reported missed. */
    public string $grace = '10m';

    /**
     * Console commands to watch, by route, each with its job's options
     * (schedule, timezone, grace, timeout, expect, name, ...), or true:
     *
     *     'commands' => [
     *         'resave/entries' => ['schedule' => '0 3 * * *'],
     *         'app/reports/send' => ['schedule' => '*\/15 * * * *', 'name' => 'send-reports'],
     *     ],
     *
     * @var array<string, array<string, mixed>|bool>
     */
    public array $commands = [];

    /**
     * Queue job classes to watch (besides those marked #[Cronwatch\Watch]),
     * each with its job's options, or true.
     *
     * @var array<string, array<string, mixed>|bool>
     */
    public array $queueJobs = [];

    /** The JSON API's token, for @cronwatch/mcp; empty turns the API off (unless CRONWATCH_TOKEN is set). */
    public string $apiToken = '';

    /** A setting with an environment variable ("$NAME" or "${NAME}") read. */
    public function value(string $name): string
    {
        $value = App::parseEnv((string) $this->{$name});
        return is_string($value) ? trim($value) : '';
    }

    protected function defineRules(): array
    {
        return [
            [['emailTo', 'slackWebhookUrl', 'webhookUrl', 'webhookSecret', 'grace', 'apiToken', ...self::channelAttributes()], 'string'],
            [['grace'], 'required'],
            [['grace'], function (string $attribute): void {
                try {
                    Duration::parse($this->value($attribute), 'grace');
                } catch (\Throwable $error) {
                    $this->addError($attribute, $error->getMessage());
                }
            }],
            [['slackWebhookUrl', 'webhookUrl'], function (string $attribute): void {
                $url = $this->value($attribute);
                if ($url !== '' && preg_match('#^https?://[^/\s]+#i', $url) !== 1) {
                    $this->addError($attribute, 'Enter an http or https URL.');
                }
            }],
            // Each provider partly filled in, or refused by its channel, named beside its field (checked once, on the first).
            [[self::channelAttributes()[0]], function (): void {
                foreach (ChannelSettings::problems(fn (string $key): string => $this->value(ChannelSettings::camel($key))) as $key => $message) {
                    $this->addError(ChannelSettings::camel($key), $message);
                }
            }, 'skipOnEmpty' => false],
        ];
    }

    /**
     * The other channels' settings, as this model names them.
     *
     * @return list<string>
     */
    public static function channelAttributes(): array
    {
        return array_map(ChannelSettings::camel(...), array_keys(ChannelSettings::defaults()));
    }
}
