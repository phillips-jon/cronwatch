<?php

declare(strict_types=1);

namespace Cronwatch\Laravel;

use Cronwatch\FromEnv;
use Cronwatch\Alert;
use Cronwatch\Alerts\AlertChannel;
use Cronwatch\Alerts\Discord;
use Cronwatch\Alerts\Slack;
use Cronwatch\Alerts\Webhook;
use Cronwatch\Cronwatch;
use Cronwatch\Store\MemoryStore;
use Cronwatch\Store\Migrated;
use Cronwatch\Store\SqliteStore;
use Cronwatch\Store\Store;
use Cronwatch\Triage\Anthropic;
use Illuminate\Contracts\Container\Container;

/**
 * The client, from config/cronwatch.php: the store, the alert channels,
 * triage and the client's options. The service provider binds the client
 * this makes as a singleton; an app that wants to build its own binds
 * Cronwatch\Cronwatch again in its own service provider's register().
 */
final class ClientFactory
{
    public function __construct(private readonly Container $app)
    {
    }

    /** @return array<string, mixed> */
    private function config(): array
    {
        $config = $this->app->make('config')->get('cronwatch', []);
        return is_array($config) ? $config : [];
    }

    public function client(): Cronwatch
    {
        $config = $this->config();
        $secret = $config['cron_secret'] ?? null;
        $triage = $config['triage'] ?? [];
        return new Cronwatch(
            store: $this->store(),
            alerts: $this->alerts(),
            triage: !empty($triage['enabled']) ? new Anthropic(
                model: is_string($triage['model'] ?? null) && $triage['model'] !== '' ? $triage['model'] : null,
                context: is_string($triage['context'] ?? null) && $triage['context'] !== '' ? $triage['context'] : null,
            ) : null,
            // false in the config turns the secret off; unset reads CRON_SECRET.
            cronSecret: $secret === false ? null : (is_string($secret) && $secret !== '' ? $secret : FromEnv::Read),
            retention: $config['retention'] ?? '30d',
            defaults: is_array($config['defaults'] ?? null) ? $config['defaults'] : [],
            deliver: is_string($config['deliver'] ?? null) ? $config['deliver'] : 'now',
            onError: $this->report(...),
        );
    }

    /** onError: the app's log, with the exception for its context. */
    public function report(\Throwable $error, string $where): void
    {
        $this->app->make('log')->error("[cronwatch] {$where}: " . get_class($error) . ': ' . $error->getMessage(), ['exception' => $error]);
    }

    /**
     * The store config/cronwatch.php names. `ignoreCreateTables` gives the
     * store itself, for the migration, even when create_tables is off.
     * The table prefix and create_tables are read through Settings, which
     * still takes their pre-1.0 keys under `store`.
     */
    public function store(bool $ignoreCreateTables = false): Store
    {
        $config = $this->config()['store'] ?? [];
        $settings = $this->app->make('config');
        $prefix = Settings::tablePrefix($settings);
        $driver = is_string($config['driver'] ?? null) ? $config['driver'] : 'database';
        $store = match ($driver) {
            'database' => DatabaseStore::make($this->app->make('db'), is_string($config['connection'] ?? null) && $config['connection'] !== '' ? $config['connection'] : null, $prefix),
            'sqlite' => new SqliteStore(is_string($config['path'] ?? null) && $config['path'] !== '' ? $config['path'] : self::storagePath('cronwatch/cronwatch.db'), prefix: $prefix),
            'memory' => new MemoryStore(),
            default => throw new \InvalidArgumentException("cronwatch.store.driver must be database, sqlite or memory, not {$driver}"),
        };
        if (!$ignoreCreateTables && !Settings::createTables($settings) && !$store instanceof MemoryStore) {
            return new Migrated($store);
        }
        return $store;
    }

    private static function storagePath(string $path): string
    {
        return function_exists('storage_path') ? storage_path($path) : $path;
    }

    /** @return list<AlertChannel|callable> */
    public function alerts(): array
    {
        $config = $this->config()['alerts'] ?? [];
        $link = $this->link();
        $channels = [];
        $mail = $config['mail'] ?? [];
        if (is_array($mail) && self::filled($mail['to'] ?? null)) {
            $channels[] = new MailChannel(
                $this->app->make('mail.manager'),
                $mail['to'],
                self::filled($mail['from'] ?? null) ? (string) $mail['from'] : null,
                self::filled($mail['mailer'] ?? null) ? (string) $mail['mailer'] : null,
                self::filled($mail['subject_prefix'] ?? null) ? (string) $mail['subject_prefix'] : null,
                $link,
            );
        }
        if (self::filled($config['slack'] ?? null)) {
            $channels[] = new Slack((string) $config['slack'], $link);
        }
        if (self::filled($config['discord'] ?? null)) {
            $channels[] = new Discord((string) $config['discord'], $link);
        }
        $webhook = $config['webhook'] ?? [];
        if (is_array($webhook) && self::filled($webhook['url'] ?? null)) {
            $channels[] = new Webhook((string) $webhook['url'], secret: self::filled($webhook['secret'] ?? null) ? (string) $webhook['secret'] : null);
        }
        foreach ((array) ($config['channels'] ?? []) as $channel) {
            $channels[] = is_string($channel) ? $this->app->make($channel) : $channel;
        }
        $log = $config['log'] ?? null;
        if (self::filled($log) || $channels === []) {
            $channels[] = new LogChannel($this->app->make('log'), self::filled($log) ? (string) $log : null);
        }
        return $channels;
    }

    /**
     * A link to the job's page in the dashboard, for the channels that show
     * one, when the dashboard is mounted. It starts from app.url (or the
     * dashboard's domain, in app.url's scheme), never from the request that
     * happens to send the alert, whose Host header a visitor chooses.
     */
    private function link(): ?\Closure
    {
        $dashboard = $this->config()['dashboard'] ?? [];
        if (!is_array($dashboard) || empty($dashboard['enabled'])) {
            return null;
        }
        $base = rtrim(trim((string) $this->app->make('config')->get('app.url', '')), '/');
        $domain = $dashboard['domain'] ?? null;
        if (is_string($domain) && trim($domain) !== '' && !str_contains($domain, '{')) {
            $scheme = parse_url($base, PHP_URL_SCHEME);
            $base = (is_string($scheme) && $scheme !== '' ? $scheme : 'https') . '://' . trim($domain, " \t/");
        }
        if ($base === '') {
            return null;
        }
        $path = trim((string) ($dashboard['path'] ?? 'cronwatch'), '/');
        return fn (Alert $alert): string => $base . '/' . ($path === '' ? '' : "{$path}/") . 'jobs/' . rawurlencode($alert->job);
    }

    private static function filled(mixed $value): bool
    {
        return (is_string($value) && trim($value) !== '') || (is_array($value) && $value !== []);
    }
}
