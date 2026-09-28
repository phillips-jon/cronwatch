"""Serves cronwatch.web over HTTP for packages/mcp/test/python-web.test.ts,
which drives @cronwatch/mcp against it. Seeded like the MCP tests' own end to
end case: a "nightly" job with one good run and one failed one, and a fixed
clock. Mounted under /cronwatch the way a WSGI dispatcher mounts an app
(SCRIPT_NAME), so the routes read their base path from it. Standard library
only (wsgiref).

    uv run --project packages/python python packages/python/tests/web_server.py PORT

Alerts are printed as "alert <job> <type>" lines.
"""

from __future__ import annotations

import sys
from typing import Any
from wsgiref.simple_server import WSGIRequestHandler, make_server

import cronwatch
from cronwatch._js import date_utc
from cronwatch.stores import MemoryStore

MOUNT = "/cronwatch"


class Quiet(WSGIRequestHandler):
    def log_message(self, format: str, *args: Any) -> None:  # noqa: A002
        pass


def main() -> None:
    port = int(sys.argv[1])
    now = [date_utc(2026, 0, 5, 2)]
    channel = cronwatch.Custom("test", lambda alert: print(f"alert {alert.job} {alert.type}", flush=True))
    cw = cronwatch.Cronwatch(store=MemoryStore(), alerts=[channel], cron_secret=None, now=lambda: now[0])
    nightly = cw.job("nightly", schedule="0 2 * * *", timezone="UTC", grace="15m")
    nightly.run(lambda job: job.log("step 1"))
    now[0] += 60_000

    def fail(job: Any) -> None:
        job.log("step 2")
        raise RuntimeError("db down")

    try:
        nightly.run(fail)
    except RuntimeError:
        pass

    web = cw.routes(token="tok")

    def mounted(environ: dict[str, Any], start_response: Any) -> Any:
        path = environ.get("PATH_INFO", "")
        if path != MOUNT and not path.startswith(MOUNT + "/"):
            start_response("404 Not Found", [("content-type", "text/plain")])
            return [b"not found"]
        environ["SCRIPT_NAME"] = MOUNT
        environ["PATH_INFO"] = path[len(MOUNT) :]
        return web(environ, start_response)

    server = make_server("127.0.0.1", port, mounted, handler_class=Quiet)
    print(f"serving on {port} with wsgiref", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
