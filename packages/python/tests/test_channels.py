"""The channels beside the conformance replay (which checks every request
byte for byte), as the SDK's alerts.test.ts, channels-hardening.test.ts and
sigv4.test.ts have them: SigV4 against the AWS test suite, SMS fitting, the
options each channel refuses, failures that never name a secret, and the
default urllib path against local sockets (no redirect followed, one
deadline for the whole request, header values trimmed)."""

from __future__ import annotations

import hashlib
import hmac
import json
import socket
import threading
import time
import urllib.parse
from collections.abc import Callable
from typing import Any

import pytest

from cronwatch import AlertDraft, Cronwatch, JobDefinition, Run, _js, alerts
from cronwatch.alerts import _shared, email, sigv4, twilio
from cronwatch.alerts._http import RequestTimeout, UrllibHTTP
from cronwatch.format import compose_alert

from helpers import MIN, T0, Clock, make

A = alerts


class FakeHTTP:
    """Stands in for urllib: answers every request with `answer(url, body, headers)`, keeping each."""

    def __init__(self, status: int = 200, body: str = "", answer: Callable[[str, str, dict[str, str]], tuple[int, str]] | None = None) -> None:
        self.answer = answer or (lambda _u, _b, _h: (status, body))
        self.requests: list[dict[str, Any]] = []
        self._lock = threading.Lock()

    def post(self, url: str, body: str, headers: dict[str, str]) -> alerts.Response:
        with self._lock:
            self.requests.append({"url": url, "body": body, "headers": dict(headers)})
        status, text = self.answer(url, body, headers)
        return alerts.Response(status, text)


def failed(message: str = "Error: boom", triage: str | None = None, title: str | None = None, output: str | None = None) -> Any:
    run = Run(id="r1", job="nightly", status="failed", started_at=T0, finished_at=T0 + 1000, duration_ms=1000, error=message, output=output)
    alert = compose_alert(AlertDraft(type="failed", run=run, details={"consecutive_failures": 1, "threshold": 1}), JobDefinition({"name": "nightly"}), T0 + 2000)
    alert.message = message
    if title is not None:
        alert.title = title
    if triage is not None:
        alert.set_triage(triage)
    return alert


def recovered() -> Any:
    alert = failed()
    alert.type = "recovered"
    return alert


EMAIL = {"from_": "a@b.c", "to": "d@e.f"}


# ---------------------------------------------------------------- SigV4

# Cases from the AWS Signature Version 4 test suite, as packages/sdk/test/sigv4.test.ts has them.
SCOPE = "Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request"
STS_TOKEN = (
    "AQoDYXdzEPT//////////wEXAMPLEtc764bNrC9SAPBSM22wDOk4x4HIZ8j4FZTwdQWLWsKWHGBuFqwAeMicRXmxfpSPfIeoIYRqTflfKD8YUuwthAx7mSEI/"
    "qkPpKPi/kMcGdQrmGdeehM4IC1NtBmUpp2wUE8phUZampKsburEDy0KPkyQDYwT7WZ0wq5VSXDvp75YU9HFvlRd8Tx6q6fE8YQcHNVXAkiY9q6d+xo0rKwT38xVqr7ZD0u0iPPkUL64lIZbqBAz+"
    "scqKmlzm8FDrypNC9Yjc8fPOLn9FX9KSYvKTr4rvx3iSIlTJabIQwj2ICCR/oLxBA=="
)
SIGV4_CASES = [
    ("get-vanilla", "GET", "https://example.amazonaws.com/", {}, None,
     "SignedHeaders=host;x-amz-date, Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31"),
    ("post-vanilla", "POST", "https://example.amazonaws.com/", {}, None,
     "SignedHeaders=host;x-amz-date, Signature=5da7c1a2acd57cee7505fc6676e4e544621c30862966e37dddb68e92efbe5d6b"),
    ("get-vanilla-query-order-key-case", "GET", "https://example.amazonaws.com/?Param2=value2&Param1=value1", {}, None,
     "SignedHeaders=host;x-amz-date, Signature=b97d918cfa904a5beff61c982a1b6f458b799221646efd99d3219ec94cdf2500"),
    ("post-header-value-case", "POST", "https://example.amazonaws.com/", {"My-Header1": "VALUE1"}, None,
     "SignedHeaders=host;my-header1;x-amz-date, Signature=cdbc9802e29d2942e5e10b5bccfdd67c5f22c7c4e8ae67b53629efa58b974b7d"),
    ("post-sts-header-before", "POST", "https://example.amazonaws.com/", {}, STS_TOKEN,
     "SignedHeaders=host;x-amz-date;x-amz-security-token, Signature=85d96828115b5dc0cfc3bd16ad9e210dd772bbebba041836c64533a82be05ead"),
]  # fmt: skip


@pytest.mark.parametrize(("name", "method", "url", "headers", "token", "authorization"), SIGV4_CASES)
def test_sigv4_matches_the_aws_test_suite(name: str, method: str, url: str, headers: dict[str, str], token: str | None, authorization: str) -> None:
    now = _js.date_utc(2015, 7, 30, 12, 36)
    signed = sigv4.sign(method=method, url=url, headers=headers, body="", region="us-east-1", service="service", now=now,
                        access_key_id="AKIDEXAMPLE", secret_access_key="wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY", session_token=token)  # fmt: skip
    assert signed["authorization"] == f"AWS4-HMAC-SHA256 {SCOPE}, {authorization}"
    assert signed["x-amz-date"] == "20150830T123600Z"
    assert "host" not in signed, "urllib sets Host itself"
    if token:
        assert signed["x-amz-security-token"] == token


# ---------------------------------------------------------------- SMS

def test_sms_bodies_fit_their_segments_and_keep_the_link_whole() -> None:
    gsm = twilio.sms_body(failed("x" * 2000), "https://app.example/j")
    assert len(gsm) <= 459
    assert gsm.endswith("...\nhttps://app.example/j")
    ucs = twilio.sms_body(failed("\U0001f600" * 500), None)
    assert _js.length16(ucs) <= 201
    ucs.encode("utf-8")  # whole characters only
    assert twilio.sms_body(failed("one\ntwo"), None) == "nightly failed\none\ntwo"
    assert twilio.sms_body(failed("one", triage="db down"), None) == "nightly failed\none\nTriage: db down"
    # The extension table counts two: 80 braces are 160 septets, one segment; 81 are not.
    assert twilio.fits("{" * 80, 1)
    assert not twilio.fits("{" * 81, 1)
    assert twilio.fits("é" * 160, 1)
    assert not twilio.fits("ê" * 71, 1), "a character outside GSM-7 makes the message UCS-2"


def test_sms_bodies_stay_inside_twilios_1600_characters_and_pack_segments_as_phones_do() -> None:
    long = failed("x" * 3000, title="j failed")
    assert len(twilio.sms_body(long, None, 12)) <= 1530, "segments capped at 10"
    assert len(twilio.sms_body(long, None, float("nan"))) <= 459, "not a number: the default 3"
    assert len(twilio.sms_body(long, None, "5")) <= 459, "not a number: the default 3"
    assert len(twilio.sms_body(long, None, True)) <= 459, "not a number: the default 3"
    assert twilio.sms_segments("a" * 160) == 1
    assert twilio.sms_segments("a" * 161) == 2
    assert twilio.sms_segments("a" * 152 + "{" + "a" * 152) == 3, "an escape pair never straddles a segment"
    assert twilio.sms_segments(twilio.sms_body(failed(("a" * 152 + "{") * 3, title="t"), None, 3)) <= 3
    assert twilio.sms_segments("\U0001f600" * 35) == 1
    assert twilio.sms_segments("a" * 66 + "\U0001f600" + "a" * 66) == 3, "a surrogate pair never straddles a segment"
    huge = twilio.sms_body(failed("m"), "https://example.com/" + "p" * 2000, 10)
    assert _js.length16(huge) <= 1600


def test_twilio_tries_every_number_and_reports_how_many_failed_without_the_token() -> None:
    http = FakeHTTP(400, "tw-token rejected")
    channel = A.Twilio(account_sid="AC123", auth_token="tw-token", from_="+1", to=["+2", "+3"], http=http)
    with pytest.raises(RuntimeError) as error:
        channel.send(failed())
    assert str(error.value) == "Twilio https://api.twilio.com answered 400: [redacted] rejected (2 of 2 numbers failed)"
    assert len(http.requests) == 2
    A.Twilio(account_sid="AC1", auth_token="t", from_="+1", to="+2", http=http).send(recovered())
    assert len(http.requests) == 2, "recoveries are not texted by default"


def test_twilio_texts_every_number_at_once_one_taking_it_is_a_delivery_and_the_refusals_are_reported() -> None:
    sent: list[str] = []

    def answer(_url: str, body: str, _headers: dict[str, str]) -> tuple[int, str]:
        to = urllib.parse.parse_qs(body)["To"][0]
        if to == "+15550000000":
            return 400, '{"code":21211,"message":"Invalid To"}'
        sent.append(to)
        return 201, "{}"

    clock = Clock(_js.date_utc(2026, 0, 1))
    errors: list[str] = []
    cw = Cronwatch(now=clock.now, cron_secret=None, on_error=lambda e, where: errors.append(f"{where}: {e}"),
                   alerts=[A.Twilio(account_sid="AC1", auth_token="tok", from_="+15551112222", to=["+15553334444", "+15550000000"], http=FakeHTTP(answer=answer))])  # fmt: skip
    cw.job("nightly", schedule="0 * * * *")
    cw.check()
    for _ in range(6):
        clock.advance(70 * MIN)
        cw.check()
    assert sent == ["+15553334444"], "one SMS for one open missed condition, never resent"
    assert len(errors) == 1, errors
    assert errors[0].startswith("alert channel twilio: Twilio https://api.twilio.com answered 400: ")
    assert "Invalid To" in errors[0]
    assert errors[0].endswith("(to ********0000; 1 of 2 numbers took the alert)")

    # Every number refusing it is a failure, retried at the next check.
    with pytest.raises(RuntimeError, match=r"\(2 of 2 numbers failed\)\Z"):
        A.Twilio(account_sid="AC1", auth_token="tok", from_="+1", to=["+2", "+3"], http=FakeHTTP(500, "no")).send(failed())


def test_twilio_without_a_context_warns_for_each_refusal(capsys: pytest.CaptureFixture[str]) -> None:
    http = FakeHTTP(answer=lambda _u, body, _h: (400, "no") if "15550000000" in body else (201, "{}"))
    A.Twilio(account_sid="AC1", auth_token="tok", from_="+1", to=["+15553334444", "+15550000000"], http=http).send(failed())
    err = capsys.readouterr().err
    assert "[cronwatch] alert channel twilio: Twilio " in err
    assert "(to ********0000; 1 of 2 numbers took the alert)" in err


# ---------------------------------------------------------------- email

def test_email_content_and_addresses() -> None:
    mail = email.compose(failed('a <b>\n"q"'), from_="a@b.c", to=["x@y.z"], subject_prefix="[p]\n", link=lambda _a: "javascript:alert(1)")
    assert mail.subject == "[p]  nightly failed", "one line"
    assert "javascript:" not in mail.html
    assert "a &lt;b&gt;\n&quot;q&quot;" in mail.html
    assert email.parse_address('"Ops Team" <ops@example.com>') == {"email": "ops@example.com", "name": "Ops Team"}
    assert email.parse_address(" ops@example.com ") == {"email": "ops@example.com"}
    assert email.parse_address("<ops@example.com>") == {"email": "ops@example.com"}
    assert email.compose(failed(), from_="a@b.c", to=["x@y.z"], link=lambda _a: "HTTPS://app.example/j").text.endswith("Open: HTTPS://app.example/j")


def test_text_cut_for_a_subject_never_leaves_half_a_surrogate_pair() -> None:
    assert email.compose(failed(title="a" * 249 + "\U0001f600"), from_="a@b.c", to=["d@e.f"]).subject == "a" * 249


@pytest.mark.parametrize(
    ("make_channel", "message"),
    [
        (lambda: A.Resend(api_key="", **EMAIL), "needs an api_key"),
        (lambda: A.Resend(api_key="k", from_=None, to="x@y.z"), "needs a from address"),
        (lambda: A.Postmark(server_token="t", from_="a@b.c", to=[" ", None]), "needs at least one to address"),
        (lambda: A.Mailgun(api_key="k", domain="", **EMAIL), "needs a domain"),
        (lambda: A.Ses(region="US East", access_key_id="a", secret_access_key="b", **EMAIL), "region like us-east-1"),
        (lambda: A.Ses(region="us-east-1", access_key_id="a", secret_access_key="", **EMAIL), "secret_access_key"),
        (lambda: A.Twilio(account_sid="AC1", from_="+1", to="+2"), "auth_token"),
        (lambda: A.Twilio(account_sid="AC1", auth_token="t", to="+2"), "from number"),
        (lambda: A.Sentry(dsn="https://o1.ingest.sentry.io/42"), "dsn like"),
        (lambda: A.Sentry(dsn="not a url"), "valid dsn"),
        (lambda: A.Datadog(api_key="k", site="evil.com/x?y"), "site like"),
        (lambda: A.NewRelic(account_id="12a", api_key="k"), "numeric account_id"),
        (lambda: A.Rollbar(access_token=None), "access_token"),  # type: ignore[arg-type]
        (lambda: A.Slack(""), "webhook_url"),
        (lambda: A.Discord(None), "webhook_url"),  # type: ignore[arg-type]
        (lambda: A.Webhook(""), "url"),
        (lambda: A.Resend(api_key="  ", **EMAIL), "needs an api_key"),
    ],
)
def test_channels_refuse_what_they_cannot_send_with(make_channel: Callable[[], Any], message: str) -> None:
    with pytest.raises(ValueError, match=message):
        make_channel()


def test_sentry_reads_a_dsn() -> None:
    from cronwatch.alerts.sentry import parse_dsn

    dsn = parse_dsn("https://pub@o1.ingest.sentry.io/42")
    assert [dsn.endpoint, dsn.public_key] == ["https://o1.ingest.sentry.io/api/42/envelope/", "pub"]
    dsn = parse_dsn("https://p%40b@sentry.example.com:9000/prefix/7")
    assert [dsn.endpoint, dsn.public_key] == ["https://sentry.example.com:9000/prefix/api/7/envelope/", "p@b"]


def test_the_alert_id_is_stable_and_every_failure_hides_the_secret() -> None:
    assert _shared.alert_id(failed()) == _shared.alert_id(failed("other"))
    with pytest.raises(RuntimeError) as error:
        A.Honeybadger(api_key="hb-secret", http=FakeHTTP(401, "bad key hb-secret given")).send(failed())
    assert str(error.value) == "Honeybadger https://api.honeybadger.io answered 401: bad key [redacted] given"


@pytest.mark.parametrize(("body", "text"), [("﻿bom", "bom"), ("café � end", "café � end")])
def test_a_failure_body_loses_its_byte_order_mark(body: str, text: str) -> None:
    with pytest.raises(RuntimeError) as error:
        A.Honeybadger(api_key="k-secret", http=FakeHTTP(500, body)).send(failed())
    assert str(error.value) == f"Honeybadger https://api.honeybadger.io answered 500: {text}"


def test_response_text_reads_bytes_as_fetch_does() -> None:
    from cronwatch.alerts._http import text

    assert text(b"\xef\xbb\xbfbom") == "bom"
    assert text(b"caf\xc3\xa9 \xff end") == "café � end"


def test_a_secret_that_straddles_the_cut_in_a_providers_error_body_is_still_cut_out() -> None:
    # Built in pieces so no Mailgun-shaped literal is committed for secret scanners to flag.
    key = "key-" + "0123456789abcdef" + "0123456789abcdef"
    http = FakeHTTP(401, "x" * 180 + f"invalid key {key}")
    with pytest.raises(RuntimeError) as error:
        A.Mailgun(api_key=key, domain="mg.example.com", **EMAIL, http=http).send(failed())
    message = str(error.value)
    for i in range(len(key) - 5):
        assert key[i : i + 6] not in message, f"a piece of the key survives: {message}"
    assert message.endswith(": " + "x" * 180 + "invalid key [redacte"), "cut to 200 after the key was taken out"
    assert _shared.error_body("a" * 199 + "\U0001f600tail") == "a" * 199, "never half a surrogate pair"
    assert _shared.error_body("short") == "short"
    assert _shared.error_body("y" * 10 + "sekret" + "z" * 300, ["sekret"])[:20] == "y" * 10 + "[redacted]"
    assert len(_shared.error_body("z" * 300, ["sekret"])) == 200


def test_credentials_are_trimmed_before_they_go_in_a_header() -> None:
    http = FakeHTTP()
    A.Resend(api_key=" re_secret\n", **EMAIL, http=http).send(failed())
    A.Postmark(server_token="\tpm-secret ", **EMAIL, http=http).send(failed())
    A.Sendgrid(api_key="SG.secret\n", **EMAIL, http=http).send(failed())
    A.Mailgun(api_key=" key-secret ", domain="mg.example.com", **EMAIL, http=http).send(failed())
    A.Datadog(api_key="dd-secret\n", http=http).send(failed())
    A.Honeybadger(api_key=" hb-secret", http=http).send(failed())
    A.Rollbar(access_token="rb-secret \n", http=http).send(failed())
    A.Bugsnag(api_key="bs-secret\n", http=http).send(failed())
    A.NewRelic(account_id="1", api_key=" nr-secret", http=http).send(failed())
    A.Sentry(dsn=" https://pubkey@o1.ingest.sentry.io/42\n", http=http).send(failed())
    A.Twilio(account_sid=" AC1 ", auth_token="tok\n", from_="+1", to="+2", http=http).send(failed())
    A.Ses(region="us-east-1", access_key_id=" AKIDEXAMPLE", secret_access_key="sekret\n", **EMAIL, http=http).send(failed())
    A.Webhook("https://hooks.example.com/in", headers={"authorization": " Bearer wh-secret\n"}, http=http).send(failed())
    for request in http.requests:
        for name, value in request["headers"].items():
            assert value.strip() == value, f"{name} has spaces around it"
    headers = [r["headers"] for r in http.requests]
    assert headers[0]["authorization"] == "Bearer re_secret"
    assert headers[1]["x-postmark-server-token"] == "pm-secret"
    assert headers[4]["dd-api-key"] == "dd-secret"
    assert json.loads(http.requests[7]["body"])["apiKey"] == "bs-secret"
    assert http.requests[10]["url"] == "https://api.twilio.com/2010-04-01/Accounts/AC1/Messages.json"
    assert headers[10]["authorization"] == "Basic QUMxOnRvaw=="
    assert headers[11]["authorization"].startswith("AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/")
    assert headers[12]["authorization"] == "Bearer wh-secret"


# ---------------------------------------------------------------- Slack, Discord, webhook

RUN = Run(id="r1", job="j", status="failed", started_at=T0, finished_at=T0 + 1000, duration_ms=1000, error="Error: boom",
          output="before\n```\n@everyone <!channel> [click](https://evil.example)")  # fmt: skip


def alert_j(triage: str | None = None) -> Any:
    alert = compose_alert(AlertDraft(type="failed", run=RUN, details={"consecutive_failures": 1, "threshold": 1}), JobDefinition({"name": "j"}), T0 + 2000)
    if triage is not None:
        alert.set_triage(triage)
    return alert


def test_discord_keeps_job_output_inside_its_code_block_and_pings_no_one() -> None:
    http = FakeHTTP()
    A.Discord("https://discord.example/api/webhooks/1/secret", http=http).send(alert_j("See [the docs](https://evil.example) *now*"))
    body = json.loads(http.requests[0]["body"])
    assert body["allowed_mentions"] == {"parse": []}
    description = body["embeds"][0]["description"]
    assert description.count("```") == 2, "only the block's own fences"
    assert "**Triage:** See \\[the docs\\]\\(https://evil.example\\) \\*now\\*" in description
    assert list(body) == ["content", "allowed_mentions", "embeds"]
    assert list(body["embeds"][0]) == ["title", "description", "color", "timestamp"]
    assert body["embeds"][0]["timestamp"] == "2026-01-05T09:30:02.000Z"
    assert body["embeds"][0]["color"] == 0xC62828


def test_discord_adds_the_link_and_reports_a_refusal() -> None:
    http = FakeHTTP(400, "x" * 500)
    channel = A.Discord("https://discord.example/w", link=lambda a: f"https://app.example/{a.job}", http=http)
    with pytest.raises(RuntimeError, match="^Discord webhook answered 400: x{200}$"):
        channel.send(alert_j())
    assert json.loads(http.requests[0]["body"])["embeds"][0]["url"] == "https://app.example/j"


def test_slack_escapes_control_characters_and_fences_in_the_blocks_and_the_fallback_text() -> None:
    http = FakeHTTP()
    A.Slack("https://hooks.slack.example/T/B/secret", http=http).send(alert_j("<b> & co"))
    body = json.loads(http.requests[0]["body"])
    assert "<!channel>" not in body["text"]
    block = body["blocks"][1]["text"]["text"]
    assert block.count("```") == 2
    assert "&lt;!channel&gt;" in block
    assert block.endswith("```")
    assert body["blocks"][2]["text"]["text"] == "_Triage:_ &lt;b&gt; &amp; co"
    assert body["blocks"][0]["text"]["text"] == ":x: *j failed*"


def test_slack_link_and_failure() -> None:
    http = FakeHTTP(500, "no")
    channel = A.Slack("https://hooks.slack.example/x", link=lambda _a: "https://app.example/j", http=http)
    with pytest.raises(RuntimeError, match="^Slack webhook answered 500: no$"):
        channel.send(alert_j())
    assert json.loads(http.requests[0]["body"])["blocks"][0]["text"]["text"] == ":x: *j failed* (<https://app.example/j|open>)"


def test_webhook_failures_name_the_origin_not_the_secret_path() -> None:
    with pytest.raises(RuntimeError, match="^Webhook https://hooks.example.com answered 500$"):
        A.Webhook("https://hooks.example.com/services/s3cret-token?key=abc", http=FakeHTTP(500)).send(alert_j())
    assert _shared.origin("http://user:pw@LOCALHOST:8080/x") == "http://localhost:8080"
    assert _shared.origin("https://example.com:443/x") == "https://example.com"
    assert _shared.origin("not a url") == "(invalid URL)"


def test_webhook_signs_the_raw_body_and_sends_the_alert_as_the_sdk_does() -> None:
    http = FakeHTTP()
    A.Webhook("https://hooks.example.com/cw", secret="s3cret", headers={"x-team": "billing"}, http=http).send(alert_j("db"))
    call = http.requests[0]
    assert call["headers"]["x-cronwatch-signature"] == "sha256=" + hmac.new(b"s3cret", call["body"].encode(), hashlib.sha256).hexdigest()
    assert call["headers"]["user-agent"] == "cronwatch"
    assert call["headers"]["x-team"] == "billing"
    parsed = json.loads(call["body"])
    assert list(parsed) == ["type", "run", "details", "job", "definition", "title", "message", "at", "triage"]
    assert parsed["details"] == {"consecutiveFailures": 1, "threshold": 1}
    assert call["body"] == _js.dumps(alert_j("db").to_dict())


# ---------------------------------------------------------------- through the client

def test_a_channel_sends_through_the_client_like_any_other() -> None:
    http = FakeHTTP()
    cw, clock, _ = make(alerts=[A.Datadog(api_key="dd", http=http)])
    job = cw.job("nightly")

    def boom(_ctx: Any) -> None:
        raise RuntimeError("boom")

    with pytest.raises(RuntimeError):
        job.run(boom)
    assert len(http.requests) == 1
    assert http.requests[0]["url"] == "https://api.datadoghq.com/api/v1/events"
    assert json.loads(http.requests[0]["body"])["alert_type"] == "error"


def test_channels_get_a_context_and_one_argument_channels_still_work() -> None:
    errors: list[str] = []
    seen: list[str] = []

    def two(alert: Any, context: Any) -> None:
        seen.append(str(alert.type))
        context.on_error(RuntimeError("one recipient refused it"))

    class Plain:
        name = "plain"

        def __init__(self) -> None:
            self.got: list[str] = []

        def send(self, alert: Any) -> None:
            self.got.append(str(alert.type))

    plain = Plain()
    cw = Cronwatch(now=Clock().now, cron_secret=None, on_error=lambda e, where: errors.append(f"{where}: {e}"),
                   alerts=[A.Custom("two", two), A.Custom("one", lambda alert: seen.append(str(alert.type))), plain])  # fmt: skip
    with pytest.raises(RuntimeError):
        cw.run("j", lambda _ctx: (_ for _ in ()).throw(RuntimeError("boom")))
    assert seen == ["failed", "failed"]
    assert plain.got == ["failed"]
    assert errors == ["alert channel two: one recipient refused it"]


# ---------------------------------------------------------------- the default HTTP path


class LocalServer:
    """A server on 127.0.0.1 answering each request with `status` and `headers`, recording what it was sent."""

    def __init__(self, status: int, headers: dict[str, str] | None = None) -> None:
        self.sock = socket.socket()
        self.sock.bind(("127.0.0.1", 0))
        self.sock.listen(16)
        self.url = f"http://127.0.0.1:{self.sock.getsockname()[1]}"
        self.seen: list[tuple[str, bytes]] = []
        extra = "".join(f"{k}: {v}\r\n" for k, v in (headers or {}).items())
        self.reply = f"HTTP/1.1 {status} X\r\n{extra}Content-Length: 0\r\nConnection: close\r\n\r\n".encode()
        self.thread = threading.Thread(target=self._serve, daemon=True)
        self.thread.start()

    def _serve(self) -> None:
        while True:
            try:
                client, _ = self.sock.accept()
            except OSError:
                return
            with client:
                data = b""
                while b"\r\n\r\n" not in data:
                    chunk = client.recv(65536)
                    if not chunk:
                        break
                    data += chunk
                head, _, rest = data.partition(b"\r\n\r\n")
                length = next((int(line.split(b":")[1]) for line in head.split(b"\r\n") if line.lower().startswith(b"content-length:")), 0)
                while len(rest) < length:
                    rest += client.recv(65536)
                self.seen.append((head.decode("latin-1"), rest))
                client.sendall(self.reply)

    def close(self) -> None:
        self.sock.close()


def test_the_default_http_posts_to_a_real_server() -> None:
    server = LocalServer(204)
    try:
        A.Webhook(f"{server.url}/hook?key=abc", secret="k").send(alert_j())
        head, body = server.seen[0]
        assert head.startswith("POST /hook?key=abc HTTP/1.1\r\n")
        assert "\r\nContent-type: application/json" in head or "\r\ncontent-type: application/json" in head.lower()
        signature = hmac.new(b"k", body, hashlib.sha256).hexdigest()
        assert f"x-cronwatch-signature: sha256={signature}" in head.lower()
        assert body.decode() == _js.dumps(alert_j().to_dict())
    finally:
        server.close()


def test_no_channel_follows_a_redirect_so_its_credentials_never_reach_another_origin() -> None:
    evil = LocalServer(202)
    provider = LocalServer(307, {"Location": f"{evil.url}/steal"})
    try:
        real = UrllibHTTP(timeout=5)

        class Redirected:
            """Every channel's request goes to the redirecting server, whatever its URL."""

            def post(self, _url: str, body: str, headers: dict[str, str]) -> alerts.Response:
                return real.post(f"{provider.url}/in", body, headers)

        http = Redirected()
        channels = [
            A.Datadog(api_key="dd-secret-key-123", http=http),
            A.Resend(api_key="re_secret", **EMAIL, http=http),
            A.Postmark(server_token="pm-secret", **EMAIL, http=http),
            A.Sendgrid(api_key="SG.secret", **EMAIL, http=http),
            A.Mailgun(api_key="key-secret", domain="mg.example.com", **EMAIL, http=http),
            A.Ses(region="us-east-1", access_key_id="AKIDEXAMPLE", secret_access_key="sekret-sekret", **EMAIL, http=http),
            A.Twilio(account_sid="AC1", auth_token="tw-secret", from_="+1", to="+2", http=http),
            A.Sentry(dsn="https://pubkey@o1.ingest.sentry.io/42", http=http),
            A.Honeybadger(api_key="hb-secret", http=http),
            A.Rollbar(access_token="rb-secret", http=http),
            A.Bugsnag(api_key="bs-secret", http=http),
            A.NewRelic(account_id="1", api_key="nr-secret", http=http),
            A.Webhook(f"{provider.url}/in", headers={"authorization": "Bearer wh-secret"}, secret="s", http=http),
            A.Slack(f"{provider.url}/in", http=http),
            A.Discord(f"{provider.url}/in", http=http),
        ]
        for channel in channels:
            with pytest.raises(RuntimeError, match="answered 307"):
                channel.send(failed())
        assert len(provider.seen) == len(channels)
        assert evil.seen == [], "nothing reached the other origin"
    finally:
        evil.close()
        provider.close()


def test_the_default_http_has_a_whole_request_deadline() -> None:
    """The deadline is the whole request's, as AbortSignal.timeout(10_000) is:
    a body dripping in under each read timeout still stops at the deadline,
    and the status is kept with an empty body, as the SDK reads it."""
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    sock.listen(1)

    def drip() -> None:
        client, _ = sock.accept()
        with client:
            client.recv(65536)
            client.sendall(b"HTTP/1.1 500 Oops\r\nContent-Length: 30\r\nConnection: close\r\n\r\n")
            for _ in range(30):
                time.sleep(0.2)
                try:
                    client.sendall(b"x")
                except OSError:
                    return

    threading.Thread(target=drip, daemon=True).start()
    try:
        started = time.monotonic()
        response = UrllibHTTP(timeout=1).post(f"http://127.0.0.1:{sock.getsockname()[1]}/", "{}", {})
        assert time.monotonic() - started < 2.5
        assert response.status == 500
        assert response.body == ""
    finally:
        sock.close()


def test_the_default_http_raises_when_no_answer_comes_before_the_deadline() -> None:
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    sock.listen(4)
    held: list[socket.socket] = []

    def hold() -> None:
        try:
            while True:
                held.append(sock.accept()[0])
        except OSError:
            return

    threading.Thread(target=hold, daemon=True).start()
    try:
        started = time.monotonic()
        with pytest.raises(RequestTimeout, match="^The operation was aborted due to timeout$"):
            UrllibHTTP(timeout=0.5).post(f"http://127.0.0.1:{sock.getsockname()[1]}/", "{}", {})
        assert time.monotonic() - started < 2
    finally:
        for s in held:
            s.close()
        sock.close()


def test_the_default_http_trims_header_values() -> None:
    server = LocalServer(204)
    try:
        response = UrllibHTTP().post(f"{server.url}/", "{}", {"authorization": " Bearer abc\n", "x-key": "\tk\r\n"})
        assert response.status == 204
        head = server.seen[0][0].lower()
        assert "\r\nauthorization: bearer abc\r\n" in head
        assert "\r\nx-key: k\r\n" in head or head.endswith("\r\nx-key: k")
    finally:
        server.close()


def test_the_default_http_posts_only_to_http_and_https_and_never_quotes_the_url(tmp_path: Any) -> None:
    """urllib would open file: and ftp: URLs, and its errors for a URL it
    cannot read quote it whole, path and all: a webhook's credential."""
    secret_path = "/services/T0/B0/" + "hook" + "path" + "secret"
    target = tmp_path / "private.txt"
    target.write_text("not for a channel")
    for url in (f"file://{target}", "ftp://example.com/x", "hooks.slack.com" + secret_path, "javascript:alert(1)"):
        with pytest.raises(ValueError) as refused:
            UrllibHTTP(timeout=1).post(url, "{}", {})
        assert "only http and https" in str(refused.value)
        assert "hookpathsecret" not in str(refused.value) and "private" not in str(refused.value)
    with pytest.raises(ValueError) as invalid:
        UrllibHTTP(timeout=1).post("https://hooks.example.com" + secret_path + " x", "{}", {})
    assert str(invalid.value) == "cannot post to https://hooks.example.com: the URL is not valid"
    with pytest.raises(ValueError) as failed:
        A.Slack("https://hooks.example.com" + secret_path + " x").send(alert_j())
    assert "hookpathsecret" not in str(failed.value)


def test_the_default_http_reads_a_pasted_url_as_fetch_does() -> None:
    server = LocalServer(204)
    try:
        response = UrllibHTTP().post(f"  {server.url}/hook\n?key=abc\r\n", "{}", {})
        assert response.status == 204
        assert server.seen[0][0].startswith("POST /hook?key=abc HTTP/1.1\r\n")
    finally:
        server.close()


def test_a_header_value_with_a_line_break_is_refused_without_quoting_it() -> None:
    key = "key-" + "line" + "break" + "credential"
    with pytest.raises(ValueError) as refused:
        UrllibHTTP(timeout=1).post("https://127.0.0.1:9/", "{}", {"authorization": f"Bearer {key}\r\nx-injected: 1"})
    assert "authorization" in str(refused.value)
    assert "credential" not in str(refused.value)


def test_the_default_http_gives_up_after_ten_seconds() -> None:
    assert UrllibHTTP().timeout == 10
    assert A.Slack("https://hooks.slack.example/x")._http.timeout == 10  # type: ignore[attr-defined]
