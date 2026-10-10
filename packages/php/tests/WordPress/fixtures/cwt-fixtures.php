<?php
/**
 * Plugin Name: CronWatch test fixtures
 *
 * A must-use plugin the WordPress tests install beside CronWatch: event
 * callbacks that succeed, throw, hit a fatal error, exit, or stream a lot
 * of output, a clock the tests move (the cwt_now option, epoch
 * milliseconds), an alert channel that keeps each alert in the cwt_alerts
 * option, and job options for some hooks from the cwt_job_options option
 * (hook => options), through the cronwatch_job_options filter. WordPress requests
 * nothing over HTTP: its own events (the update checks, Site Health's
 * request to the site itself) would reach the network, or wait on the one
 * request the tests' server answers at a time.
 */

add_filter('pre_http_request', function ($pre, $args, $url) {
    return new WP_Error('cwt_offline', "the tests make no HTTP requests ({$url})");
}, 10, 3);

add_action('cwt_ok', function (...$args): void {
    echo "did ok\n";
    // The documented form, and the function the plugin keeps working.
    do_action('cronwatch_log', 'logged', $args);
    cronwatch_log('and by the function');
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
add_action('cwt_big', function (): void {
    // 32 MB in 1 KB lines, and how much more memory the process held at the end.
    $before = memory_get_usage();
    $line = str_repeat('x', 1017) . "\n";
    for ($i = 0; $i < 32 * 1024; $i++) {
        echo sprintf('%05d ', $i % 100000) . $line;
    }
    echo "the end\n";
    update_option('cwt_big_memory', memory_get_usage() - $before, false);
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

add_filter('cronwatch_job_options', function (array $options, string $hook): array {
    $extra = get_option('cwt_job_options', []);
    return is_array($extra) && is_array($extra[$hook] ?? null) ? $extra[$hook] + $options : $options;
}, 10, 2);

add_filter('cronwatch_watch_event', function (bool $watch, string $hook): bool {
    return $hook === 'cwt_ignored' ? false : $watch;
}, 10, 2);
