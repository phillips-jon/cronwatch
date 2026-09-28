"""Where runs this process does not wrap come from. A source is anything
with ``name`` and ``sync(host)``: on every check the client calls sync with
itself as the host, and the source declares jobs (``host.job``), reads the
store (``host.store``), records the runs it found (``host.record_run``) and
reports problems (``host.on_error(error, where)``). sync returns the alerts
recording sent.

``cronwatch.sources.pgcron.PgCron`` reads pg_cron's jobs and runs."""
