<?php

declare(strict_types=1);

namespace Cronwatch\Bridge;

use Cronwatch\Alerts\AlertChannel;
use Cronwatch\Alerts\Bugsnag;
use Cronwatch\Alerts\Datadog;
use Cronwatch\Alerts\Discord;
use Cronwatch\Alerts\Honeybadger;
use Cronwatch\Alerts\Http;
use Cronwatch\Alerts\Mailgun;
use Cronwatch\Alerts\NewRelic;
use Cronwatch\Alerts\Postmark;
use Cronwatch\Alerts\Resend;
use Cronwatch\Alerts\Rollbar;
use Cronwatch\Alerts\Sendgrid;
use Cronwatch\Alerts\Sentry;
use Cronwatch\Alerts\Ses;
use Cronwatch\Alerts\Twilio;
use Cronwatch\Js;

/**
 * The channels a CMS settings page offers beyond its own email, Slack and
 * the webhook: Discord, the email providers, Twilio and the error trackers.
 * One list, so the WordPress, Drupal and Craft forms show the same fields
 * and make the same channels from them.
 *
 * Each setting is named "<provider>_<field>" (discord_webhook_url,
 * resend_api_key); Craft spells it in camel case (camel()). A provider is
 * on when every one of its required fields is set, and a form refuses (or,
 * in WordPress, warns about) one that is only partly filled in.
 *
 * Labels and help are English; each plugin translates them its own way.
 *
 * @internal For the CMS integrations.
 */
final class ChannelSettings
{
    /** The section each provider is shown in. */
    public const CHAT = 'chat';
    public const EMAIL = 'email';
    public const SMS = 'sms';
    public const TRACKERS = 'trackers';

    /**
     * Every provider, in the order the forms show them: its label, its
     * section, and its fields. A field has a label, a kind ("text", "url",
     * "secret", "list" for a comma-separated list, or "choice" with
     * options), whether it is required, and optional help.
     *
     * @return array<string, array{label: string, section: string, fields: array<string, array{label: string, kind: string, required: bool, help?: string, options?: array<string, string>}>}>
     */
    public static function providers(): array
    {
        $from = ['label' => 'From', 'kind' => 'text', 'required' => true, 'help' => 'A sender address on a domain the provider has verified, such as CronWatch <alerts@example.com>.'];
        $to = ['label' => 'To', 'kind' => 'list', 'required' => true, 'help' => 'One or more addresses, separated by commas.'];
        $region = ['label' => 'Region', 'kind' => 'choice', 'required' => false, 'options' => ['' => 'US', 'eu' => 'EU']];
        $environment = ['label' => 'Environment', 'kind' => 'text', 'required' => false, 'help' => 'Such as production.'];
        return [
            'discord' => ['label' => 'Discord', 'section' => self::CHAT, 'fields' => [
                'webhook_url' => ['label' => 'Webhook URL', 'kind' => 'url', 'required' => true, 'help' => 'A channel webhook, from the server\'s Settings, Integrations, Webhooks.'],
            ]],
            'resend' => ['label' => 'Resend', 'section' => self::EMAIL, 'fields' => [
                'api_key' => ['label' => 'API key', 'kind' => 'secret', 'required' => true],
                'from' => $from,
                'to' => $to,
            ]],
            'postmark' => ['label' => 'Postmark', 'section' => self::EMAIL, 'fields' => [
                'server_token' => ['label' => 'Server token', 'kind' => 'secret', 'required' => true],
                'from' => $from,
                'to' => $to,
                'message_stream' => ['label' => 'Message stream', 'kind' => 'text', 'required' => false, 'help' => 'Empty is the server\'s default transactional stream.'],
            ]],
            'sendgrid' => ['label' => 'SendGrid', 'section' => self::EMAIL, 'fields' => [
                'api_key' => ['label' => 'API key', 'kind' => 'secret', 'required' => true],
                'from' => $from,
                'to' => $to,
                'region' => $region,
            ]],
            'mailgun' => ['label' => 'Mailgun', 'section' => self::EMAIL, 'fields' => [
                'api_key' => ['label' => 'API key', 'kind' => 'secret', 'required' => true],
                'domain' => ['label' => 'Domain', 'kind' => 'text', 'required' => true, 'help' => 'The sending domain, such as mg.example.com.'],
                'from' => $from,
                'to' => $to,
                'region' => $region,
            ]],
            'ses' => ['label' => 'Amazon SES', 'section' => self::EMAIL, 'fields' => [
                'region' => ['label' => 'Region', 'kind' => 'text', 'required' => true, 'help' => 'The AWS region the from address is verified in, such as us-east-1.'],
                'access_key_id' => ['label' => 'Access key ID', 'kind' => 'secret', 'required' => true, 'help' => 'For an IAM user allowed ses:SendEmail.'],
                'secret_access_key' => ['label' => 'Secret access key', 'kind' => 'secret', 'required' => true],
                'from' => $from,
                'to' => $to,
            ]],
            'twilio' => ['label' => 'Twilio', 'section' => self::SMS, 'fields' => [
                'account_sid' => ['label' => 'Account SID', 'kind' => 'text', 'required' => true],
                'auth_token' => ['label' => 'Auth token', 'kind' => 'secret', 'required' => true],
                'from' => ['label' => 'From', 'kind' => 'text', 'required' => true, 'help' => 'A Twilio number such as +15005550006, or a messaging service SID (MG...).'],
                'to' => ['label' => 'To', 'kind' => 'list', 'required' => true, 'help' => 'One or more numbers such as +15551110000, separated by commas. Recoveries are not texted.'],
            ]],
            'sentry' => ['label' => 'Sentry', 'section' => self::TRACKERS, 'fields' => [
                'dsn' => ['label' => 'DSN', 'kind' => 'secret', 'required' => true, 'help' => 'The project\'s DSN, from its Client Keys.'],
                'environment' => $environment,
            ]],
            'honeybadger' => ['label' => 'Honeybadger', 'section' => self::TRACKERS, 'fields' => [
                'api_key' => ['label' => 'API key', 'kind' => 'secret', 'required' => true],
                'environment' => $environment,
            ]],
            'datadog' => ['label' => 'Datadog', 'section' => self::TRACKERS, 'fields' => [
                'api_key' => ['label' => 'API key', 'kind' => 'secret', 'required' => true],
                'site' => ['label' => 'Site', 'kind' => 'text', 'required' => false, 'help' => 'Such as datadoghq.eu. Empty is datadoghq.com.'],
            ]],
            'rollbar' => ['label' => 'Rollbar', 'section' => self::TRACKERS, 'fields' => [
                'access_token' => ['label' => 'Access token', 'kind' => 'secret', 'required' => true, 'help' => 'A project token with the post_server_item scope.'],
                'environment' => $environment,
            ]],
            'bugsnag' => ['label' => 'Bugsnag', 'section' => self::TRACKERS, 'fields' => [
                'api_key' => ['label' => 'API key', 'kind' => 'secret', 'required' => true],
                'release_stage' => ['label' => 'Release stage', 'kind' => 'text', 'required' => false, 'help' => 'Such as production.'],
            ]],
            'newrelic' => ['label' => 'New Relic', 'section' => self::TRACKERS, 'fields' => [
                'account_id' => ['label' => 'Account ID', 'kind' => 'text', 'required' => true],
                'license_key' => ['label' => 'License key', 'kind' => 'secret', 'required' => true, 'help' => 'An ingest license key.'],
                'region' => $region,
            ]],
        ];
    }

    /**
     * Every setting's name, each "" by default.
     *
     * @return array<string, string>
     */
    public static function defaults(): array
    {
        $defaults = [];
        foreach (self::providers() as $provider => $spec) {
            foreach (array_keys($spec['fields']) as $field) {
                $defaults["{$provider}_{$field}"] = '';
            }
        }
        return $defaults;
    }

    /** A setting's name as Craft spells it: resend_api_key is resendApiKey. */
    public static function camel(string $key): string
    {
        return lcfirst(str_replace(' ', '', ucwords(str_replace('_', ' ', $key))));
    }

    /**
     * What is wrong with the providers the settings start to fill in: each
     * required field left empty, then what a channel refused when made from
     * the rest (a from address without an @, say). Keyed by the setting to
     * show it beside. A provider with nothing set is off and has no problem.
     *
     * @param callable(string): string $get a setting's value, by its name
     * @return array<string, string>
     */
    public static function problems(callable $get): array
    {
        $problems = [];
        foreach (self::providers() as $provider => $spec) {
            $values = self::values($provider, $spec, $get);
            if (implode('', $values) === '') {
                continue;
            }
            $missing = false;
            foreach ($spec['fields'] as $field => $f) {
                if ($f['required'] && $values[$field] === '') {
                    $problems["{$provider}_{$field}"] = "{$spec['label']}: {$f['label']} is required, or clear the other {$spec['label']} fields to turn it off.";
                    $missing = true;
                } elseif ($f['kind'] === 'url' && $values[$field] !== '' && preg_match('#^https?://[^/\s]+#i', $values[$field]) !== 1) {
                    $problems["{$provider}_{$field}"] = 'Enter an http or https URL.';
                    $missing = true;
                } elseif ($f['kind'] === 'choice' && !array_key_exists($values[$field], $f['options'] ?? [])) {
                    $problems["{$provider}_{$field}"] = "{$spec['label']}: {$f['label']} is not one of the choices.";
                    $missing = true;
                }
            }
            if ($missing) {
                continue;
            }
            try {
                self::make($provider, $values, null, null, null);
            } catch (\Throwable $error) {
                $problems["{$provider}_" . array_key_first($spec['fields'])] = $error->getMessage();
            }
        }
        return $problems;
    }

    /**
     * The channels the settings turn on, in the providers' order. A provider
     * whose required fields are not all set is left out; one a channel
     * refuses to be made from is left out and reported to $onError.
     *
     * @param callable(string): string $get a setting's value, by its name
     * @param (callable(\Cronwatch\Alert): ?string)|null $link
     * @param (callable(\Throwable): void)|null $onError
     * @return list<AlertChannel>
     */
    public static function channels(callable $get, ?callable $link = null, ?string $subjectPrefix = null, ?Http $http = null, ?callable $onError = null): array
    {
        $channels = [];
        foreach (self::providers() as $provider => $spec) {
            $values = self::values($provider, $spec, $get);
            foreach ($spec['fields'] as $field => $f) {
                if ($f['required'] && $values[$field] === '') {
                    continue 2;
                }
            }
            try {
                $channels[] = self::make($provider, $values, $link, $subjectPrefix, $http);
            } catch (\Throwable $error) {
                if ($onError !== null) {
                    $onError(new \RuntimeException("CronWatch could not use {$spec['label']}: {$error->getMessage()}", 0, $error));
                }
            }
        }
        return $channels;
    }

    /**
     * @param array{label: string, section: string, fields: array<string, array<string, mixed>>} $spec
     * @return array<string, string>
     */
    private static function values(string $provider, array $spec, callable $get): array
    {
        $values = [];
        foreach (array_keys($spec['fields']) as $field) {
            $value = $get("{$provider}_{$field}");
            $values[$field] = is_string($value) ? Js::trim($value) : '';
        }
        return $values;
    }

    /**
     * @param array<string, string> $v
     */
    private static function make(string $provider, array $v, ?callable $link, ?string $prefix, ?Http $http): AlertChannel
    {
        $opt = fn (string $field): ?string => $v[$field] !== '' ? $v[$field] : null;
        $list = fn (string $field): array => array_values(array_filter(array_map(Js::trim(...), explode(',', $v[$field])), fn (string $a) => $a !== ''));
        return match ($provider) {
            'discord' => new Discord($v['webhook_url'], $link, $http),
            'resend' => new Resend($v['api_key'], $v['from'], $list('to'), $prefix, $link, $http),
            'postmark' => new Postmark($v['server_token'], $v['from'], $list('to'), $opt('message_stream'), $prefix, $link, $http),
            'sendgrid' => new Sendgrid($v['api_key'], $v['from'], $list('to'), $opt('region'), $prefix, $link, $http),
            'mailgun' => new Mailgun($v['api_key'], $v['domain'], $v['from'], $list('to'), $opt('region'), $prefix, $link, $http),
            'ses' => new Ses($v['region'], $v['access_key_id'], $v['secret_access_key'], $v['from'], $list('to'), subjectPrefix: $prefix, link: $link, http: $http),
            'twilio' => str_starts_with($v['from'], 'MG')
                ? new Twilio($v['account_sid'], $list('to'), authToken: $v['auth_token'], messagingServiceSid: $v['from'], link: $link, http: $http)
                : new Twilio($v['account_sid'], $list('to'), authToken: $v['auth_token'], from: $v['from'], link: $link, http: $http),
            'sentry' => new Sentry($v['dsn'], $opt('environment'), link: $link, http: $http),
            'honeybadger' => new Honeybadger($v['api_key'], $opt('environment'), link: $link, http: $http),
            'datadog' => new Datadog($v['api_key'], $opt('site'), link: $link, http: $http),
            'rollbar' => new Rollbar($v['access_token'], $opt('environment'), link: $link, http: $http),
            'bugsnag' => new Bugsnag($v['api_key'], $opt('release_stage'), link: $link, http: $http),
            'newrelic' => new NewRelic($v['account_id'], $v['license_key'], $opt('region'), link: $link, http: $http),
            default => throw new \InvalidArgumentException("No channel named {$provider}"),
        };
    }
}
