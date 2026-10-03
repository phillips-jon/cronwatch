<?php

declare(strict_types=1);

namespace Cronwatch\Tests;

use Cronwatch\Alerts\AlertChannel;
use Cronwatch\Bridge\ChannelSettings;
use PHPUnit\Framework\TestCase;

/**
 * The channels the WordPress, Drupal and Craft settings pages offer beyond
 * their own email, Slack and webhook: the settings' names, what a form
 * refuses, and the channels made from what it saved.
 */
final class ChannelSettingsTest extends TestCase
{
    /** @param array<string, string> $values */
    private static function get(array $values): \Closure
    {
        return fn (string $key): string => $values[$key] ?? '';
    }

    public function testEverySettingIsNamedAfterItsProviderAndField(): void
    {
        $defaults = ChannelSettings::defaults();
        $this->assertSame('', $defaults['discord_webhook_url']);
        $this->assertArrayHasKey('ses_secret_access_key', $defaults);
        $this->assertArrayHasKey('newrelic_license_key', $defaults);
        $this->assertSame(['discord', 'resend', 'postmark', 'sendgrid', 'mailgun', 'ses', 'twilio', 'sentry', 'honeybadger', 'datadog', 'rollbar', 'bugsnag', 'newrelic'], array_keys(ChannelSettings::providers()));
        $this->assertSame('sesSecretAccessKey', ChannelSettings::camel('ses_secret_access_key'));
        $this->assertSame('discordWebhookUrl', ChannelSettings::camel('discord_webhook_url'));
    }

    public function testNothingSetIsNoChannelAndNoProblem(): void
    {
        $this->assertSame([], ChannelSettings::channels(self::get([])));
        $this->assertSame([], ChannelSettings::problems(self::get([])));
    }

    public function testAProviderPartlyFilledInIsRefusedAndLeftOff(): void
    {
        $values = ['resend_api_key' => 're_123', 'resend_to' => 'ops@example.com'];
        $this->assertSame(['resend_from' => 'Resend: From is required, or clear the other Resend fields to turn it off.'], ChannelSettings::problems(self::get($values)));
        $this->assertSame([], ChannelSettings::channels(self::get($values)));

        $problems = ChannelSettings::problems(self::get(['ses_from' => 'a@example.com']));
        $this->assertSame('Amazon SES: Region is required, or clear the other Amazon SES fields to turn it off.', $problems['ses_region']);
        $this->assertSame('Amazon SES: Access key ID is required, or clear the other Amazon SES fields to turn it off.', $problems['ses_access_key_id']);
        $this->assertArrayHasKey('ses_to', $problems);
    }

    public function testWhatAChannelRefusesIsShownBesideItsFirstField(): void
    {
        $problems = ChannelSettings::problems(self::get(['newrelic_account_id' => 'abc', 'newrelic_license_key' => 'k']));
        $this->assertSame(['newrelic_account_id' => 'NewRelic needs a numeric accountId'], $problems);
        $this->assertSame(['discord_webhook_url' => 'Enter an http or https URL.'], ChannelSettings::problems(self::get(['discord_webhook_url' => 'discord.com/api/webhooks/1/x'])));
        $this->assertSame(['sendgrid_region' => "SendGrid: Region is not one of the choices."], ChannelSettings::problems(self::get([
            'sendgrid_api_key' => 'k', 'sendgrid_from' => 'a@example.com', 'sendgrid_to' => 'b@example.com', 'sendgrid_region' => 'mars',
        ])));
    }

    public function testEachCompleteProviderIsAChannelInOrder(): void
    {
        $values = [
            'newrelic_account_id' => '1234567', 'newrelic_license_key' => 'nr', 'newrelic_region' => 'eu',
            'discord_webhook_url' => ' https://discord.com/api/webhooks/1/x ',
            'resend_api_key' => 're_123', 'resend_from' => 'CronWatch <alerts@example.com>', 'resend_to' => 'ops@example.com, , dev@example.com',
            'twilio_account_sid' => 'AC123', 'twilio_auth_token' => 't', 'twilio_from' => 'MG123', 'twilio_to' => '+15551110000',
            'sentry_dsn' => 'https://key@o1.ingest.sentry.io/2',
        ];
        $channels = ChannelSettings::channels(self::get($values), fn () => 'https://example.com/cw', '[Site]');
        $this->assertSame(['discord', 'resend', 'twilio', 'sentry', 'newrelic'], array_map(fn (AlertChannel $c) => $c->name(), $channels));
        $this->assertSame([], ChannelSettings::problems(self::get($values)));
    }

    public function testAChannelThatCannotBeMadeIsReportedAndLeftOut(): void
    {
        $errors = [];
        $channels = ChannelSettings::channels(
            self::get(['newrelic_account_id' => 'abc', 'newrelic_license_key' => 'k', 'rollbar_access_token' => 'r']),
            onError: function (\Throwable $e) use (&$errors): void {
                $errors[] = $e->getMessage();
            },
        );
        $this->assertSame(['rollbar'], array_map(fn (AlertChannel $c) => $c->name(), $channels));
        $this->assertSame(['CronWatch could not use New Relic: NewRelic needs a numeric accountId'], $errors);
    }
}
