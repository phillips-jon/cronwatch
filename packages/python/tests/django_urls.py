"""The URLconf of tests/test_django.py's project: the dashboard under a prefix
of two parts, and a job's handler() (plain and async) as views."""

from django.urls import include, path

import cronwatch

#: The client the handler views record to (test_django.py reads its runs).
handler_client = cronwatch.Cronwatch(alerts=[], cron_secret="s3cret")


def _work(ctx: cronwatch.JobContext, request: object) -> None:
    ctx.log("via django", getattr(request, "path", "?"))


async def _async_work(ctx: cronwatch.JobContext, request: object) -> str:
    return "async via django"


urlpatterns = [
    path("ops/cronwatch/", include("cronwatch.django.urls")),
    path("cron/nightly", handler_client.job("django-nightly").handler(_work).django),
    path("cron/async", handler_client.job("django-async").handler(_async_work).django),
]
