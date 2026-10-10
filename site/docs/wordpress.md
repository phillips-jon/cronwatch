---
title: WordPress
description: The CronWatch plugin for WordPress: every WP-Cron event watched with no code, alerts by email, Slack, Discord, SMS, a webhook or an error tracker, a real cron for quiet sites, the dashboard in wp-admin and the JSON API for agents.
order: 3.73
group: PHP
---

# WordPress

WordPress runs its scheduled events (WP-Cron) only when someone visits the site. On a quiet site they run late or not at all, and when an event's code fails nobody hears about it. The CronWatch plugin records every WP-Cron event as it runs, in the site's own database, and alerts you when an event is missed, fails, gets stuck or runs much slower than usual, and again when it recovers. It needs no code, and it is the WordPress plugin of the PHP library, [`cronwatch/cronwatch`](/docs/php/), with the same rules, alert text and stored rows.

## Install

The plugin is [CronWatch in the wordpress.org plugin directory](https://wordpress.org/plugins/cronwatch/). In wp-admin, go to Plugins, Add New Plugin, search for CronWatch, then install and activate it. Or use WP-CLI:

```bash
wp plugin install cronwatch --activate
```

Each release's zip is also attached to its [GitHub release](https://github.com/cronwatchdev/cronwatch/releases/latest), as `cronwatch.zip`, for a site that installs plugins from a file.

Activating it makes three tables (`wp_cronwatch_jobs`, `wp_cronwatch_runs` and `wp_cronwatch_state`, with your table prefix) and schedules its check. Then, under CronWatch, Settings, enter where alerts go and send a test alert.

It needs WordPress 6.1 or newer, PHP 8.2 or newer, and MySQL 5.7.8 or MariaDB 10.3 or newer (the versions with the JSON functions it reads state with); activation refuses an older database server with a message.

## What is watched

Every WP-Cron event becomes a job, with nothing to configure. A run starts just before WordPress runs the event's callbacks and ends after the last, from wp-cron.php or `wp cron event run`; what the callbacks print is kept as its output (its end, as much as a run keeps) and still printed, as it is printed.

- A recurring event is a job named `wp:<hook>`, expected every interval of its recurrence: `hourly` is `every 1h`, `twicedaily` `every 12h`, `daily` `every 1d`, `weekly` `every 7d`, and a schedule a plugin adds through `cron_schedules` its own interval. One scheduled with arguments is `wp:<hook>:<key>`, the key the first 8 characters of WordPress's own key for those arguments, so the same hook with two sets of arguments is two jobs.
- Single events (`wp_schedule_single_event`, such as a scheduled post's publishing) are one job per hook, with no schedule: they are one-offs, so a failure is reported but there is no cadence to miss. If WP-Cron stops running altogether, the recurring events WordPress itself schedules (`wp_version_check` and the rest) are reported missed, which is how you find out.
- An event that is no longer scheduled (its plugin was deactivated, say) keeps its history and is never reported missed.
- An uncaught exception, a fatal error or `exit()` in a callback fails the run, with the message and its file and line.

Jobs are tagged `wp-cron`, and their runs have the trigger `"wp-cron"`. The `wp:` prefix keeps a hook's job apart from the app's own jobs; see [Triggers, tags and job names](/docs/dashboard/#triggers-tags-and-job-names). A hook fired by hand (`do_action()`) outside WP-Cron is not a run.

Your own code can add lines to the output of the event running now with the `cronwatch_log` action, which does nothing while the plugin is inactive, so the code needs no check for it:

```php
do_action( 'cronwatch_log', 'Sent', $count, 'emails' );
```

## A quiet site needs a real cron

CronWatch finds missed runs with a check every five minutes, which it schedules as a WP-Cron event of its own. WP-Cron runs only when someone (or something) loads a page, so on a site with no visits the check does not run either: the same silence that stops your events stops the check that would report them. A site that gets regular traffic is covered as it is. For every other site, and for events that must run on time, run WP-Cron and the check from the server's own cron.

Turn off WP-Cron's page-load trigger in `wp-config.php`:

```php
define( 'DISABLE_WP_CRON', true );
```

Then add crontab lines that run due events and the check every five minutes:

```
*/5 * * * *  cd /var/www/site && wp cron event run --due-now --quiet
*/5 * * * *  cd /var/www/site && wp cronwatch check --quiet
```

or, without WP-CLI, request wp-cron.php (`curl -s https://example.com/wp-cron.php > /dev/null`) for the events; the check then runs as one of them. `wp cronwatch check` prints one line, such as `cronwatch: checked 12 jobs, sent 1 alert`, and exits non-zero with the reason when something is wrong. Many hosts offer a "real cron" setting that does the same as these lines. A missed `wp:wp_version_check` is how a site learns it needs one.

## Settings

CronWatch, Settings, for administrators (`manage_options`):

- **Email to**: one address or several, separated by commas, sent with `wp_mail()`, the way the site sends its other mail. The subject starts with the site's name.
- **Slack webhook URL**: an incoming webhook.
- **Webhook URL** and **secret**: each alert is posted there as JSON, signed with the secret in `X-CronWatch-Signature` (HMAC-SHA256 of the body) when there is one.
- **More channels**, each folded under its name until one of its fields is set: Discord; email through Resend, Postmark, SendGrid, Mailgun or Amazon SES, for a site whose own mail is not reliable; text messages through Twilio; and the error trackers Sentry, Honeybadger, Datadog, Rollbar, Bugsnag and New Relic. Each asks for what its provider needs (an API key, a from address on a domain the provider has verified, the addresses or numbers to send to, and the provider's options such as the region) and sends once every required field is set. Keys, tokens and the DSN are never shown again once saved: left blank, the saved one is kept, and a "Remove it" box beside it clears it. A provider only partly filled in is saved, and the notice names what it still needs; it sends nothing until then.
- **Grace**: how late an event may run before it counts as missed, such as `10m` (the default) or `1h`.

Nothing leaves the site until a channel is set; with none, alerts go to the PHP error log. "Send a test alert" sends one where a real alert would go and says what happened:

- With no channel set, it is written to the PHP error log, and the notice says so.
- With channels set, it goes to each one, and a notice per channel says it was sent or why it failed. A channel that sent it but reported a partial failure (one address of several refused, say) has that added to its notice.

A save that refuses the grace, a secret (one holding a line break or another control character) or the API token names each one it refused and saves the rest. Below the test button, the watched events are listed with their health, last run and next due time. Alerts link to the event's page in wp-admin. Every channel but email is sent through `wp_remote_post()`, with no redirects followed and a ten second timeout.

## The dashboard

The CronWatch menu in wp-admin opens the dashboard, for administrators: every event's health, the last 24 hours as a lane per event (when each was due, when it ran and for how long, and the slots nothing ran in), and for each event its last seven days, its runs with their output and errors, a button to silence it for a while, and, at the foot of its page, Delete history. "Run check now" is on the board. Before anything is recorded, the board says that WP-Cron's events appear after the first check, which runs every five minutes, and that "Run check now" or `wp cronwatch check` runs it at once.

These are the library's pages ([Dashboard and API](/docs/dashboard/)), shown inside wp-admin and never at a public URL; WordPress's sign-in stands for the dashboard's token, and every change carries a WordPress nonce.

## The JSON API for agents

The JSON API that [`@cronwatch/mcp`](/docs/mcp/) talks to is off by default: nothing is registered and the site answers 404. Turn it on under CronWatch, Settings, "Allow the JSON API", with a token you type (at least 24 letters, digits and `. _ ~ + / = -`) or one the plugin makes and shows once. It is then the REST route `cronwatch/v1`, only the dashboard's `/api` paths, answering requests that carry `Authorization: Bearer <token>`. The settings page shows the base URL and the line that adds it to Claude Code:

```bash
claude mcp add cronwatch -e CRONWATCH_URL=https://example.com/wp-json/cronwatch/v1 -e CRONWATCH_TOKEN=... -- npx -y @cronwatch/mcp
```

(`https://example.com/?rest_route=/cronwatch/v1` without pretty permalinks.) Anyone with the token can read the events, their runs and their output, silence or forget them, and run the check, so keep it as you would a password, and make a new one there if it leaks.

## Multisite

Activated for a network, the plugin makes the tables and schedules the check on every site, and does the same for a site made later. Each site has its own tables, settings, dashboard and check. Network deactivation clears the check from every site.

## For developers

Filters, for a plugin or a must-use plugin:

```php
// Leave events out: given true, the hook, its arguments and its recurrence (null for a single event).
add_filter( 'cronwatch_watch_event', function ( bool $watch, string $hook, array $args, ?string $recurrence ) {
    return $watch && ! str_starts_with( $hook, 'woocommerce_cleanup_' );
}, 10, 4 );

// A job's options (grace, timeout, maxDuration, failuresBeforeAlert, description, tags). Options CronWatch
// refuses (a timeout of "2 hours") are written to the error log, and the job keeps its own.
add_filter( 'cronwatch_job_options', function ( array $options, string $hook ) {
    if ( 'my_nightly_import' === $hook ) {
        $options['timeout'] = '2h';
        $options['failuresBeforeAlert'] = 2;
    }
    return $options;
}, 10, 2 );

// More channels: any AlertChannel (Discord here, from the Composer package), or a callable taking the Cronwatch\Alert.
add_filter( 'cronwatch_alerts', function ( array $channels ) {
    $channels[] = new \Cronwatch\Alerts\Discord( DISCORD_WEBHOOK_URL );
    return $channels;
} );

// The arguments the library's client is made with, such as Claude triage (from the Composer package).
add_filter( 'cronwatch_client_args', function ( array $args ) {
    $args['triage'] = new \Cronwatch\Triage\Anthropic( apiKey: ANTHROPIC_API_KEY, context: 'A WooCommerce shop.' );
    return $args;
} );
```

The plugin carries every channel the library has, since its settings offer each one; the filter adds one with options the form does not offer ([PHP](/docs/php/#email-sms-and-error-trackers)), sent through `wp_remote_post()` here. Triage comes with the Composer package, `composer require cronwatch/cronwatch`, which has it.

`cronwatch_reject_unsafe_urls` decides whether an alert URL may reach a private address or an unusual port (WordPress's `reject_unsafe_urls`): true on a multisite network, where a site's administrators may not be the network's, and false otherwise.

Inside a watched event, `\Cronwatch\Cronwatch::current()` is the run's context, for `metric()` as well as `log()`.

## Uninstall

Deactivating stops the check. Deleting the plugin drops its three tables and removes every option and scheduled event it made, on every site of a network.

## Privacy

CronWatch sends nothing anywhere until you set an alert channel, and has no tracking, statistics or calls home. Runs, output and state stay in your own database, and values that look like secrets (API keys, tokens, passwords) are blanked from run output and errors before they are stored. The plugin is GPLv2 or later; it bundles the MIT licensed library.
