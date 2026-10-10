<?php
/**
 * Plugin Name:       CronWatch
 * Plugin URI:        https://cronwatch.dev/
 * Description:       Watches WP-Cron: records every scheduled event's runs and tells you when one is missed, fails, gets stuck, or runs slow.
 * Version:           0.12.5
 * Requires at least: 6.1
 * Requires PHP:      8.2
 * Author:            Jon C. Phillips
 * Author URI:        https://joncphillips.com/
 * License:           GPLv2 or later
 * License URI:       https://www.gnu.org/licenses/gpl-2.0.html
 * Text Domain:       cronwatch
 *
 * @package Cronwatch
 */

// The plugin wrapper is GPLv2 or later. It bundles the cronwatch/cronwatch
// library (lib/, MIT licensed, which is GPL compatible); see readme.txt.

if ( ! defined( 'ABSPATH' ) ) {
	exit;
}

define( 'CRONWATCH_PLUGIN_FILE', __FILE__ );

/*
 * Classes load on demand. Cronwatch\WordPress\ is this plugin's own code, in
 * includes/. Cronwatch\ is the library: from lib/src in the released plugin,
 * or from ../src when the plugin is run from the monorepo. A site that
 * already has the library through Composer keeps its own copy.
 */
spl_autoload_register(
	static function ( string $class ): void {
		if ( str_starts_with( $class, 'Cronwatch\\WordPress\\' ) ) {
			$file = __DIR__ . '/includes/' . str_replace( '\\', '/', substr( $class, 20 ) ) . '.php';
		} elseif ( str_starts_with( $class, 'Cronwatch\\' ) ) {
			$root = is_dir( __DIR__ . '/lib/src' ) ? __DIR__ . '/lib/src' : dirname( __DIR__ ) . '/src';
			$file = $root . '/' . str_replace( '\\', '/', substr( $class, 10 ) ) . '.php';
		} else {
			return;
		}
		if ( is_file( $file ) ) {
			require $file;
		}
	}
);

register_activation_hook( __FILE__, array( \Cronwatch\WordPress\Plugin::class, 'activate' ) );
register_deactivation_hook( __FILE__, array( \Cronwatch\WordPress\Plugin::class, 'deactivate' ) );

\Cronwatch\WordPress\Plugin::boot();

/**
 * Adds a line to the output of the WP-Cron event running now, as the job's
 * log. Does nothing outside a watched event.
 *
 * The documented form is the action, do_action( 'cronwatch_log', ...$parts ),
 * which does nothing when the plugin is not active where a call to this
 * function would be a fatal error. This function is kept, and keeps working,
 * for code written against it.
 *
 * @param mixed ...$parts Joined with spaces; anything not a string is written as JSON.
 */
function cronwatch_log( mixed ...$parts ): void {
	\Cronwatch\WordPress\Plugin::watcher()->log( ...$parts );
}
