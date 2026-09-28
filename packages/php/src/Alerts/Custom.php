<?php

declare(strict_types=1);

namespace Cronwatch\Alerts;

use Cronwatch\Alert;

/**
 * Any callable as an alert channel: new Custom('pager', fn (Alert $alert) => ...).
 * A callable that takes two arguments also gets the ChannelContext.
 */
final class Custom implements AlertChannel
{
    private readonly \Closure $send;
    private readonly bool $takesContext;

    public function __construct(private readonly string $name, callable $send)
    {
        $this->send = \Closure::fromCallable($send);
        $this->takesContext = self::arity($this->send) >= 2;
    }

    /** How many arguments a callable takes, counting a variadic one as many. */
    public static function arity(\Closure $fn): int
    {
        $reflection = new \ReflectionFunction($fn);
        return $reflection->isVariadic() ? PHP_INT_MAX : $reflection->getNumberOfParameters();
    }

    public function name(): string
    {
        return $this->name;
    }

    public function send(Alert $alert, ChannelContext $context): void
    {
        $this->takesContext ? ($this->send)($alert, $context) : ($this->send)($alert);
    }
}
