<?php

declare(strict_types=1);

namespace Cronwatch\Tests\Symfony;

use Cronwatch\Cronwatch;
use Cronwatch\Store\MemoryStore;
use Cronwatch\Tests\Support\Capture;
use Cronwatch\Tests\Support\Clock;
use Cronwatch\Tests\Symfony\Fixtures\TestKernel;
use Symfony\Component\HttpKernel\KernelInterface;

// The Symfony tests run on FrameworkBundle's test kernel with the
// Scheduler, Messenger and SecurityBundle, which the CI entries for each
// supported Symfony install (see DESIGN.md); without them they are skipped,
// so the core suite runs on its own.
if (class_exists(\Symfony\Bundle\FrameworkBundle\Test\WebTestCase::class)
    && class_exists(\Symfony\Component\Scheduler\Schedule::class)
    && class_exists(\Symfony\Bundle\SecurityBundle\SecurityBundle::class)
    && class_exists(\Symfony\Component\BrowserKit\AbstractBrowser::class)) {
    require_once __DIR__ . '/Fixtures/App.php';

    abstract class TestCase extends \Symfony\Bundle\FrameworkBundle\Test\WebTestCase
    {
        protected Clock $clock;
        protected Capture $capture;
        /** @var list<array{\Throwable, string}> */
        protected array $errors = [];

        protected static function getKernelClass(): string
        {
            return TestKernel::class;
        }

        protected static function createKernel(array $options = []): KernelInterface
        {
            return new TestKernel($options['cronwatch'] ?? ['store' => 'memory'], $options['environment'] ?? 'test');
        }

        protected function tearDown(): void
        {
            parent::tearDown();
            // The bundle names the kernel's environment as the fallback; the next test's kernel is another.
            \Cronwatch\Env::setFallback(null);
        }

        public static function tearDownAfterClass(): void
        {
            parent::tearDownAfterClass();
            self::removeDir(TestKernel::dir());
        }

        private static function removeDir(string $dir): void
        {
            if (!is_dir($dir)) {
                return;
            }
            $items = new \RecursiveIteratorIterator(new \RecursiveDirectoryIterator($dir, \FilesystemIterator::SKIP_DOTS), \RecursiveIteratorIterator::CHILD_FIRST);
            foreach ($items as $item) {
                $item->isDir() ? @rmdir($item->getPathname()) : @unlink($item->getPathname());
            }
            @rmdir($dir);
        }

        /** A client on a test clock, capturing alerts and errors, set as the container's before anything uses it. */
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
            static::getContainer()->set(Cronwatch::class, $cw);
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
            $this->markTestSkipped('the Symfony tests need symfony/framework-bundle, symfony/scheduler, symfony/messenger, symfony/security-bundle and symfony/browser-kit');
        }
    }
}
