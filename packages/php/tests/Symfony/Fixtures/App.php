<?php

declare(strict_types=1);

namespace Cronwatch\Tests\Symfony\Fixtures;

use Cronwatch\Cronwatch;
use Cronwatch\Job\JobContext;
use Cronwatch\Symfony\CronwatchBundle;
use Cronwatch\Watch;
use Symfony\Bundle\FrameworkBundle\FrameworkBundle;
use Symfony\Bundle\FrameworkBundle\Kernel\MicroKernelTrait;
use Symfony\Bundle\SecurityBundle\SecurityBundle;
use Symfony\Component\DependencyInjection\Loader\Configurator\ContainerConfigurator;
use Symfony\Component\HttpFoundation\JsonResponse;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\HttpFoundation\Response;
use Symfony\Component\HttpKernel\Kernel;
use Symfony\Component\Routing\Loader\Configurator\RoutingConfigurator;
use Symfony\Component\Scheduler\RecurringMessage;
use Symfony\Component\Scheduler\Schedule;
use Symfony\Component\Scheduler\ScheduleProviderInterface;

use function Symfony\Component\DependencyInjection\Loader\Configurator\service;

// A Symfony app for the bundle's tests, in one file (tests/Symfony/TestCase.php
// requires it, since PSR-4 finds one class a file): a kernel with
// FrameworkBundle, SecurityBundle, and CronwatchBundle, a schedule the test
// fills in, messages and their handlers, and a controller running a job's
// handler().

final class TestKernel extends Kernel
{
    use MicroKernelTrait;

    /** @param array<string, mixed> $cronwatch the bundle's configuration */
    public function __construct(private readonly array $cronwatch = [], string $environment = 'test')
    {
        parent::__construct($environment, false);
    }

    public function registerBundles(): iterable
    {
        yield new FrameworkBundle();
        yield new SecurityBundle();
        yield new CronwatchBundle();
    }

    public function getProjectDir(): string
    {
        return self::dir();
    }

    public function getCacheDir(): string
    {
        return self::dir() . '/cache/' . md5(serialize($this->cronwatch) . $this->environment);
    }

    public function getLogDir(): string
    {
        return self::dir() . '/log';
    }

    public static function dir(): string
    {
        return sys_get_temp_dir() . '/cronwatch-symfony-' . getmypid();
    }

    protected function configureContainer(ContainerConfigurator $container): void
    {
        $framework = [
            'test' => true,
            'secret' => 'test-' . 'secret',
            'http_method_override' => false,
            'handle_all_throwables' => true,
            'php_errors' => ['log' => true],
            'router' => ['utf8' => true],
            'messenger' => [
                'transports' => [
                    'async' => ['dsn' => 'in-memory://', 'retry_strategy' => ['max_retries' => 2, 'delay' => 0, 'multiplier' => 1]],
                ],
                'routing' => [AsyncReport::class => 'async', RedispatchedReport::class => 'async'],
            ],
        ];
        if (Kernel::MAJOR_VERSION < 7) {
            $framework['annotations'] = false;
        }
        $container->extension('framework', $framework);
        $container->extension('security', [
            'password_hashers' => ['Symfony\Component\Security\Core\User\InMemoryUser' => 'plaintext'],
            'providers' => ['users' => ['memory' => ['users' => [
                'admin' => ['password' => 'pw', 'roles' => ['ROLE_ADMIN']],
                'viewer' => ['password' => 'pw', 'roles' => ['ROLE_USER']],
            ]]]],
            'firewalls' => ['main' => ['pattern' => '^/', 'lazy' => true, 'provider' => 'users', 'http_basic' => null]],
            'access_control' => [],
        ]);
        $container->extension('cronwatch', $this->cronwatch);

        $services = $container->services();
        // Quiet: Messenger logs a handler that fails at critical, which the default logger prints.
        $services->set('logger', \Psr\Log\NullLogger::class);
        $services->set(TestSchedule::class)->tag('scheduler.schedule_provider', ['name' => 'default']);
        $services->set(ReportsSchedule::class)->tag('scheduler.schedule_provider', ['name' => 'reports']);
        $services->set(Handlers::class)
            ->tag('messenger.message_handler', ['handles' => Report::class, 'method' => 'report'])
            ->tag('messenger.message_handler', ['handles' => Plain::class, 'method' => 'plain'])
            ->tag('messenger.message_handler', ['handles' => Failing::class, 'method' => 'failing'])
            ->tag('messenger.message_handler', ['handles' => AsyncReport::class, 'method' => 'async'])
            ->tag('messenger.message_handler', ['handles' => RedispatchedReport::class, 'method' => 'redispatched']);
        $services->set(CronController::class)->args([service(Cronwatch::class)])->tag('controller.service_arguments')->public();
    }

    protected function configureRoutes(RoutingConfigurator $routes): void
    {
        $routes->import('@CronwatchBundle/config/routes.php')->prefix('/cronwatch');
        $routes->add('cron_nightly', '/cron/nightly')->controller(CronController::class)->methods(['GET', 'POST']);
        $routes->add('cron_down', '/cron/down')->controller([CronController::class, 'down']);
    }
}

final class TestSchedule implements ScheduleProviderInterface
{
    /** @var list<RecurringMessage> what the next kernel's default schedule sends */
    public static array $messages = [];

    public function getSchedule(): Schedule
    {
        $schedule = new Schedule();
        return self::$messages === [] ? $schedule : $schedule->add(...self::$messages);
    }
}

final class ReportsSchedule implements ScheduleProviderInterface
{
    /** @var list<RecurringMessage> */
    public static array $messages = [];

    public function getSchedule(): Schedule
    {
        $schedule = new Schedule();
        return self::$messages === [] ? $schedule : $schedule->add(...self::$messages);
    }
}

#[Watch(name: 'nightly-report', expect: 'Report written', grace: '15m')]
final class Report
{
}

final class Plain
{
    public function __construct(public readonly string $label = '')
    {
    }
}

final class Failing
{
}

/** Fails until its handler has seen it $succeedOn times (0: never). */
#[Watch(failuresBeforeAlert: 1)]
final class AsyncReport
{
}

#[Watch(name: 'queued-report')]
final class RedispatchedReport
{
}

final class Handlers
{
    public static int $asyncCalls = 0;
    public static int $succeedOn = 3;

    public function report(Report $message): string
    {
        Cronwatch::current()?->metric('pages', 12);
        return 'Report written';
    }

    public function plain(Plain $message): void
    {
    }

    public function failing(Failing $message): void
    {
        throw new \RuntimeException('the report service is down');
    }

    public function async(AsyncReport $message): void
    {
        self::$asyncCalls++;
        if (self::$succeedOn === 0 || self::$asyncCalls < self::$succeedOn) {
            throw new \RuntimeException('attempt ' . self::$asyncCalls . ' failed');
        }
        Cronwatch::current()?->log('attempt ' . self::$asyncCalls . ' worked');
    }

    public function redispatched(RedispatchedReport $message): string
    {
        return 'sent on and handled';
    }
}

final class CronController
{
    public function __construct(private readonly Cronwatch $cw)
    {
    }

    public function __invoke(Request $request): Response
    {
        return $this->cw->job('nightly')->handler(function (JobContext $job, Request $request): void {
            $job->log($request->getPathInfo());
        })($request);
    }

    public function down(Request $request): Response
    {
        return $this->cw->job('down')->handler(fn () => new JsonResponse(['down' => true], 503))($request);
    }
}
