"""Replays packages/ruby/test/web/golden.json, the SDK routes' answers to a
fixed seed (written by golden.mjs), against cronwatch.web seeded the same way,
and compares status, headers and body byte for byte. Run ids are random on
both sides, so each becomes <id:N> in order of first appearance. The gem's
test/web_golden_test.rb replays the same file."""

from __future__ import annotations

import base64
import json
import re
from pathlib import Path
from typing import Any

import pytest

from cronwatch import Cronwatch, Custom
from cronwatch.stores import MemoryStore
from cronwatch.web import Request, Web

from helpers import DAY, HOUR, MIN, T0, Clock, send

GOLDEN = Path(__file__).resolve().parents[2] / "ruby" / "test" / "web" / "golden.json"
UUID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
RUN = re.compile(r"\{run:([^:}]+):(\d+)\}")
# The one header the SDK leaves to the server.
IGNORED_HEADERS = {"content-length"}


def quietly(fn: Any) -> None:
    try:
        fn()
    except Exception:
        pass  # A failed run is part of the seed.


def seed() -> Cronwatch:
    """The seed in golden.mjs, step for step."""
    clock = Clock()
    cw = Cronwatch(now=clock.now, store=MemoryStore(), alerts=[Custom("capture", lambda alert: None)], cron_secret=None)
    nightly = cw.job(
        "nightly-report",
        schedule="0 2 * * *",
        timezone="UTC",
        grace="15m",
        max_duration="10m",
        budget={"cost": 2},
        expect="Report written",
        failures_before_alert=2,
        description="Builds the <b>PDF</b>",
        tags=["reports", "<t>"],
    )
    durations = [2000, 2500, 90_000, 3100, 1800]
    for i, duration in enumerate(durations):
        clock.set(T0 - (5 - i) * DAY - 7 * HOUR - 30 * MIN)

        def work(job: Any, i: int = i, duration: int = duration) -> None:
            job.log("Wrote nothing" if i == 3 else "Report written:", f"report-{i}.pdf")
            job.metric("cost", 2.5 if i == 4 else 1.2)
            job.metric("rows", 40 + i)
            job.metric("2", 0.123456)
            clock.advance(duration)

        quietly(lambda work=work: nightly.run(work))

    broken = cw.job("broken", expect="done")
    clock.set(T0 - 2 * HOUR)

    def half_way(job: Any) -> None:
        job.log("half way <script>alert(1)</script>")
        clock.advance(450)

    quietly(lambda: broken.run(half_way))

    sync = cw.job("sync-users", schedule="*/15 * * * *", grace=60_000, timeout="5m")
    clock.set(T0 - 3 * HOUR)
    quietly(lambda: sync.run(lambda job: clock.advance(12_345) and None))

    cw.job("never-ran", schedule="0 * * * *")

    # A run as a foreign or damaged row could hold it: started before the
    # year 1, so the pages write it in words rather than as a date.
    far_back = cw.job("far-back", timeout="5m", expect="far")
    clock.set(-62_135_596_800_001)
    quietly(lambda: far_back.run(lambda job: clock.advance(1000) and None))
    clock.set(T0)
    return cw


def golden() -> dict[str, Any]:
    data: dict[str, Any] = json.loads(GOLDEN.read_text())
    return data


def replay(cw: Cronwatch, web: Any, capture: dict[str, Any], deliver: Any) -> tuple[int, dict[str, str], bytes]:
    path = RUN.sub(lambda m: cw.runs(m.group(1), 50)[int(m.group(2))].id, capture["path"])
    return deliver(web, capture["method"], path, capture["headers"], capture["body"])


def through_wsgi(web: Any, method: str, path: str, headers: dict[str, str], body: str | None) -> tuple[int, dict[str, str], bytes]:
    res = send(web, method, path, headers, body)
    return res.status, res.headers, res.body


def through_handle(web: Web, method: str, path: str, headers: dict[str, str], body: str | None) -> tuple[int, dict[str, str], bytes]:
    target, _, query = path.partition("?")
    res = web.handle(Request(method, target, query, {k.lower(): v for k, v in headers.items()}, (body or "").encode(), "http://app.test"))
    return res.status, res.headers, res.body


@pytest.mark.parametrize("deliver", [through_wsgi, through_handle], ids=["wsgi", "handle"])
def test_the_json_api_and_pages_match_the_sdk_routes(deliver: Any) -> None:
    data = golden()
    assert data["t0"] == T0
    assert len(data["captures"]) == 59
    cw = seed()
    web = cw.routes(token="tok", base_path="/cronwatch")
    ids: dict[str, str] = {}

    def number(match: re.Match[str]) -> str:
        return ids.setdefault(match.group(0), f"<id:{len(ids)}>")

    for capture in data["captures"]:
        label = f"{capture['method']} {capture['path']}"
        status, headers, raw = replay(cw, web, capture, deliver)
        if headers.get("content-type") == "image/png":
            # PNGs are kept as base64, so the fixture stays text.
            body = "base64:" + base64.b64encode(raw).decode()
        else:
            body = UUID.sub(number, raw.decode("utf-8"))
        assert status == capture["status"], label
        shown = {k: v for k, v in headers.items() if k not in IGNORED_HEADERS}
        assert shown == capture["responseHeaders"], label
        assert body == capture["responseBody"], label
