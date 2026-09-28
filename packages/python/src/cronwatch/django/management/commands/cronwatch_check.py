"""`python manage.py cronwatch_check`: one check, for cron to call.

Looks for missed and stuck runs across every job, sends alerts, retries
undelivered ones and prunes old runs (cw.check()). Schedule it every few
minutes; nothing else notices a job that never ran.

    */5 * * * * cd /app && python manage.py cronwatch_check
"""

from __future__ import annotations

from typing import Any

from django.core.management.base import BaseCommand

from ... import client


class Command(BaseCommand):
    help = "Check for missed and stuck runs and send alerts (what cw.check() does)."

    def handle(self, *args: Any, **options: Any) -> None:
        result = client().check()
        if options.get("verbosity", 1) >= 1:
            jobs = len(result.jobs)
            alerts = len(result.alerts)
            self.stdout.write(f"cronwatch: checked {jobs} job{'' if jobs == 1 else 's'}, sent {alerts} alert{'' if alerts == 1 else 's'}")
