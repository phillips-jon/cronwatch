<?php

declare(strict_types=1);

namespace Cronwatch\Tests;

use Cronwatch\Env;
use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;

/**
 * Development and production are read as every port reads them:
 * CRONWATCH_ENV, then APP_ENV, then the port's own (WP_ENVIRONMENT_TYPE
 * here, in NODE_ENV's place in the SDK's env.test.ts), the first whose
 * value, trimmed, is not empty, lowercased, with the aliases.
 */
final class EnvTest extends TestCase
{
    private const VARIABLES = ['CRONWATCH_ENV', 'APP_ENV', 'WP_ENVIRONMENT_TYPE'];

    /** @var array<string, array{string|false, mixed, mixed}> */
    private array $saved = [];

    protected function setUp(): void
    {
        foreach (self::VARIABLES as $name) {
            $this->saved[$name] = [getenv($name), $_ENV[$name] ?? null, $_SERVER[$name] ?? null];
            self::set($name, null);
        }
        Env::setFallback(null);
    }

    protected function tearDown(): void
    {
        foreach ($this->saved as $name => [$env, $superEnv, $server]) {
            putenv($env === false ? $name : "{$name}={$env}");
            self::restore($_ENV, $name, $superEnv);
            self::restore($_SERVER, $name, $server);
        }
        Env::setFallback(null);
    }

    /** @param array<string, mixed> $array */
    private static function restore(array &$array, string $name, mixed $value): void
    {
        if ($value === null) {
            unset($array[$name]);
        } else {
            $array[$name] = $value;
        }
    }

    private static function set(string $name, ?string $value): void
    {
        putenv($value === null ? $name : "{$name}={$value}");
        unset($_ENV[$name], $_SERVER[$name]);
    }

    /** @return iterable<string, array{?string, ?string, ?string, string}> CRONWATCH_ENV, APP_ENV, WP_ENVIRONMENT_TYPE, what they read as */
    public static function cases(): iterable
    {
        yield 'none set' => [null, null, null, 'none'];
        yield 'own development' => [null, null, 'development', 'development'];
        yield 'own test' => [null, null, 'test', 'development'];
        yield 'own production' => [null, null, 'production', 'production'];
        yield 'APP_ENV before own' => [null, 'local', 'production', 'development'];
        yield 'CRONWATCH_ENV first' => ['production', 'dev', 'development', 'production'];
        yield 'staging is neither' => ['staging', null, 'development', 'neither'];
        yield 'trimmed and lowercased' => ['  PROD ', null, null, 'production'];
        yield 'Testing' => [null, 'Testing', null, 'development'];
        yield 'DEV' => [null, 'DEV', null, 'development'];
        yield 'empty and blank are unset' => ['', '   ', 'production', 'production'];
        yield 'blank alone is none' => [" \t", null, null, 'none'];
    }

    #[DataProvider('cases')]
    public function testTheEnvironmentIsReadAsEveryPortReadsIt(?string $cronwatch, ?string $app, ?string $own, string $expected): void
    {
        self::set('CRONWATCH_ENV', $cronwatch);
        self::set('APP_ENV', $app);
        self::set('WP_ENVIRONMENT_TYPE', $own);
        $read = match (true) {
            Env::isDevelopment() => 'development',
            Env::isProduction() => 'production',
            Env::environment() === null => 'none',
            default => 'neither',
        };
        $this->assertSame($expected, $read);
    }

    public function testAFrameworksFallbackIsReadWhenEveryVariableIsBlank(): void
    {
        self::set('APP_ENV', '  ');
        Env::setFallback(fn () => ' Local ');
        $this->assertTrue(Env::isDevelopment());
    }
}
