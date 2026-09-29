"""cronwatch.django in a Django project made here: settings, the dashboard
under the project's URLs, the cronwatch_check command and DEBUG as the
environment. CI runs this file on every supported Django series."""

from __future__ import annotations

import asyncio
import hashlib
import io
import json
import re
from collections.abc import Iterator
from typing import Any

import pytest

django = pytest.importorskip("django")

from django.conf import settings  # noqa: E402

if not settings.configured:
    settings.configure(
        DEBUG=False,
        SECRET_KEY="cronwatch-tests-only",
        ALLOWED_HOSTS=["testserver", "app.test"],
        ROOT_URLCONF="django_urls",
        INSTALLED_APPS=["cronwatch.django"],
        MIDDLEWARE=[
            "django.middleware.security.SecurityMiddleware",
            "django.middleware.common.CommonMiddleware",
            "django.middleware.csrf.CsrfViewMiddleware",
            "django.middleware.clickjacking.XFrameOptionsMiddleware",
        ],
        CRONWATCH={"TOKEN": "tok", "STORE": "cronwatch.stores.MemoryStore", "ALERTS": [], "CRON_SECRET": None},
    )
    django.setup()

from django.core.exceptions import ImproperlyConfigured  # noqa: E402
from django.core.management import call_command  # noqa: E402
from django.test import AsyncClient, Client, override_settings  # noqa: E402

import cronwatch  # noqa: E402
import cronwatch.django as cwdjango  # noqa: E402
from cronwatch import _env  # noqa: E402
from cronwatch.stores import MemoryStore  # noqa: E402
from cronwatch.web import Request  # noqa: E402

from helpers import boom, make, run_python  # noqa: E402

DIGEST = hashlib.sha256(b"cronwatch-cookie:tok").hexdigest()
BEARER = {"HTTP_AUTHORIZATION": "Bearer tok"}
BASE = "/ops/cronwatch"


@pytest.fixture(autouse=True)
def fresh(monkeypatch: pytest.MonkeyPatch) -> Iterator[None]:
    """Each test starts with no client made from the settings, and no environment named outside Django."""
    for name in ("CRONWATCH_ENV", "APP_ENV", "ENVIRONMENT", "CRONWATCH_TOKEN", "CRON_SECRET"):
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setattr(cronwatch, "_client", None)
    cwdjango.reset()
    yield
    cwdjango.reset()


def fixed() -> Any:
    """A client on a fixed clock with one good and one failed job, for CRONWATCH's CLIENT."""
    cw, clock, _ = make()
    cw.job("nightly", schedule="0 2 * * *", timezone="UTC").run(lambda ctx: ctx.log("Report written"))
    clock.advance(60_000)
    with pytest.raises(RuntimeError):
        cw.run("broken", boom("db down"))
    return cw


def test_the_dashboard_answers_under_its_prefix_with_a_client_made_from_the_settings() -> None:
    client = Client()
    empty = client.get(f"{BASE}/api/jobs", **BEARER)
    assert empty.status_code == 200
    assert empty["content-type"] == "application/json; charset=utf-8"
    assert empty.json() == {"ok": True, "jobs": []}
    cw = cwdjango.client()
    assert isinstance(cw.store, MemoryStore), "a dotted path to a class is made into the store"
    assert cw.alerts == []
    assert cronwatch.client() is cw, "and it is the process's client"
    cw.run("nightly", lambda ctx: None)
    assert [job["name"] for job in client.get(f"{BASE}/api/jobs", **BEARER).json()["jobs"]] == ["nightly"]
    assert client.get(f"{BASE}/api/jobs").status_code == 401


def test_pages_through_django_are_the_routes_pages_byte_for_byte() -> None:
    cw = fixed()
    with override_settings(CRONWATCH={"CLIENT": cw, "TOKEN": "tok"}):
        client = Client()
        for path in ["/", "/jobs/nightly", "/jobs/broken", "/jobs/nope", "/api/jobs", "/api/jobs/broken?runs=1", "/manifest.webmanifest", "/icons/icon-192.png"]:
            through = client.get(f"{BASE}{path}", **BEARER)
            target, _, query = path.partition("?")
            direct = cw.routes(token="tok", base_path=BASE).handle(
                Request("GET", f"{BASE}{target}", query, {"authorization": "Bearer tok"}, b"", "http://testserver")
            )
            assert through.status_code == direct.status, path
            assert through.content == direct.body, path
            for name, value in direct.headers.items():
                assert through[name] == value, (path, name)


def test_forms_post_without_a_django_csrf_token_and_a_cross_site_write_is_refused() -> None:
    cw = fixed()
    with override_settings(CRONWATCH={"CLIENT": cw, "TOKEN": "tok"}):
        client = Client(enforce_csrf_checks=True)
        client.cookies["cronwatch_token"] = DIGEST
        form = client.post(
            f"{BASE}/jobs/nightly/silence",
            "for=2h",
            content_type="application/x-www-form-urlencoded",
            HTTP_ORIGIN="http://testserver",
            HTTP_REFERER=f"http://testserver{BASE}/jobs/nightly",
        )
        assert form.status_code == 303
        assert form["location"] == f"http://testserver{BASE}/jobs/nightly"
        assert cw.job_summary("nightly").silenced_until == cw.now() + 2 * 3_600_000
        refused = client.post(f"{BASE}/jobs/nightly/unsilence", HTTP_ORIGIN="https://evil.example")
        assert refused.status_code == 403
        assert b"Cross-site request refused" in refused.content
        assert cw.job_summary("nightly").silenced_until is not None
        check = client.post(f"{BASE}/api/check", content_type="application/json", **BEARER)
        assert check.json()["ok"] is True


def test_sign_in_moves_the_token_into_a_cookie_scoped_to_the_prefix() -> None:
    res = Client().get(f"{BASE}/jobs/x?token=tok&view=all")
    assert res.status_code == 303
    assert res["location"] == f"{BASE}/jobs/x?view=all"
    # The routes' own Set-Cookie header, as the SDK writes it, rather than Django's cookie jar.
    assert res["set-cookie"] == f"cronwatch_token={DIGEST}; Path={BASE}; HttpOnly; SameSite=Lax; Max-Age=2592000"


def test_through_djangos_wsgi_handler_the_raw_path_and_the_cookie_header_arrive() -> None:
    from django.core.handlers.wsgi import WSGIHandler

    from helpers import send

    handler = WSGIHandler()
    res = send(handler, "GET", f"http://testserver{BASE}/?token=tok")
    assert res.status == 303
    assert res.headers["set-cookie"] == f"cronwatch_token={DIGEST}; Path={BASE}; HttpOnly; SameSite=Lax; Max-Age=2592000"
    # A bad escape, sent as it was (RAW_URI), is the routes' 400 as in the SDK.
    assert send(handler, "GET", f"http://testserver{BASE}/api/jobs/%zz", {"authorization": "Bearer tok"}).status == 400


def test_the_prefix_without_its_slash_is_redirected_by_django() -> None:
    res = Client().get(BASE)
    assert res.status_code == 301
    assert res["location"] == f"{BASE}/"


def test_base_path_and_origin_come_from_the_settings() -> None:
    with override_settings(CRONWATCH={"TOKEN": "tok", "BASE_PATH": "/elsewhere/", "ORIGIN": "https://app.example.com"}):
        res = Client().get(f"{BASE}/?token=tok")
        assert res["location"] == f"{BASE}/"
        assert res["set-cookie"].endswith("; Path=/elsewhere; HttpOnly; SameSite=Lax; Max-Age=2592000; Secure"), "the public origin is https"


def test_debug_is_the_development_environment(capsys: pytest.CaptureFixture[str], monkeypatch: pytest.MonkeyPatch) -> None:
    with override_settings(DEBUG=True, CRONWATCH={"CLIENT": fixed()}):
        assert _env.is_development()
        page = Client().get(f"{BASE}/")
        assert page.status_code == 401
        assert b"The sign-in link is in the server log" in page.content
        line = capsys.readouterr().out.strip()
        match = re.fullmatch(
            rf"\[cronwatch\] CRONWATCH_TOKEN is not set, so this development server made a token for the dashboard\. Sign in: {re.escape(BASE)}/\?token=([A-Za-z0-9_-]{{43}})"
            r" on this server \(the first request's host is not local, so the link leaves it out\)",
            line,
        )
        assert match, "testserver is not a loopback host, so the line leaves it out"
        token = match.group(1)
        assert Client().get(f"{BASE}/api/jobs", HTTP_AUTHORIZATION=f"Bearer {token}").status_code == 200
        monkeypatch.setenv("CRONWATCH_ENV", "production")
        assert not _env.is_development(), "an environment variable still wins"
    with override_settings(DEBUG=False, CRONWATCH={"CLIENT": fixed()}):
        assert _env.is_production()
        locked = Client().get(f"{BASE}/api/jobs")
        assert locked.status_code == 503
        assert locked.json() == {"ok": False, "error": "CRONWATCH_TOKEN is not set"}


def test_the_cronwatch_check_command_runs_one_check() -> None:
    cw = fixed()
    with override_settings(CRONWATCH={"CLIENT": cw}):
        out = io.StringIO()
        call_command("cronwatch_check", stdout=out)
        assert out.getvalue() == "cronwatch: checked 2 jobs, sent 0 alerts\n"
        quiet = io.StringIO()
        call_command("cronwatch_check", stdout=quiet, verbosity=0)
        assert quiet.getvalue() == ""
    one, _, _ = make()
    one.run("only", lambda ctx: None)
    with override_settings(CRONWATCH={"CLIENT": one}):
        out = io.StringIO()
        call_command("cronwatch_check", stdout=out)
        assert out.getvalue() == "cronwatch: checked 1 job, sent 0 alerts\n"


def test_settings_take_dotted_paths_and_refuse_unknown_keys() -> None:
    with override_settings(CRONWATCH={"STORE": MemoryStore(), "ALERTS": ["cronwatch.Console"], "RETENTION": "7d", "CRON_SECRET": "s3cret"}):
        cw = cwdjango.client()
        assert isinstance(cw.alerts[0], cronwatch.Console)
        assert cw.retention_ms == 7 * 86_400_000
        assert cw.cron_secret == "s3cret"
        assert Client().get(f"{BASE}/api/check", HTTP_AUTHORIZATION="Bearer s3cret").status_code == 503, "no token outside development"
    with override_settings(CRONWATCH={"TOKEN": "tok", "STORAGE": "x"}):
        with pytest.raises(ImproperlyConfigured, match="CRONWATCH has 'STORAGE'"):
            cwdjango.client()
    with override_settings(CRONWATCH={"TOKEN": "tok"}):
        assert cwdjango.client() is cronwatch.client(), "no client options: the process's client"


def test_the_dashboard_answers_under_django_asgi_too() -> None:
    cw = fixed()
    with override_settings(CRONWATCH={"CLIENT": cw, "TOKEN": "tok"}):
        res = asyncio.run(AsyncClient().get(f"{BASE}/api/jobs/broken", headers={"authorization": "Bearer tok"}))
        assert res.status_code == 200
        body = json.loads(res.content)
        assert body["job"]["health"] == "failing"
        assert body["runs"][0]["error"].startswith("RuntimeError: db down")
        signed_in = AsyncClient()
        signed_in.cookies["cronwatch_token"] = DIGEST
        page = asyncio.run(signed_in.get(f"{BASE}/jobs/broken"))
        assert page.status_code == 200
        assert f'<link rel="manifest" href="{BASE}/manifest.webmanifest">'.encode() in page.content


def test_a_job_handler_is_a_django_view_exempt_from_csrf_plain_or_async() -> None:
    from django_urls import handler_client

    client = Client(enforce_csrf_checks=True)
    ok = client.post("/cron/nightly", HTTP_AUTHORIZATION="Bearer s3cret")
    assert ok.status_code == 200, "the bearer secret, not a CSRF token"
    assert ok["content-type"] == "application/json; charset=utf-8"
    assert ok.json()["job"] == "django-nightly"
    assert handler_client.runs("django-nightly")[0].output == "via django /cron/nightly"
    assert client.get("/cron/nightly").status_code == 401
    res = asyncio.run(AsyncClient().get("/cron/async", headers={"authorization": "Bearer s3cret"}))
    assert res.status_code == 200
    assert handler_client.runs("django-async")[0].output == "async via django"
    assert Client().get("/cron/async", HTTP_AUTHORIZATION="Bearer s3cret").status_code == 200, "an async view under WSGI too"


def test_each_apps_cronwatch_jobs_module_is_imported_at_startup(tmp_path: Any) -> None:
    """A project of its own, in a process of its own: a job declared in an
    app's cronwatch_jobs.py is known to cronwatch_check before it ever runs."""
    app = tmp_path / "reports"
    app.mkdir()
    (app / "__init__.py").write_text("")
    (app / "cronwatch_jobs.py").write_text(
        "from cronwatch.django import client\n\n"
        'nightly = client().job("nightly-report", schedule="0 2 * * *", timezone="UTC")\n'
    )
    (tmp_path / "settings.py").write_text(
        'SECRET_KEY = "cronwatch-tests-only"\n'
        'INSTALLED_APPS = ["cronwatch.django", "reports"]\n'
        'CRONWATCH = {"STORE": "cronwatch.stores.SqliteStore", "ALERTS": [], "CRON_SECRET": None}\n'
    )
    script = (
        "import os, django\n"
        'os.chdir(os.environ["WORK"])\n'
        "django.setup()\n"
        "from django.core.management import call_command\n"
        "import cronwatch.django\n"
        'call_command("cronwatch_check")\n'
        'print([job.name + ":" + str(job.health) for job in cronwatch.django.client().jobs()])\n'
    )
    done = run_python(script, tmp_path, DJANGO_SETTINGS_MODULE="settings")
    assert done.stdout.splitlines() == ["cronwatch: checked 1 job, sent 0 alerts", "['nightly-report:never_ran']"]
