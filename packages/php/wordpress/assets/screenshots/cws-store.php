<?php
/**
 * Plugin Name: Example Store jobs (screenshot seed)
 *
 * A must-use plugin for the listing screenshots: the store's own WP-Cron
 * events (hooks store_*), a clock (the cws_now option, epoch milliseconds,
 * which each run moves on by how long it takes), a warehouse feed that is
 * down while the cws_feed_down option is set, and no HTTP requests leaving
 * the site.
 */

add_filter('pre_http_request', function ($pre, $args, $url) {
    return new WP_Error('cws_offline', "the screenshot site makes no HTTP requests ({$url})");
}, 10, 3);

add_filter('cron_schedules', function (array $schedules): array {
    $schedules['every_thirty_minutes'] = ['interval' => 1800, 'display' => 'Every thirty minutes'];
    return $schedules;
});

$GLOBALS['cws_now'] = (int) get_option('cws_now', 0);
$GLOBALS['cws_feed_down'] = (bool) get_option('cws_feed_down', false);

add_filter('cronwatch_client_args', function (array $args): array {
    if ($GLOBALS['cws_now'] > 0) {
        $args['now'] = fn () => (int) $GLOBALS['cws_now'];
    }
    return $args;
});

/** How long each event's run takes, in milliseconds (the clock moves on by it). */
const CWS_TAKES = [
    'store_sync_inventory' => 13000,
    'store_fetch_exchange_rates' => 2000,
    'store_purge_page_cache' => 900,
    'store_rebuild_sitemap' => 4200,
    'store_send_newsletter' => 41000,
    'store_backup_database' => 64000,
    'wp_version_check' => 900,
    'wp_update_plugins' => 1400,
    'wp_update_themes' => 700,
    'wp_update_user_counts' => 200,
    'wp_scheduled_delete' => 300,
    'delete_expired_transients' => 250,
    'recovery_mode_clean_expired_keys' => 120,
    'wp_privacy_delete_old_export_files' => 150,
    'wp_privacy_personal_data_cleanup_requests' => 180,
    'wp_scheduled_auto_draft_delete' => 220,
    'wp_site_health_scheduled_check' => 2600,
    'wp_delete_temp_updater_backups' => 160,
    'wp_update_comment_type_batch' => 300,
];

foreach (CWS_TAKES as $hook => $ms) {
    add_action($hook, function () use ($ms): void {
        if ($GLOBALS['cws_now'] > 0) {
            $GLOBALS['cws_now'] += (int) round($ms * (0.85 + mt_rand(0, 300) / 1000));
        }
    }, PHP_INT_MAX - 1);
}

add_action('store_purge_page_cache', function (): void {
    echo "purged 212 cached pages\n";
});
add_action('store_rebuild_sitemap', function (): void {
    echo "sitemap: 1,284 urls\n";
});
add_action('store_fetch_exchange_rates', function (): void {
    echo "rates for 6 currencies\n";
});
add_action('store_send_newsletter', function (): void {
    echo "sent the newsletter to 3,120 subscribers\n";
});
add_action('store_backup_database', function (): void {
    echo "backup written: store-db.sql.gz (84 MB)\n";
});

add_action('store_sync_inventory', function (): void {
    echo "fetching stock levels from the warehouse feed\n";
    if ($GLOBALS['cws_feed_down']) {
        $GLOBALS['cws_now'] += 30000;
        throw new RuntimeException('warehouse feed: HTTP 503 Service Unavailable after 30s');
    }
    echo "updated stock for 840 products\n";
});
