=== CronWatch ===
Contributors: joncphillips
Tags: cron, wp-cron, monitoring, scheduled tasks, alerts
Requires at least: 6.1
Tested up to: 7.1
Requires PHP: 8.2
Stable tag: 0.5.0
License: GPLv2 or later
License URI: https://www.gnu.org/licenses/gpl-2.0.html

Watches WP-Cron: records every scheduled event's runs and tells you when one is missed, fails, gets stuck or runs slow.

== Description ==

WordPress runs its scheduled events (WP-Cron) only when someone visits the site. On a quiet site they run late or not at all, and when an event's code fails nobody hears about it. CronWatch records every WP-Cron event as it runs, in your own database, and alerts you when:

* an event is missed: it did not run within its recurrence plus a grace (10 minutes by default),
* a run fails: its code threw an exception, hit a fatal error or exited,
* a run gets stuck: it started and never finished,
* a run is much slower than usual,

and again when the event recovers. Every condition alerts once, when it starts, and once more when it ends; nothing repeats while it lasts.

It needs no change to your code or your other plugins. Every scheduled event becomes a job:

* A recurring event (hourly, twice daily, daily, weekly, or any schedule a plugin adds) is a job named `wp:<hook>`, expected every interval of its recurrence. One scheduled with arguments is `wp:<hook>:<key>`, the key being the start of WordPress's own key for those arguments, so the same hook on two schedules is two jobs.
* Single events (`wp_schedule_single_event`, such as a scheduled post's publishing) are one job per hook, with no schedule: they are one-offs, so a failure is reported but there is no cadence to miss. If WP-Cron stops running altogether, the recurring events WordPress itself schedules (update checks, twice daily and hourly) are reported missed, which is how you find out.
* An event that is no longer scheduled (its plugin was deactivated, say) keeps its history and is never reported missed.

What a run prints is kept as its output. Your own code can add lines with `cronwatch_log( 'sent 40 emails' );`.

Alerts go by email (through `wp_mail()`, the way the site sends its other mail), to Slack, or to any URL as a signed JSON webhook: set them under Tools, CronWatch, where you can also send a test alert and see each event's health. A dashboard with each job's runs and timeline comes to wp-admin in a later release.

CronWatch is the WordPress plugin of [the CronWatch library](https://cronwatch.dev/), which also watches jobs in Node, Ruby, Python and PHP apps and keeps the same tables in every language.

= Why a check that runs on page visits misses a quiet site =

CronWatch finds missed runs with a check every five minutes, which it schedules as a WP-Cron event of its own. WP-Cron runs only when someone (or something) loads a page, so on a site with no visits the check does not run either: the same silence that stops your events stops the check that would report them. A site that gets regular traffic is covered as it is; for every other site, and for events that must run on time, run WP-Cron and the check from the server's own cron instead:

1. Turn off WP-Cron's page-load trigger in `wp-config.php`:

    define( 'DISABLE_WP_CRON', true );

2. Add a crontab line that runs due events every five minutes, either through WP-CLI:

    */5 * * * * cd /path/to/site && wp cron event run --due-now --quiet

   or by requesting wp-cron.php:

    */5 * * * * curl -s https://example.com/wp-cron.php > /dev/null

3. And run CronWatch's check from the crontab too, so it happens whether or not WP-Cron does:

    */5 * * * * cd /path/to/site && wp cronwatch check --quiet

`wp cronwatch check` prints one line, such as `cronwatch: checked 12 jobs, sent 1 alert`. Many hosts offer a "real cron" setting that does the same as these lines.

= For developers =

* `cronwatch_alerts` (filter): the list of alert channels. Add any object implementing `Cronwatch\Alerts\AlertChannel`, or a callable taking the `Cronwatch\Alert`.
* `cronwatch_watch_event` (filter): return false to leave an event unwatched. Given `true`, the hook, its arguments and its recurrence name (null for a single event).
* `cronwatch_job_options` (filter): a job's options (`grace`, `timeout`, `maxDuration`, `failuresBeforeAlert`, `description`, `tags`), given the options, the hook, its arguments and its recurrence.
* `cronwatch_client_args` (filter): the arguments the library's client is made with.
* `cronwatch_log( ...$parts )`, or `do_action( 'cronwatch_log', ...$parts )`: a line for the output of the event running now.

= Privacy and outside services =

CronWatch sends nothing anywhere until you set an alert channel. Runs, output and state stay in three tables in your own database (`wp_cronwatch_jobs`, `wp_cronwatch_runs` and `wp_cronwatch_state`, with your table prefix). Values that look like secrets (API keys, tokens, passwords) are blanked from run output and errors before they are stored.

When you set one, alerts are sent to:

* Email: through `wp_mail()`, to the addresses you enter.
* Slack: to the incoming webhook URL you enter, on Slack's servers ([Slack's terms](https://slack.com/terms-of-service), [privacy policy](https://slack.com/trust/privacy/privacy-policy)).
* Webhook: to the URL you enter.

An alert holds the job's name, what went wrong, and the end of the run's output and error.

= Licence =

The plugin is GPLv2 or later. It includes the cronwatch/cronwatch PHP library (in `lib/`), which is MIT licensed; the MIT licence is compatible with the GPL, and the library's licence text is in `lib/LICENSE`.

== Installation ==

1. Install and activate the plugin. It creates its three tables and schedules its check.
2. Under Tools, CronWatch, enter where alerts should go and send a test alert.
3. If the site is not visited every few minutes, set up the server cron described above.

It needs PHP 8.2 or newer and MySQL 5.7.8 or MariaDB 10.3 or newer (the versions with the JSON functions it reads state with). Deleting the plugin removes its tables, settings and scheduled check.

== Frequently Asked Questions ==

= Does it slow my site down? =

No. On an ordinary page view it does nothing but note, when WP-Cron runs an event, which one it is. The work (a few queries per event) happens in the cron request, and the check runs every five minutes.

= An event is reported missed but my site is fine =

The event did not run within its recurrence plus the grace. On a quiet site that is WP-Cron waiting for a visit: see "Why a check that runs on page visits misses a quiet site". If an event is late by design, raise the grace under Tools, CronWatch, or give that job its own with the `cronwatch_job_options` filter.

= Can I watch events of one plugin only? =

Yes, with the `cronwatch_watch_event` filter.

== Changelog ==

= 0.5.0 =

* First release: WP-Cron events recorded as jobs, missed, failed, stuck and slow alerts by email, Slack and webhook, `wp cronwatch check`.
