<?php

declare(strict_types=1);

namespace Cronwatch\Tests\Support;

use Cronwatch\Cronwatch;
use Cronwatch\Store\Store;

/** What the SDK tests' make() builds: a client on a test clock that captures its alerts and errors. */
trait Clients
{
    protected Clock $clock;
    protected Capture $capture;
    /** @var list<array{\Throwable, string}> */
    protected array $errors = [];

    /** @param array<string, mixed> $options more of Cronwatch's named arguments */
    protected function make(array $options = []): Cronwatch
    {
        $this->clock ??= new Clock();
        $this->capture = new Capture();
        $this->errors = [];
        return new Cronwatch(...array_replace([
            'now' => $this->clock,
            'alerts' => [$this->capture],
            'cronSecret' => false,
            'onError' => function (\Throwable $error, string $where): void {
                $this->errors[] = [$error, $where];
            },
        ], $options));
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

    /** Runs a job that throws, and returns what it threw. */
    protected function failing(callable $run): \Throwable
    {
        try {
            $run();
        } catch (\Throwable $error) {
            return $error;
        }
        $this->fail('expected the job to throw');
    }

    protected static function thrower(string $message = 'x'): \Closure
    {
        return function () use ($message): never {
            throw new \RuntimeException($message);
        };
    }

    protected static function store(Cronwatch $cw): Store
    {
        return $cw->store;
    }
}
