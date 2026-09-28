<?php

declare(strict_types=1);

namespace Cronwatch\Tests;

use Cronwatch\Alert;
use Cronwatch\AlertDraft;
use Cronwatch\Alerts;
use Cronwatch\Alerts\ChannelContext;
use Cronwatch\Alerts\Custom;
use Cronwatch\Alerts\Email;
use Cronwatch\Alerts\NativeHttp;
use Cronwatch\Alerts\RequestTimeout;
use Cronwatch\Alerts\Sentry;
use Cronwatch\Alerts\Shared;
use Cronwatch\Alerts\SigV4;
use Cronwatch\Alerts\Twilio;
use Cronwatch\Cronwatch;
use Cronwatch\Format;
use Cronwatch\JobDefinition;
use Cronwatch\Js;
use Cronwatch\Run;
use Cronwatch\Tests\Support\Clients;
use Cronwatch\Tests\Support\Clock;
use Cronwatch\Tests\Support\FakeHttp;
use Cronwatch\Tests\Support\LocalServer;
use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;

/**
 * The channels beside the conformance replay (which checks every request
 * byte for byte), as the SDK's alerts.test.ts, channels-hardening.test.ts
 * and sigv4.test.ts have them: SigV4 against the AWS test suite, SMS
 * fitting, the options each channel refuses, failures that never name a
 * secret, and the default Http (curl and PHP's streams) against a local
 * server: no redirect followed, one deadline for the whole request, header
 * values trimmed.
 */
final class ChannelsTest extends TestCase
{
    use Clients;

    private const T0 = Clock::T0;
    private const EMAIL = ['from' => 'a@b.c', 'to' => 'd@e.f'];

    private static function failed(string $message = 'Error: boom', ?string $triage = null, ?string $title = null): Alert
    {
        $run = new Run('r1', 'nightly', 'failed', self::T0, self::T0 + 1000, 1000, $message);
        $alert = Format::composeAlert(new AlertDraft('failed', $run, ['consecutiveFailures' => 1, 'threshold' => 1]), JobDefinition::fromJson(['name' => 'nightly']), self::T0 + 2000);
        $alert->message = $message;
        if ($title !== null) {
            $alert->title = $title;
        }
        if ($triage !== null) {
            $alert->setTriage($triage);
        }
        return $alert;
    }

    private static function recovered(): Alert
    {
        $alert = self::failed();
        $alert->type = 'recovered';
        return $alert;
    }

    private static function context(?array &$reported = null): ChannelContext
    {
        $reported = [];
        return new ChannelContext(function (\Throwable $e) use (&$reported): void {
            $reported[] = $e->getMessage();
        });
    }

    private static function sendError(Alerts\AlertChannel $channel, ?Alert $alert = null): string
    {
        try {
            $channel->send($alert ?? self::failed(), self::context());
        } catch (\RuntimeException $error) {
            return $error->getMessage();
        }
        self::fail('expected the send to fail');
    }

    // ------------------------------------------------------------ SigV4

    public static function sigv4Cases(): iterable
    {
        $token = 'AQoDYXdzEPT//////////wEXAMPLEtc764bNrC9SAPBSM22wDOk4x4HIZ8j4FZTwdQWLWsKWHGBuFqwAeMicRXmxfpSPfIeoIYRqTflfKD8YUuwthAx7mSEI/'
            . 'qkPpKPi/kMcGdQrmGdeehM4IC1NtBmUpp2wUE8phUZampKsburEDy0KPkyQDYwT7WZ0wq5VSXDvp75YU9HFvlRd8Tx6q6fE8YQcHNVXAkiY9q6d+xo0rKwT38xVqr7ZD0u0iPPkUL64lIZbqBAz+'
            . 'scqKmlzm8FDrypNC9Yjc8fPOLn9FX9KSYvKTr4rvx3iSIlTJabIQwj2ICCR/oLxBA==';
        yield 'get-vanilla' => ['GET', 'https://example.amazonaws.com/', [], null,
            'SignedHeaders=host;x-amz-date, Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31'];
        yield 'post-vanilla' => ['POST', 'https://example.amazonaws.com/', [], null,
            'SignedHeaders=host;x-amz-date, Signature=5da7c1a2acd57cee7505fc6676e4e544621c30862966e37dddb68e92efbe5d6b'];
        yield 'get-vanilla-query-order-key-case' => ['GET', 'https://example.amazonaws.com/?Param2=value2&Param1=value1', [], null,
            'SignedHeaders=host;x-amz-date, Signature=b97d918cfa904a5beff61c982a1b6f458b799221646efd99d3219ec94cdf2500'];
        yield 'post-header-value-case' => ['POST', 'https://example.amazonaws.com/', ['My-Header1' => 'VALUE1'], null,
            'SignedHeaders=host;my-header1;x-amz-date, Signature=cdbc9802e29d2942e5e10b5bccfdd67c5f22c7c4e8ae67b53629efa58b974b7d'];
        yield 'post-sts-header-before' => ['POST', 'https://example.amazonaws.com/', [], $token,
            'SignedHeaders=host;x-amz-date;x-amz-security-token, Signature=85d96828115b5dc0cfc3bd16ad9e210dd772bbebba041836c64533a82be05ead'];
    }

    #[DataProvider('sigv4Cases')]
    public function testSigV4MatchesTheAwsTestSuite(string $method, string $url, array $headers, ?string $token, string $authorization): void
    {
        $signed = SigV4::sign($method, $url, $headers, '', 'us-east-1', 'service', Js::dateUtc(2015, 7, 30, 12, 36),
            'AKIDEXAMPLE', 'wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY', $token);
        $this->assertSame("AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, {$authorization}", $signed['authorization']);
        $this->assertSame('20150830T123600Z', $signed['x-amz-date']);
        $this->assertArrayNotHasKey('host', $signed, 'the HTTP client sets Host itself');
        if ($token !== null) {
            $this->assertSame($token, $signed['x-amz-security-token']);
        }
    }

    // ------------------------------------------------------------ SMS

    public function testSmsBodiesFitTheirSegmentsAndKeepTheLinkWhole(): void
    {
        $gsm = Twilio::smsBody(self::failed(str_repeat('x', 2000)), 'https://app.example/j');
        $this->assertLessThanOrEqual(459, strlen($gsm));
        $this->assertStringEndsWith("...\nhttps://app.example/j", $gsm);
        $ucs = Twilio::smsBody(self::failed(str_repeat("\u{1F600}", 500)), null);
        $this->assertLessThanOrEqual(201, Js::length16($ucs));
        $this->assertSame(1, preg_match('//u', $ucs), 'whole characters only');
        $this->assertSame("nightly failed\none\ntwo", Twilio::smsBody(self::failed("one\ntwo"), null));
        $this->assertSame("nightly failed\none\nTriage: db down", Twilio::smsBody(self::failed('one', 'db down'), null));
        // The extension table counts two: 80 braces are 160 septets, one segment; 81 are not.
        $this->assertTrue(Twilio::fits(str_repeat('{', 80), 1));
        $this->assertFalse(Twilio::fits(str_repeat('{', 81), 1));
        $this->assertTrue(Twilio::fits(str_repeat('é', 160), 1));
        $this->assertFalse(Twilio::fits(str_repeat('ê', 71), 1), 'a character outside GSM-7 makes the message UCS-2');
    }

    public function testSmsBodiesStayInsideTwiliosLimitAndPackSegmentsAsPhonesDo(): void
    {
        $long = self::failed(str_repeat('x', 3000), title: 'j failed');
        $this->assertLessThanOrEqual(1530, strlen(Twilio::smsBody($long, null, 12)), 'segments capped at 10');
        $this->assertLessThanOrEqual(459, strlen(Twilio::smsBody($long, null, NAN)), 'not a number: the default 3');
        $this->assertLessThanOrEqual(459, strlen(Twilio::smsBody($long, null, '5')), 'not a number: the default 3');
        $this->assertLessThanOrEqual(459, strlen(Twilio::smsBody($long, null, true)), 'not a number: the default 3');
        $this->assertSame(1, Twilio::smsSegments(str_repeat('a', 160)));
        $this->assertSame(2, Twilio::smsSegments(str_repeat('a', 161)));
        $this->assertSame(3, Twilio::smsSegments(str_repeat('a', 152) . '{' . str_repeat('a', 152)), 'an escape pair never straddles a segment');
        $this->assertSame(1, Twilio::smsSegments(str_repeat("\u{1F600}", 35)));
        $this->assertSame(3, Twilio::smsSegments(str_repeat('a', 66) . "\u{1F600}" . str_repeat('a', 66)), 'a surrogate pair never straddles a segment');
        $huge = Twilio::smsBody(self::failed('m'), 'https://example.com/' . str_repeat('p', 2000), 10);
        $this->assertLessThanOrEqual(1600, Js::length16($huge));
    }

    public function testTwilioTriesEveryNumberAndReportsHowManyFailedWithoutTheToken(): void
    {
        $http = new FakeHttp(400, 'tw-token rejected');
        $channel = new Alerts\Twilio(accountSid: 'AC123', authToken: 'tw-token', from: '+1', to: ['+2', '+3'], http: $http);
        $this->assertSame('Twilio https://api.twilio.com answered 400: [redacted] rejected (2 of 2 numbers failed)', self::sendError($channel));
        $this->assertCount(2, $http->requests);
        (new Alerts\Twilio(accountSid: 'AC1', authToken: 't', from: '+1', to: '+2', http: $http))->send(self::recovered(), self::context());
        $this->assertCount(2, $http->requests, 'recoveries are not texted by default');
    }

    public function testTwilioOneNumberTakingTheAlertIsADeliveryAndTheRefusalsAreReported(): void
    {
        $sent = [];
        $http = new FakeHttp(answer: function (string $url, string $body) use (&$sent): array {
            $to = FakeHttp::form($body)['To'][0];
            if ($to === '+15550000000') {
                return [400, '{"code":21211,"message":"Invalid To"}'];
            }
            $sent[] = $to;
            return [201, '{}'];
        });
        $cw = $this->make(['alerts' => [new Alerts\Twilio(accountSid: 'AC1', authToken: 'tok', from: '+15551112222', to: ['+15553334444', '+15550000000'], http: $http)]]);
        $cw->job('nightly', ['schedule' => '0 * * * *']);
        $cw->check();
        for ($i = 0; $i < 6; $i++) {
            $this->clock->advance(70 * Clock::MIN);
            $cw->check();
        }
        $this->assertSame(['+15553334444'], $sent, 'one SMS for one open missed condition, never resent');
        $this->assertSame(['alert channel twilio'], $this->wheres());
        $this->assertStringStartsWith('Twilio https://api.twilio.com answered 400: ', $this->messages()[0]);
        $this->assertStringContainsString('Invalid To', $this->messages()[0]);
        $this->assertStringEndsWith('(to ********0000; 1 of 2 numbers took the alert)', $this->messages()[0]);

        $channel = new Alerts\Twilio(accountSid: 'AC1', authToken: 'tok', from: '+1', to: ['+2', '+3'], http: new FakeHttp(500, 'no'));
        $this->assertStringEndsWith('(2 of 2 numbers failed)', self::sendError($channel), 'every number refusing is a failure, retried at the next check');
    }

    // ------------------------------------------------------------ email

    public function testEmailContentAndAddresses(): void
    {
        $mail = Email::compose(self::failed("a <b>\n\"q\""), 'a@b.c', ['x@y.z'], "[p]\n", fn () => 'javascript:alert(1)');
        $this->assertSame('[p]  nightly failed', $mail->subject, 'one line');
        $this->assertStringNotContainsString('javascript:', $mail->html);
        $this->assertStringContainsString("a &lt;b&gt;\n&quot;q&quot;", $mail->html);
        $this->assertSame(['email' => 'ops@example.com', 'name' => 'Ops Team'], Email::parseAddress('"Ops Team" <ops@example.com>'));
        $this->assertSame(['email' => 'ops@example.com'], Email::parseAddress(' ops@example.com '));
        $this->assertSame(['email' => 'ops@example.com'], Email::parseAddress('<ops@example.com>'));
        $this->assertStringEndsWith('Open: HTTPS://app.example/j', Email::compose(self::failed(), 'a@b.c', ['x@y.z'], link: fn () => 'HTTPS://app.example/j')->text);
        $this->assertSame(str_repeat('a', 249), Email::compose(self::failed(title: str_repeat('a', 249) . "\u{1F600}"), 'a@b.c', ['d@e.f'])->subject, 'never half a surrogate pair');
    }

    public static function refusals(): iterable
    {
        $email = self::EMAIL;
        yield 'resend key' => [fn () => new Alerts\Resend(...$email, apiKey: ''), 'needs an apiKey'];
        yield 'resend blank key' => [fn () => new Alerts\Resend(...$email, apiKey: '  '), 'needs an apiKey'];
        yield 'resend from' => [fn () => new Alerts\Resend(apiKey: 'k', from: '', to: 'x@y.z'), 'needs a from address'];
        yield 'postmark to' => [fn () => new Alerts\Postmark(serverToken: 't', from: 'a@b.c', to: [' ', null]), 'needs at least one to address'];
        yield 'mailgun domain' => [fn () => new Alerts\Mailgun(...$email, apiKey: 'k', domain: ''), 'needs a domain'];
        yield 'ses region' => [fn () => new Alerts\Ses(...$email, region: 'US East', accessKeyId: 'a', secretAccessKey: 'b'), 'region like us-east-1'];
        yield 'ses secret' => [fn () => new Alerts\Ses(...$email, region: 'us-east-1', accessKeyId: 'a', secretAccessKey: ''), 'secretAccessKey'];
        yield 'twilio token' => [fn () => new Alerts\Twilio(accountSid: 'AC1', from: '+1', to: '+2'), 'authToken'];
        yield 'twilio from' => [fn () => new Alerts\Twilio(accountSid: 'AC1', authToken: 't', to: '+2'), 'from number'];
        yield 'twilio to' => [fn () => new Alerts\Twilio(accountSid: 'AC1', authToken: 't', from: '+1', to: []), 'at least one to number'];
        yield 'sentry key' => [fn () => new Alerts\Sentry(dsn: 'https://o1.ingest.sentry.io/42'), 'dsn like'];
        yield 'sentry url' => [fn () => new Alerts\Sentry(dsn: 'not a url'), 'valid dsn'];
        yield 'datadog site' => [fn () => new Alerts\Datadog(apiKey: 'k', site: 'evil.com/x?y'), 'site like'];
        yield 'newrelic account' => [fn () => new Alerts\NewRelic(accountId: '12a', apiKey: 'k'), 'numeric accountId'];
        yield 'rollbar token' => [fn () => new Alerts\Rollbar(accessToken: null), 'accessToken'];
        yield 'slack url' => [fn () => new Alerts\Slack(''), 'webhookUrl'];
        yield 'discord url' => [fn () => new Alerts\Discord(''), 'webhookUrl'];
        yield 'webhook url' => [fn () => new Alerts\Webhook(''), 'url'];
    }

    #[DataProvider('refusals')]
    public function testChannelsRefuseWhatTheyCannotSendWith(\Closure $make, string $message): void
    {
        $this->expectException(\InvalidArgumentException::class);
        $this->expectExceptionMessage($message);
        $make();
    }

    public function testSentryReadsADsn(): void
    {
        $this->assertSame(['https://o1.ingest.sentry.io/api/42/envelope/', 'pub'], Sentry::parseDsn('https://pub@o1.ingest.sentry.io/42'));
        $this->assertSame(['https://sentry.example.com:9000/prefix/api/7/envelope/', 'p@b'], Sentry::parseDsn('https://p%40b@sentry.example.com:9000/prefix/7'));
    }

    // ------------------------------------------------------------ secrets in failures

    public function testTheAlertIdIsStableAndEveryFailureHidesTheSecret(): void
    {
        $this->assertSame(Shared::alertId(self::failed()), Shared::alertId(self::failed('other')));
        $this->assertSame(
            'Honeybadger https://api.honeybadger.io answered 401: bad key [redacted] given',
            self::sendError(new Alerts\Honeybadger(apiKey: 'hb-secret', http: new FakeHttp(401, 'bad key hb-secret given'))),
        );
    }

    public function testAFailureBodyIsReadAsFetchReadsIt(): void
    {
        $this->assertSame(
            'Honeybadger https://api.honeybadger.io answered 500: bom',
            self::sendError(new Alerts\Honeybadger(apiKey: 'k-secret', http: new FakeHttp(500, "\u{FEFF}bom"))),
        );
        $this->assertSame(
            "Honeybadger https://api.honeybadger.io answered 500: caf\u{e9} \u{FFFD} end",
            self::sendError(new Alerts\Honeybadger(apiKey: 'k-secret', http: new FakeHttp(500, "caf\xc3\xa9 \xff end"))),
        );
    }

    public function testASecretThatStraddlesTheCutInAProvidersErrorBodyIsStillCutOut(): void
    {
        // Built in pieces so no Mailgun-shaped literal is committed for secret scanners to flag.
        $key = 'key-' . '0123456789abcdef' . '0123456789abcdef';
        $channel = new Alerts\Mailgun(...self::EMAIL, apiKey: $key, domain: 'mg.example.com', http: new FakeHttp(401, str_repeat('x', 180) . "invalid key {$key}"));
        $message = self::sendError($channel);
        for ($i = 0; $i < strlen($key) - 5; $i++) {
            $this->assertStringNotContainsString(substr($key, $i, 6), $message, 'a piece of the key survives');
        }
        $this->assertStringEndsWith(': ' . str_repeat('x', 180) . 'invalid key [redacte', $message, 'cut to 200 after the key was taken out');
        $this->assertSame(str_repeat('a', 199), Shared::errorBody(str_repeat('a', 199) . "\u{1F600}tail"), 'never half a surrogate pair');
        $this->assertSame(str_repeat('y', 10) . '[redacted]', substr(Shared::errorBody(str_repeat('y', 10) . 'sekret' . str_repeat('z', 300), ['sekret']), 0, 20));
    }

    public function testCredentialsAreTrimmedBeforeTheyGoInAHeader(): void
    {
        $http = new FakeHttp();
        $email = [...self::EMAIL, 'http' => $http];
        $channels = [
            new Alerts\Resend(...$email, apiKey: " re_secret\n"),
            new Alerts\Postmark(...$email, serverToken: "\tpm-secret "),
            new Alerts\Sendgrid(...$email, apiKey: "SG.secret\n"),
            new Alerts\Mailgun(...$email, apiKey: ' key-secret ', domain: 'mg.example.com'),
            new Alerts\Datadog(apiKey: "dd-secret\n", http: $http),
            new Alerts\Honeybadger(apiKey: ' hb-secret', http: $http),
            new Alerts\Rollbar(accessToken: "rb-secret \n", http: $http),
            new Alerts\Bugsnag(apiKey: "bs-secret\n", http: $http),
            new Alerts\NewRelic(accountId: '1', apiKey: ' nr-secret', http: $http),
            new Alerts\Sentry(dsn: " https://pubkey@o1.ingest.sentry.io/42\n", http: $http),
            new Alerts\Twilio(accountSid: ' AC1 ', authToken: "tok\n", from: '+1', to: '+2', http: $http),
            new Alerts\Ses(...$email, region: 'us-east-1', accessKeyId: ' AKIDEXAMPLE', secretAccessKey: "sekret\n"),
            new Alerts\Webhook('https://hooks.example.com/in', headers: ['authorization' => " Bearer wh-secret\n"], http: $http),
        ];
        foreach ($channels as $channel) {
            $channel->send(self::failed(), self::context());
        }
        foreach ($http->requests as $request) {
            foreach ($request['headers'] as $name => $value) {
                $this->assertSame(trim($value), $value, "{$name} has spaces around it");
            }
        }
        $headers = array_column($http->requests, 'headers');
        $this->assertSame('Bearer re_secret', $headers[0]['authorization']);
        $this->assertSame('pm-secret', $headers[1]['x-postmark-server-token']);
        $this->assertSame('dd-secret', $headers[4]['dd-api-key']);
        $this->assertSame('bs-secret', Js::parse($http->requests[7]['body'])->apiKey);
        $this->assertSame('https://api.twilio.com/2010-04-01/Accounts/AC1/Messages.json', $http->requests[10]['url']);
        $this->assertSame('Basic QUMxOnRvaw==', $headers[10]['authorization']);
        $this->assertStringStartsWith('AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/', $headers[11]['authorization']);
        $this->assertSame('Bearer wh-secret', $headers[12]['authorization']);
    }

    // ------------------------------------------------------------ Slack, Discord, webhook

    private static function alertJ(?string $triage = null): Alert
    {
        $run = new Run('r1', 'j', 'failed', self::T0, self::T0 + 1000, 1000, 'Error: boom', "before\n```\n@everyone <!channel> [click](https://evil.example)");
        $alert = Format::composeAlert(new AlertDraft('failed', $run, ['consecutiveFailures' => 1, 'threshold' => 1]), JobDefinition::fromJson(['name' => 'j']), self::T0 + 2000);
        if ($triage !== null) {
            $alert->setTriage($triage);
        }
        return $alert;
    }

    public function testDiscordKeepsJobOutputInsideItsCodeBlockAndPingsNoOne(): void
    {
        $http = new FakeHttp();
        (new Alerts\Discord('https://discord.example/api/webhooks/1/secret', http: $http))->send(self::alertJ('See [the docs](https://evil.example) *now*'), self::context());
        $body = Js::plain(Js::parse($http->requests[0]['body']));
        $this->assertSame(['parse' => []], $body['allowed_mentions']);
        $description = $body['embeds'][0]['description'];
        $this->assertSame(2, substr_count($description, '```'), "only the block's own fences");
        $this->assertStringContainsString('**Triage:** See \\[the docs\\]\\(https://evil.example\\) \\*now\\*', $description);
        $this->assertSame(['content', 'allowed_mentions', 'embeds'], array_keys($body));
        $this->assertSame(['title', 'description', 'color', 'timestamp'], array_keys($body['embeds'][0]));
        $this->assertSame('2026-01-05T09:30:02.000Z', $body['embeds'][0]['timestamp']);
        $this->assertSame(0xC62828, $body['embeds'][0]['color']);
    }

    public function testDiscordAddsTheLinkAndReportsARefusal(): void
    {
        $http = new FakeHttp(400, str_repeat('x', 500));
        $channel = new Alerts\Discord('https://discord.example/w', link: fn (Alert $a) => "https://app.example/{$a->job}", http: $http);
        $this->assertSame('Discord webhook answered 400: ' . str_repeat('x', 200), self::sendError($channel, self::alertJ()));
        $this->assertSame('https://app.example/j', Js::parse($http->requests[0]['body'])->embeds[0]->url);
    }

    public function testACutThroughAnEmojiIsWrittenAsJsonStringifyWritesIt(): void
    {
        $http = new FakeHttp();
        (new Alerts\Discord('https://discord.example/w', http: $http))->send(self::failed(str_repeat('a', 3799) . "\u{1F600}"), self::context());
        $this->assertStringContainsString(str_repeat('a', 3799) . '\\ud83d\\n```', $http->requests[0]['body'], 'the lone high surrogate JavaScript keeps, escaped');
        $this->assertSame('"\\ud83d"', Js::quote(Js::slice16("\u{1F600}", 1)));
        $this->assertSame("\u{FFFD}", Js::slice16("\u{FFFD}x", 1));
    }

    public function testSlackEscapesControlCharactersAndFencesInTheBlocksAndTheFallbackText(): void
    {
        $http = new FakeHttp();
        (new Alerts\Slack('https://hooks.slack.example/T/B/secret', http: $http))->send(self::alertJ('<b> & co'), self::context());
        $body = Js::plain(Js::parse($http->requests[0]['body']));
        $this->assertStringNotContainsString('<!channel>', $body['text']);
        $block = $body['blocks'][1]['text']['text'];
        $this->assertSame(2, substr_count($block, '```'));
        $this->assertStringContainsString('&lt;!channel&gt;', $block);
        $this->assertSame('_Triage:_ &lt;b&gt; &amp; co', $body['blocks'][2]['text']['text']);
        $this->assertSame(':x: *j failed*', $body['blocks'][0]['text']['text']);
    }

    public function testSlackLinkAndFailure(): void
    {
        $http = new FakeHttp(500, 'no');
        $channel = new Alerts\Slack('https://hooks.slack.example/x', link: fn () => 'https://app.example/j', http: $http);
        $this->assertSame('Slack webhook answered 500: no', self::sendError($channel, self::alertJ()));
        $this->assertSame(':x: *j failed* (<https://app.example/j|open>)', Js::parse($http->requests[0]['body'])->blocks[0]->text->text);
    }

    public function testWebhookFailuresNameTheOriginNotTheSecretPath(): void
    {
        $this->assertSame('Webhook https://hooks.example.com answered 500', self::sendError(new Alerts\Webhook('https://hooks.example.com/services/s3cret-token?key=abc', http: new FakeHttp(500)), self::alertJ()));
        $this->assertSame('http://localhost:8080', Shared::origin('http://user:pw@LOCALHOST:8080/x'));
        $this->assertSame('https://example.com', Shared::origin('https://example.com:443/x'));
        $this->assertSame('(invalid URL)', Shared::origin('not a url'));
    }

    public function testWebhookSignsTheRawBodyAndSendsTheAlertAsTheSdkDoes(): void
    {
        $http = new FakeHttp();
        (new Alerts\Webhook('https://hooks.example.com/cw', ['x-team' => 'billing'], 's3cret', $http))->send(self::alertJ('db'), self::context());
        $call = $http->requests[0];
        $this->assertSame('sha256=' . hash_hmac('sha256', $call['body'], 's3cret'), $call['headers']['x-cronwatch-signature']);
        $this->assertSame('cronwatch', $call['headers']['user-agent']);
        $this->assertSame('billing', $call['headers']['x-team']);
        $this->assertSame(['type', 'run', 'details', 'job', 'definition', 'title', 'message', 'at', 'triage'], array_keys(Js::plain(Js::parse($call['body']))));
        $this->assertSame(Js::stringify(self::alertJ('db')), $call['body']);
    }

    // ------------------------------------------------------------ through the client

    public function testAChannelSendsThroughTheClientLikeAnyOther(): void
    {
        $http = new FakeHttp();
        $cw = $this->make(['alerts' => [new Alerts\Datadog(apiKey: 'dd', http: $http)]]);
        $this->failing(fn () => $cw->job('nightly')->run(self::thrower('boom')));
        $this->assertCount(1, $http->requests);
        $this->assertSame('https://api.datadoghq.com/api/v1/events', $http->requests[0]['url']);
        $this->assertSame('error', Js::parse($http->requests[0]['body'])->alert_type);
    }

    public function testChannelsGetAContextAndOneArgumentChannelsStillWork(): void
    {
        $seen = [];
        $cw = $this->make(['alerts' => [
            new Custom('two', function (Alert $alert, ChannelContext $context) use (&$seen): void {
                $seen[] = $alert->type;
                $context->onError(new \RuntimeException('one recipient refused it'));
            }),
            new Custom('one', function (Alert $alert) use (&$seen): void {
                $seen[] = $alert->type;
            }),
        ]]);
        $this->failing(fn () => $cw->run('j', self::thrower('boom')));
        $this->assertSame(['failed', 'failed'], $seen);
        $this->assertSame(['alert channel two: one recipient refused it'], array_map(fn (array $e) => "{$e[1]}: {$e[0]->getMessage()}", $this->errors));
    }

    // ------------------------------------------------------------ the default Http

    public static function transports(): iterable
    {
        yield 'streams' => [false];
        yield 'curl' => [true];
    }

    private function http(bool $curl): NativeHttp
    {
        if ($curl && !extension_loaded('curl')) {
            $this->markTestSkipped('needs the curl extension');
        }
        return new NativeHttp($curl);
    }

    #[DataProvider('transports')]
    public function testTheDefaultHttpPostsToARealServer(bool $curl): void
    {
        $server = new LocalServer();
        try {
            (new Alerts\Webhook("{$server->url}/status/204?key=abc", secret: 'k', http: $this->http($curl)))->send(self::alertJ(), self::context());
            $request = $server->requests()[0];
            $this->assertSame('POST', $request['method']);
            $this->assertSame('/status/204?key=abc', $request['uri']);
            $this->assertSame('application/json', $request['headers']['content-type']);
            $this->assertSame('sha256=' . hash_hmac('sha256', $request['body'], 'k'), $request['headers']['x-cronwatch-signature']);
            $this->assertSame(Js::stringify(self::alertJ()), $request['body']);
        } finally {
            $server->stop();
        }
    }

    #[DataProvider('transports')]
    public function testNoChannelFollowsARedirectSoItsCredentialsNeverReachAnotherOrigin(bool $curl): void
    {
        $evil = new LocalServer();
        $provider = new LocalServer();
        try {
            $real = $this->http($curl);
            $to = rawurlencode("{$evil->url}/status/202");
            // Every channel's request goes to the redirecting server, whatever its URL.
            $http = new FakeHttp(answer: function (string $url, string $body, array $headers) use ($real, $provider, $to): array {
                $response = $real->post("{$provider->url}/redirect?to={$to}", $body, $headers);
                return [$response->status, $response->body];
            });
            $email = [...self::EMAIL, 'http' => $http];
            $channels = [
                new Alerts\Datadog(apiKey: 'dd-secret-key-123', http: $http),
                new Alerts\Resend(...$email, apiKey: 're_secret'),
                new Alerts\Postmark(...$email, serverToken: 'pm-secret'),
                new Alerts\Sendgrid(...$email, apiKey: 'SG.secret'),
                new Alerts\Mailgun(...$email, apiKey: 'key-secret', domain: 'mg.example.com'),
                new Alerts\Ses(...$email, region: 'us-east-1', accessKeyId: 'AKIDEXAMPLE', secretAccessKey: 'sekret-sekret'),
                new Alerts\Twilio(accountSid: 'AC1', authToken: 'tw-secret', from: '+1', to: '+2', http: $http),
                new Alerts\Sentry(dsn: 'https://pubkey@o1.ingest.sentry.io/42', http: $http),
                new Alerts\Honeybadger(apiKey: 'hb-secret', http: $http),
                new Alerts\Rollbar(accessToken: 'rb-secret', http: $http),
                new Alerts\Bugsnag(apiKey: 'bs-secret', http: $http),
                new Alerts\NewRelic(accountId: '1', apiKey: 'nr-secret', http: $http),
                new Alerts\Webhook('https://hooks.example.com/in', ['authorization' => 'Bearer wh-secret'], 's', $http),
                new Alerts\Slack('https://hooks.slack.example/in', http: $http),
                new Alerts\Discord('https://discord.example/in', http: $http),
            ];
            foreach ($channels as $channel) {
                $this->assertStringContainsString('answered 307', self::sendError($channel));
            }
            $this->assertCount(count($channels), $provider->requests());
            $this->assertSame([], $evil->requests(), 'nothing reached the other origin');
        } finally {
            $evil->stop();
            $provider->stop();
        }
    }

    /**
     * The deadline is the whole request's, as AbortSignal.timeout(10_000) is:
     * a body dripping in stops at the deadline, and the status is kept with
     * an empty body, as the SDK reads it.
     */
    #[DataProvider('transports')]
    public function testTheDefaultHttpHasAWholeRequestDeadline(bool $curl): void
    {
        $server = new LocalServer();
        try {
            $started = hrtime(true);
            $response = $this->http($curl)->post("{$server->url}/drip", '{}', [], 1000);
            $this->assertLessThan(2.5, (hrtime(true) - $started) / 1e9);
            $this->assertSame(500, $response->status);
            $this->assertSame('', $response->body);
        } finally {
            $server->stop();
        }
    }

    #[DataProvider('transports')]
    public function testTheDefaultHttpThrowsWhenNoAnswerComesBeforeTheDeadline(bool $curl): void
    {
        $server = new LocalServer();
        try {
            $started = hrtime(true);
            try {
                $this->http($curl)->post("{$server->url}/hang", '{}', [], 500);
                $this->fail('expected a timeout');
            } catch (RequestTimeout $error) {
                $this->assertSame('The operation was aborted due to timeout', $error->getMessage());
            }
            $this->assertLessThan(2, (hrtime(true) - $started) / 1e9);
        } finally {
            $server->stop();
        }
    }

    #[DataProvider('transports')]
    public function testTheDefaultHttpTrimsHeaderValuesAndRefusesALineBreakInside(bool $curl): void
    {
        $server = new LocalServer();
        try {
            $http = $this->http($curl);
            $this->assertSame(204, $http->post("{$server->url}/status/204", '{}', ['authorization' => " Bearer abc\n", 'x-key' => "\tk\r\n"])->status);
            $headers = $server->requests()[0]['headers'];
            $this->assertSame('Bearer abc', $headers['authorization']);
            $this->assertSame('k', $headers['x-key']);
            $this->expectException(\InvalidArgumentException::class);
            $http->post("{$server->url}/status/204", '{}', ['x-evil' => "a\r\nX-Injected: 1"]);
        } finally {
            $server->stop();
        }
    }

    public function testTheDefaultHttpGivesUpAfterTenSeconds(): void
    {
        $this->assertSame(10_000, NativeHttp::TIMEOUT_MS);
        $http = new FakeHttp();
        (new Alerts\Slack('https://hooks.slack.example/x', http: $http))->send(self::failed(), self::context());
        $this->assertSame(10_000, $http->requests[0]['timeoutMs']);
    }

    public function testAWebhookUrlThatCannotBePostedToIsRefusedWithoutQuotingIt(): void
    {
        $secretPath = implode('/', ['services', 'T0', 'B0', 'not' . 'areal' . 'secret']);
        $cases = ["hooks.example.com/{$secretPath}" => 'this URL', "ftp://hooks.example.com/{$secretPath}" => 'ftp:', "https://hooks.example.com/{$secretPath} x" => 'this URL'];
        $http = new FakeHttp();
        foreach ($cases as $url => $shown) {
            foreach ([new Alerts\Slack($url, http: $http), new Alerts\Discord($url, http: $http), new Alerts\Webhook($url, http: $http)] as $channel) {
                try {
                    $channel->send(self::failed(), self::context());
                    $this->fail("{$channel->name()} posted to {$shown}");
                } catch (\InvalidArgumentException $error) {
                    $this->assertSame("only http and https URLs can be posted to, not {$shown}", $error->getMessage(), $channel->name());
                    $this->assertStringNotContainsString($secretPath, $error->getMessage());
                }
            }
            // The default Http refuses it too, on the curl path and on the stream path.
            foreach (extension_loaded('curl') ? [true, false] : [false] as $curl) {
                try {
                    (new NativeHttp($curl))->post($url, '{}', []);
                    $this->fail("NativeHttp posted to {$shown}");
                } catch (\InvalidArgumentException $error) {
                    $this->assertSame("only http and https URLs can be posted to, not {$shown}", $error->getMessage());
                }
            }
        }
        $this->assertSame([], $http->requests, 'nothing was sent');
        // A stray newline or space around a pasted URL is dropped, as fetch drops it, so it still posts.
        (new Alerts\Slack("  https://hooks.example.com/{$secretPath}\n", http: $http))->send(self::failed(), self::context());
        $this->assertSame("https://hooks.example.com/{$secretPath}", $http->requests[0]['url']);
        $this->assertSame('https://hooks.example.com', Alerts\Shared::origin("https://hooks.example.com/{$secretPath}\n"));
        $this->assertSame('https://hooks.example.com', Alerts\Shared::origin("https://hooks.exa\tmple.com/x"), 'a tab inside is dropped, as the URL parser drops it');
    }

    public function testANetworkErrorNamesOnlyTheUrlsOrigin(): void
    {
        $secretPath = implode('/', ['hooks', 'not' . 'areal' . 'secret']);
        $probe = stream_socket_server('tcp://127.0.0.1:0');
        $name = (string) stream_socket_get_name($probe, false);
        fclose($probe);
        $url = "http://{$name}/{$secretPath}?token=" . 'not' . 'real';
        foreach (extension_loaded('curl') ? [true, false] : [false] as $curl) {
            try {
                (new NativeHttp($curl))->post($url, '{}', [], 2000);
                $this->fail('a closed port answered');
            } catch (\RuntimeException $error) {
                $this->assertStringNotContainsString($secretPath, $error->getMessage(), $curl ? 'curl' : 'streams');
                $this->assertStringNotContainsString('notreal', $error->getMessage());
            }
        }
        $this->assertSame('boom at https://h.example (x)', Alerts\Shared::scrub('boom at https://u:p@h.example/a/b?c=d (x)', 'https://u:p@h.example/a/b?c=d'));
    }

    public function testAChannelGivenNoHttpUsesTheTransportsDefault(): void
    {
        $this->assertInstanceOf(NativeHttp::class, Alerts\Transport::default());
        $http = new FakeHttp();
        Alerts\Transport::set($http);
        try {
            (new Alerts\Slack('https://hooks.slack.example/x'))->send(self::failed(), self::context());
            (new Alerts\Webhook('https://hooks.example.com/in'))->send(self::failed(), self::context());
            $this->assertSame(['https://hooks.slack.example/x', 'https://hooks.example.com/in'], array_column($http->requests, 'url'));
        } finally {
            Alerts\Transport::set(null);
        }
        $this->assertInstanceOf(NativeHttp::class, Alerts\Transport::default());
    }
}
