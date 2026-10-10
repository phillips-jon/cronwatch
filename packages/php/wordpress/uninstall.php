<?php
/**
 * Deleting the plugin removes what it made: its three tables, its options,
 * and its scheduled check, on every site of a network.
 *
 * @package Cronwatch
 */

if ( ! defined( 'WP_UNINSTALL_PLUGIN' ) ) {
	exit;
}

/** Removes the plugin's tables, options, transients, and events from the current site. */
function cronwatch_uninstall_site(): void {
	global $wpdb;
	$prefix = $wpdb->prefix . 'cronwatch_';
	if ( preg_match( '/^[A-Za-z0-9_]+$/D', $prefix ) === 1 ) {
		// The plugin's own tables, named from the site's prefix, checked above; a table name cannot be a placeholder before WordPress 6.2 (%i).
		$wpdb->query( "DROP TABLE IF EXISTS {$prefix}jobs, {$prefix}runs, {$prefix}state" ); // phpcs:ignore WordPress.DB.DirectDatabaseQuery, WordPress.DB.PreparedSQL.InterpolatedNotPrepared, WordPress.DB.DirectDatabaseQuery.SchemaChange, PluginCheck.Security.DirectDB.UnescapedDBParameter -- see above.
	}
	delete_option( 'cronwatch_settings' );
	delete_option( 'cronwatch_db_version' );
	// WordPress has no API that deletes transients by prefix; the plugin's are short lived (a test result, a new token), so this removes any left.
	$wpdb->query( $wpdb->prepare( "DELETE FROM {$wpdb->options} WHERE option_name LIKE %s OR option_name LIKE %s", $wpdb->esc_like( '_transient_cronwatch_' ) . '%', $wpdb->esc_like( '_transient_timeout_cronwatch_' ) . '%' ) ); // phpcs:ignore WordPress.DB.DirectDatabaseQuery -- see above.
	wp_clear_scheduled_hook( 'cronwatch_check' );
}

if ( is_multisite() ) {
	foreach ( get_sites( array( 'fields' => 'ids', 'number' => 0 ) ) as $cronwatch_site ) {
		switch_to_blog( (int) $cronwatch_site );
		cronwatch_uninstall_site();
		restore_current_blog();
	}
} else {
	cronwatch_uninstall_site();
}
