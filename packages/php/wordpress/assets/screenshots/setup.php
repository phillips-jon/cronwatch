<?php
// The store's events and the core events WordPress adds on its first admin
// pages, every one pushed a day ahead so none is due until the seed runs it.
$want = [
    'store_sync_inventory' => 'hourly', 'store_fetch_exchange_rates' => 'hourly', 'store_purge_page_cache' => 'every_thirty_minutes',
    'store_rebuild_sitemap' => 'hourly', 'store_send_newsletter' => 'daily', 'store_backup_database' => 'daily',
    'wp_scheduled_delete' => 'daily', 'delete_expired_transients' => 'daily', 'wp_scheduled_auto_draft_delete' => 'daily',
    'wp_update_user_counts' => 'twicedaily', 'wp_delete_temp_updater_backups' => 'weekly',
    'recovery_mode_clean_expired_keys' => 'daily', 'wp_privacy_delete_old_export_files' => 'hourly',
    'wp_privacy_personal_data_cleanup_requests' => 'daily', 'wp_version_check' => 'twicedaily', 'wp_update_plugins' => 'twicedaily',
    'wp_update_themes' => 'twicedaily', 'wp_site_health_scheduled_check' => 'weekly', 'cronwatch_check' => 'cronwatch_five_minutes',
];
foreach (_get_cron_array() as $ts => $hooks) {
    foreach ($hooks as $hook => $events) {
        if (!isset($want[$hook])) { wp_clear_scheduled_hook($hook); echo "cleared {$hook}\n"; }
    }
}
foreach ($want as $hook => $rec) {
    wp_clear_scheduled_hook($hook);
    wp_schedule_event(time() + 86400, $rec, $hook);
}
echo json_encode(array_keys($want)) . "\n";
