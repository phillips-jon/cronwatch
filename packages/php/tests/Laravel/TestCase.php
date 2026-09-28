<?php

declare(strict_types=1);

namespace Cronwatch\Tests\Laravel;

use Cronwatch\Cronwatch;
use Cronwatch\Laravel\CronwatchServiceProvider;
use Cronwatch\Store\MemoryStore;
use Cronwatch\Tests\Support\Capture;
use Cronwatch\Tests\Support\Clock;

// The Laravel tests run on Orchestra Testbench, which the CI entries for
// each supported Laravel install (see DESIGN.md); without it they are
// skipped, so the core suite runs on its own.
if (class_exists(\Orchestra\Testbench\TestCase::class)) {
    require_once __DIR__ . '/Fixtures/Jobs.php';

    /**
     * A Laravel app with the package discovered as an app would find it,
     * CronWatch's store in memory unless a test says otherwise, and helpers
     * to swap in a client on a test clock that captures its alerts.
     */
    abstract class TestCase extends \Orchestra\Testbench\TestCase
    {
        protected Clock $clock;
        protected Capture $capture;
        /** @var list<array{\Throwable, string}> */
        protected array $errors = [];

        protected function getPackageProviders($app): array
        {
            return [CronwatchServiceProvider::class];
        }

        protected function tearDown(): void
        {
            parent::tearDown();
            // The provider names the app's environment as the fallback; the next test's app is another.
            \Cronwatch\Env::setFallback(null);
        }

        protected function defineEnvironment($app): void
        {
            $app['config']->set('cronwatch.store.driver', 'memory');
            $app['config']->set('app.timezone', 'UTC');
        }

        /** A client on a test clock, capturing alerts and errors, bound as the app's. */
        protected function client(array $options = []): Cronwatch
        {
            $this->clock ??= new Clock();
            $this->capture = new Capture();
            $this->errors = [];
            $cw = new Cronwatch(...array_replace([
                'store' => new MemoryStore(),
                'now' => $this->clock,
                'alerts' => [$this->capture],
                'cronSecret' => false,
                'onError' => function (\Throwable $error, string $where): void {
                    $this->errors[] = [$error, $where];
                },
            ], $options));
            $this->app->instance(Cronwatch::class, $cw);
            return $cw;
        }

        /** @return list<string> */
        protected function wheres(): array
        {
            return array_map(fn (array $e) => $e[1], $this->errors);
        }

        /** @return list<string> */
        protected function messages(): array
        {
            return array_map(fn (array $e) => $e[0]->getMessage(), $this->errors);
        }
    }
} else {
    abstract class TestCase extends \PHPUnit\Framework\TestCase
    {
        protected function setUp(): void
        {
            $this->markTestSkipped('the Laravel tests need orchestra/testbench (composer require --dev orchestra/testbench)');
        }
    }
}
