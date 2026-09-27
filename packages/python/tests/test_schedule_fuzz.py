"""The croner port against croner itself: thousands of generated cron
expressions (valid and not, in zones with and without daylight saving, from
times around the clock changes) answered by the SDK in Node and by this
package, which must agree on every error message and every fire time.
Seeded, so a failure repeats. Needs node and the built SDK, like
test_node_compat.py; skipped, with the reason, without them."""

from __future__ import annotations

import json
import random
import subprocess
from pathlib import Path
from typing import Any

import pytest

from cronwatch import schedule
from cronwatch._js import date_utc, iso

from test_node_compat import _unavailable

HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "schedule_fuzz.mjs"

pytestmark = pytest.mark.skipif(_unavailable() is not None, reason=f"croner parity: {_unavailable()}")

ZONES = [None, "UTC", "America/New_York", "Europe/London", "Australia/Lord_Howe", "America/Santiago", "Asia/Kolkata", "Pacific/Chatham", "Europe/Berlin"]
MONTHS = ["jan", "FEB", "Mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
DAYS = ["sun", "MON", "Tue", "wed", "thu", "fri", "sat"]
NICKNAMES = ["@yearly", "@annually", "@monthly", "@weekly", "@daily", "@midnight", "@hourly", "@HOURLY", "@reboot", "@every"]


def field(rng: random.Random, low: int, high: int, names: list[str] | None = None) -> str:
    """One cron field: mostly valid, sometimes out of range or malformed."""
    size = high - low + 1

    def value() -> str:
        if names and rng.random() < 0.3:
            return rng.choice(names)
        if rng.random() < 0.05:
            return str(rng.choice([high + 1, low - 1, 99]))
        return str(rng.randint(low, high))

    kind = rng.random()
    if kind < 0.3:
        return "*"
    if kind < 0.45:
        return value()
    if kind < 0.6:
        a, b = sorted((rng.randint(low, high), rng.randint(low, high)))
        if rng.random() < 0.05:
            a, b = b + 1, a
        return f"{a}-{b}"
    if kind < 0.75:
        return f"*/{rng.choice([1, 2, 3, 5, 7, 10, 15, 30, size, size + 1, 0])}"
    if kind < 0.85:
        a, b = sorted((rng.randint(low, high), rng.randint(low, high)))
        return f"{a}-{b}/{rng.randint(1, max(1, size // 2))}"
    if kind < 0.97:
        return ",".join(value() for _ in range(rng.randint(2, 4)))
    return rng.choice(["?", "x", "", "5/15", "/5", "1-", "-1"])


def day_of_month(rng: random.Random) -> str:
    kind = rng.random()
    if kind < 0.1:
        return rng.choice(["L", "LW", "15W", "1W", "31W", "5L", "L,15"])
    if kind < 0.2:
        return "?"
    return field(rng, 1, 31)


def day_of_week(rng: random.Random) -> str:
    kind = rng.random()
    if kind < 0.1:
        return f"{rng.randint(0, 7)}#{rng.randint(0, 6)}"
    if kind < 0.18:
        return f"{rng.randint(0, 6)}L"
    if kind < 0.24:
        return "+" + field(rng, 0, 7, DAYS)
    if kind < 0.3:
        return f"{rng.choice(DAYS)}-{rng.choice(DAYS)}"
    return field(rng, 0, 7, DAYS)


def expression(rng: random.Random) -> str:
    if rng.random() < 0.05:
        return rng.choice(NICKNAMES)
    parts = [field(rng, 0, 59), field(rng, 0, 23), day_of_month(rng), field(rng, 1, 12, MONTHS), day_of_week(rng)]
    if rng.random() < 0.25:
        parts.insert(0, field(rng, 0, 59))
    if rng.random() < 0.02:
        parts.append("*")
    return " ".join(parts)


# Around the nights clocks change in the zones above, and ordinary days.
STARTS = [
    date_utc(2026, 2, 8, 6, 30),
    date_utc(2026, 10, 1, 5, 10),
    date_utc(2026, 2, 29, 0, 45),
    date_utc(2026, 9, 25, 0, 50),
    date_utc(2026, 9, 3, 15, 20),
    date_utc(2026, 3, 4, 14, 55),
    date_utc(2026, 0, 5, 9, 30),
    date_utc(2027, 1, 27, 23, 59, 59),
    date_utc(2028, 1, 28, 12),
]


def cases(seed: int, count: int) -> list[dict[str, Any]]:
    rng = random.Random(seed)
    out = []
    for _ in range(count):
        start = rng.choice(STARTS) + rng.randint(-3, 3) * 3_600_000 + rng.randint(0, 3_599) * 1000 + rng.choice([0, 0, 500, 999])
        out.append({"schedule": expression(rng), "timezone": rng.choice(ZONES), "from": start, "count": rng.randint(1, 6)})
    return out


def python_answer(case: dict[str, Any]) -> dict[str, Any]:
    try:
        parsed = schedule.parse_schedule(case["schedule"], case["timezone"])
    except ValueError as error:
        return {"error": str(error)}
    fires: list[int | None] = []
    t: int | None = case["from"]
    for _ in range(case["count"]):
        t = schedule.next_fire(parsed, t, None)  # type: ignore[arg-type]
        fires.append(t)
        if t is None:
            break
    return {"fires": fires}


@pytest.mark.parametrize("seed", [1, 2, 3])
def test_the_port_agrees_with_croner(seed: int, tmp_path: Path) -> None:
    generated = cases(seed, 1000)
    file = tmp_path / "cases.json"
    file.write_text(json.dumps(generated), "utf-8")
    done = subprocess.run(["node", str(SCRIPT), str(file)], capture_output=True, text=True, encoding="utf-8", check=False)
    assert done.returncode == 0, done.stderr
    expected = json.loads(done.stdout)
    differences = []
    parsed = 0
    for case, want in zip(generated, expected, strict=True):
        got = python_answer(case)
        parsed += "fires" in want
        if "throws" in want:
            # croner walks by recursion, a year at a time, so a date no month
            # has (February 30) runs out of stack before the year 3000. The
            # port walks in a loop and finds nothing: the schedule never fires.
            n = len(want["fires"])
            if got.get("fires", [])[: n + 1] != [*want["fires"], None]:
                differences.append(f"{case}\n    croner threw {want['throws']} after {want['fires']}\n    python {got}")
            continue
        if got != want:
            show = {k: [iso(t) if t is not None else None for t in v] if k == "fires" else v for k, v in {**want}.items()}
            mine = {k: [iso(t) if t is not None else None for t in v] if k == "fires" else v for k, v in {**got}.items()}
            differences.append(f"{case}\n    croner {show}\n    python {mine}")
    assert not differences, f"{len(differences)} of {len(generated)} differ:\n" + "\n".join(differences[:10])
    assert parsed > 300, "enough of the generated expressions are valid to exercise the walk"
