<?php

declare(strict_types=1);

namespace Cronwatch\Tests;

use Cronwatch\Alert;
use Cronwatch\Alerts;
use Cronwatch\Alerts\ChannelContext;
use Cronwatch\Alerts\Email;
use Cronwatch\Alerts\Shared;
use Cronwatch\Alerts\Twilio;
use Cronwatch\Js;
use Cronwatch\Tests\Support\FakeHttp;
use PHPUnit\Framework\TestCase;

/**
 * Replays conformance/channels.json: every channel's request (URL, headers
 * and body, byte for byte) for every sample alert, the errors each gives
 * for a refused request, Twilio's delivery to some numbers and not others,
 * and the text cuts (error bodies, subjects, SMS segments and bodies).
 */
final class ChannelConformanceTest extends TestCase
{
    private const FILE = __DIR__ . '/../../../conformance/channels.json';

    private const CLASSES = [
        'slack' => Alerts\Slack::class,
        'discord' => Alerts\Discord::class,
        'webhook' => Alerts\Webhook::class,
        'resend' => Alerts\Resend::class,
        'postmark' => Alerts\Postmark::class,
        'sendgrid' => Alerts\Sendgrid::class,
        'mailgun' => Alerts\Mailgun::class,
        'ses' => Alerts\Ses::class,
        'twilio' => Alerts\Twilio::class,
        'sentry' => Alerts\Sentry::class,
        'honeybadger' => Alerts\Honeybadger::class,
        'datadog' => Alerts\Datadog::class,
        'rollbar' => Alerts\Rollbar::class,
        'bugsnag' => Alerts\Bugsnag::class,
        'newrelic' => Alerts\NewRelic::class,
    ];

    private static ?\stdClass $fixture = null;

    private static function fixture(): \stdClass
    {
        return self::$fixture ??= Js::parse((string) file_get_contents(self::FILE));
    }

    /** The sample alert by name. */
    private static function alert(string $name): Alert
    {
        foreach (self::fixture()->alerts as $case) {
            if ($case->name === $name) {
                return Alert::fromJson($case->alert);
            }
        }
        throw new \LogicException("no alert {$name}");
    }

    private static function first(): Alert
    {
        return Alert::fromJson(self::fixture()->alerts[0]->alert);
    }

    private static function context(?array &$reported = null): ChannelContext
    {
        $reported = [];
        return new ChannelContext(function (\Throwable $e) use (&$reported): void {
            $reported[] = $e->getMessage();
        });
    }

    /**
     * The fixture's options as the channel's named arguments: `link: true`
     * stands for the usual link and `now: <ms>` for a clock fixed at that time.
     */
    private static function channel(string $name, \stdClass $options, FakeHttp $http): Alerts\AlertChannel
    {
        $args = [];
        foreach (Js::plain($options) as $key => $value) {
            $args[$key] = match ($key) {
                'link' => $value ? fn (Alert $a) => "https://app.example/cronwatch/jobs/{$a->job}" : null,
                'now' => fn () => $value,
                default => $value,
            };
        }
        $class = self::CLASSES[$name];
        return new $class(...$args, http: $http);
    }

    private static function digest(string $text): array
    {
        $length = Js::length16($text);
        return $length <= 400 ? ['text' => $text] : ['length' => $length, 'sha256' => hash('sha256', $text)];
    }

    private static function differs(mixed $expected, mixed $actual): ?string
    {
        $e = Js::stringify(Js::plain($expected));
        $a = Js::stringify(Js::plain($actual));
        return $e === $a ? null : 'expected ' . substr($e, 0, 1500) . "\n    got      " . substr($a, 0, 1500);
    }

    /**
     * @param list<\stdClass> $cases
     * @param \Closure(\stdClass): ?string $check
     */
    private function eachCase(array $cases, \Closure $check): void
    {
        $failures = [];
        foreach ($cases as $i => $case) {
            try {
                $message = $check($case);
            } catch (\Throwable $error) {
                $message = 'threw ' . get_class($error) . ': ' . $error->getMessage();
            }
            if ($message !== null) {
                $failures[] = "#{$i} " . substr(Js::stringify($case), 0, 300) . "\n    {$message}";
            }
        }
        $this->assertSame([], $failures, count($failures) . ' of ' . count($cases) . " cases differ:\n" . implode("\n", array_slice($failures, 0, 10)));
    }

    public function testSlackDiscordAndWebhookPayloads(): void
    {
        $this->eachCase(self::fixture()->sends, function (\stdClass $c): ?string {
            $http = new FakeHttp();
            self::channel($c->channel, $c->options, $http)->send(self::alert($c->alert), self::context());
            $request = $http->requests[count($http->requests) - 1];
            return self::differs([$c->url, $c->headers, $c->body], [$request['url'], $request['headers'], self::digest($request['body'])]);
        });
    }

    /** The webhook's body byte for byte, "schema": 1 first, and its signature, for every sample alert. */
    public function testWebhookPayloadsAndSignatures(): void
    {
        $this->eachCase(self::fixture()->webhookPayloads, function (\stdClass $c): ?string {
            $http = new FakeHttp();
            (new Alerts\Webhook('https://hooks.example.com/cronwatch', secret: $c->secret, http: $http))->send(self::alert($c->alert), self::context());
            $request = $http->requests[count($http->requests) - 1];
            return self::differs([$c->body, $c->signature, $c->signature], [$request['body'], $request['headers']['x-cronwatch-signature'] ?? null, 'sha256=' . Alerts\Webhook::signature($c->secret, $c->body)]);
        });
    }

    public function testTheSignatureHelper(): void
    {
        $this->assertSame('f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8', Alerts\Webhook::signature('key', 'The quick brown fox jumps over the lazy dog'));
        // The deprecated name answers the same.
        $this->assertSame(Alerts\Webhook::signature('key', 'body'), Alerts\Webhook::hmacSha256Hex('key', 'body'));
    }

    public function testSlackDiscordAndWebhookFailures(): void
    {
        $this->eachCase(self::fixture()->failures, function (\stdClass $c): ?string {
            try {
                self::channel($c->channel, $c->options, new FakeHttp($c->status, $c->body))->send(self::first(), self::context());
            } catch (\RuntimeException $error) {
                return self::differs($c->error, $error->getMessage());
            }
            return "expected an error: {$c->error}";
        });
    }

    public function testProviderPayloads(): void
    {
        $this->assertSame(array_keys(array_slice(self::CLASSES, 3)), array_values(array_unique(array_map(fn ($c) => $c->channel, self::fixture()->providerSends))));
        $this->eachCase(self::fixture()->providerSends, function (\stdClass $c): ?string {
            $http = new FakeHttp();
            self::channel($c->channel, $c->options, $http)->send(self::alert($c->alert), self::context());
            $requests = array_map(fn (array $r) => ['url' => $r['url'], 'headers' => $r['headers'], 'body' => self::digest($r['body'])], $http->requests);
            return self::differs($c->requests, $requests);
        });
    }

    public function testProviderFailures(): void
    {
        $this->eachCase(self::fixture()->providerFailures, function (\stdClass $c): ?string {
            try {
                self::channel($c->channel, $c->options, new FakeHttp($c->status, $c->body))->send(self::first(), self::context());
            } catch (\RuntimeException $error) {
                return self::differs($c->error, $error->getMessage());
            }
            return $c->error === null ? null : "expected an error: {$c->error}";
        });
    }

    /**
     * Each number refusing is reported through the channel context; the alert
     * fails only when every number refused it. The SDK also records fetch's
     * redirect: "error"; no Http here follows a redirect, so there is no
     * option to compare.
     */
    public function testTwilioPartialDelivery(): void
    {
        $partial = self::fixture()->twilioPartial;
        $options = $partial->options;
        $this->eachCase($partial->cases, function (\stdClass $c) use ($options): ?string {
            $answers = array_combine($options->to, $c->statuses);
            $seen = [];
            $http = new FakeHttp(answer: function (string $url, string $body) use ($answers, &$seen): array {
                $to = FakeHttp::form($body)['To'][0];
                $seen[] = ['url' => $url, 'to' => $to];
                $status = $answers[$to];
                return [$status, $status < 400 ? '{}' : "{\"message\":\"refused {$to} with tw-secret\"}"];
            });
            $channel = new Twilio(accountSid: $options->accountSid, authToken: $options->authToken, from: $options->from, to: $options->to, http: $http);
            $error = null;
            try {
                $channel->send(self::first(), self::context($reported));
            } catch (\RuntimeException $e) {
                $error = $e->getMessage();
            }
            $expected = [array_map(fn ($r) => ['url' => $r->url, 'to' => $r->to], $c->requests), $c->error, $c->reported];
            return self::differs($expected, [$seen, $error, $reported]);
        });
    }

    public function testErrorBodiesCutSecretsOutFirst(): void
    {
        $this->eachCase(self::fixture()->textCuts->errorBodies, fn (\stdClass $c) => self::differs($c->body, Shared::errorBody($c->text, $c->secrets)));
    }

    /** Long text travels as {"parts": [[piece, times], ...]}. */
    private static function expand(mixed $spec): mixed
    {
        return $spec instanceof \stdClass && isset($spec->parts)
            ? implode('', array_map(fn (array $part) => str_repeat($part[0], $part[1]), $spec->parts))
            : $spec;
    }

    public function testDiscordDescriptionsHoldTo4096(): void
    {
        $this->eachCase(self::fixture()->textCuts->discordDescriptions, function (\stdClass $c): ?string {
            $alert = self::first();
            $alert->message = self::expand($c->message);
            $alert->triage = self::expand($c->triage);
            return self::differs($c->description, self::digest(Alerts\Discord::embedDescription($alert)));
        });
    }

    public function testEmailSubjectsCutOnACodePoint(): void
    {
        $this->eachCase(self::fixture()->textCuts->subjects, function (\stdClass $c): ?string {
            $alert = self::first();
            $alert->title = $c->title;
            return self::differs($c->subject, Email::compose($alert, 'a@example.com', ['b@example.com'], $c->subjectPrefix)->subject);
        });
    }

    public function testSmsSegments(): void
    {
        $this->eachCase(self::fixture()->textCuts->smsSegments, fn (\stdClass $c) => self::differs($c->segments, Twilio::smsSegments($c->text)));
    }

    public function testSmsBodies(): void
    {
        $long = self::first();
        $long->title = 'nightly failed';
        $long->message = str_repeat(str_repeat('a', 152) . "{\n", 12);
        $long->setTriage(null);
        $this->eachCase(self::fixture()->textCuts->smsBodies, function (\stdClass $c) use ($long): ?string {
            $link = ($c->link ?? null) === 'long' ? 'https://app.example/' . str_repeat('p', 2000) : 'https://app.example/j';
            return self::differs($c->body, self::digest(Twilio::smsBody($long, $link, $c->segments ?? NAN)));
        });
    }
}
