<?php
/**
 * Plugin Name: CronWatch test fixtures
 *
 * A must-use plugin the WordPress tests install beside CronWatch: event
 * callbacks that succeed, throw, hit a fatal error and exit, a clock the
 * tests move (the cwt_now option, epoch milliseconds), and an alert channel
 * that keeps each alert in the cwt_alerts option. WordPress requests
 * nothing over HTTP: its own events (the update checks, Site Health's
 * request to the site itself) would reach the network, or wait on the one
 * request the tests' server answers at a time.
 */

add_filter('pre_http_request', function ($pre, $args, $url) {
    return new WP_Error('cwt_offline', "the tests make no HTTP requests ({$url})");
}, 10, 3);

add_action('cwt_ok', function (...$args): void {
    echo "did ok\n";
    cronwatch_log('logged', $args);
});
add_action('cwt_single', function (...$args): void {
    echo 'single ' . implode(',', $args) . "\n";
});
add_action('cwt_throw', function (): void {
    echo "before throw\n";
    throw new RuntimeException('boom');
});
add_action('cwt_fatal', function (): void {
    echo "before fatal\n";
    cwt_no_such_function();
});
add_action('cwt_exit', function (): void {
    echo "before exit\n";
    exit;
});
add_action('cwt_inner', function (): void {
    // A watched hook fired by hand inside a cron run is not a run of its own.
    do_action('cwt_single', 'by-hand');
});

add_filter('cronwatch_client_args', function (array $args): array {
    $now = get_option('cwt_now');
    if ($now) {
        $args['now'] = fn () => (int) $now;
    }
    return $args;
});

add_filter('cronwatch_alerts', function (array $channels): array {
    $channels[] = function (Cronwatch\Alert $alert): void {
        $seen = get_option('cwt_alerts', []);
        $seen[] = ['type' => $alert->type, 'job' => $alert->job, 'title' => $alert->title];
        update_option('cwt_alerts', $seen, false);
    };
    return $channels;
});

add_filter('cronwatch_watch_event', function (bool $watch, string $hook): bool {
    return $hook === 'cwt_ignored' ? false : $watch;
}, 10, 2);
