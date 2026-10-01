<?php

declare(strict_types=1);

namespace Cronwatch\Symfony;

use Cronwatch\FromEnv;
use Cronwatch\Alerts\AlertChannel;
use Cronwatch\Alerts\Discord;
use Cronwatch\Alerts\Slack;
use Cronwatch\Alerts\Webhook;
use Cronwatch\Cronwatch;
use Cronwatch\Env;
use Cronwatch\Store\ComparesAndSetsState;
use Cronwatch\Store\MemoryStore;
use Cronwatch\Store\Migrated;
use Cronwatch\Store\Store;
use Cronwatch\Store\UpdatesRunIf;
use Cronwatch\Triage\Anthropic;
use Psr\Log\LoggerInterface;

/**
 * The client, from config/packages/cronwatch.yaml: the store (a URL, or
 * the app's DATABASE_URL, or a SQLite file in var/), the alert channels,
 * triage and the client's options. The bundle makes the Cronwatch\Cronwatch
 * service with it; an app that wants to build its own defines that service
 * itself.
 *
 * @internal
 */
final class ClientFactory
{
    /**
     * @param array<string, mixed> $config the bundle's processed configuration
     * @param iterable<AlertChannel> $channels the services named in alerts.services
     */
    public static function client(
        array $config,
        string $projectDir,
        ?LoggerInterface $logger = null,
        ?object $mailer = null,
        iterable $channels = [],
        ?Store $store = null,
    ): Cronwatch {
        $triage = $config['triage'] ?? [];
        $secret = $config['cron_secret'] ?? null;
        $alerts = self::alerts($config, $logger, $mailer, $channels);
        return new Cronwatch(
            store: $store ?? self::store($config, $projectDir),
            // With no channel and no logger, the console (standard error, or PHP's error log).
            alerts: $alerts === [] ? null : $alerts,
            triage: !empty($triage['enabled']) ? new Anthropic(
                model: self::text($triage['model'] ?? null),
                context: self::text($triage['context'] ?? null),
            ) : null,
            // false in the config turns the secret off; unset reads CRON_SECRET.
            cronSecret: $secret === false ? null : (self::text($secret) ?? FromEnv::Read),
            retention: $config['retention'] ?? '30d',
            defaults: is_array($config['defaults'] ?? null) ? $config['defaults'] : [],
            deliver: (string) ($config['deliver'] ?? 'now'),
            onError: $logger === null ? null : function (\Throwable $error, string $where) use ($logger): void {
                $logger->error("[cronwatch] {$where}: " . get_class($error) . ': ' . $error->getMessage(), ['exception' => $error]);
            },
        );
    }

    /** @param array<string, mixed> $config */
    public static function store(array $config, string $projectDir): Store
    {
        $prefix = (string) ($config['table_prefix'] ?? 'cronwatch_');
        $url = self::text($config['store'] ?? null) ?? Env::read('DATABASE_URL');
        $store = $url !== null
            ? Stores::fromUrl($url, $prefix)
            : Stores::fromUrl('sqlite://' . rtrim($projectDir, '/') . '/var/cronwatch.db', $prefix);
        if (($config['create_tables'] ?? true) === false && !$store instanceof MemoryStore && $store instanceof UpdatesRunIf && $store instanceof ComparesAndSetsState) {
            return new Migrated($store);
        }
        return $store;
    }

    /**
     * @param array<string, mixed> $config
     * @param iterable<AlertChannel> $channels
     * @return list<AlertChannel>
     */
    private static function alerts(array $config, ?LoggerInterface $logger, ?object $mailer, iterable $channels): array
    {
        $alerts = $config['alerts'] ?? [];
        $out = [];
        $mail = $alerts['mailer'] ?? [];
        if (is_array($mail) && ($mail['to'] ?? []) !== [] && $mail['to'] !== null) {
            if ($mailer === null) {
                throw new \LogicException('cronwatch.alerts.mailer needs symfony/mailer (composer require symfony/mailer)');
            }
            $out[] = new MailerChannel($mailer, $mail['to'], (string) ($mail['from'] ?? ''), self::text($mail['subject_prefix'] ?? null));
        }
        if (($slack = self::text($alerts['slack'] ?? null)) !== null) {
            $out[] = new Slack($slack);
        }
        if (($discord = self::text($alerts['discord'] ?? null)) !== null) {
            $out[] = new Discord($discord);
        }
        $webhook = $alerts['webhook'] ?? [];
        if (is_array($webhook) && ($url = self::text($webhook['url'] ?? null)) !== null) {
            $out[] = new Webhook($url, secret: self::text($webhook['secret'] ?? null));
        }
        foreach ($channels as $channel) {
            $out[] = $channel;
        }
        if ($logger !== null && (!empty($alerts['log']) || $out === [])) {
            $out[] = new LoggerChannel($logger);
        }
        return $out;
    }

    private static function text(mixed $value): ?string
    {
        return is_string($value) && trim($value) !== '' ? $value : null;
    }
}
