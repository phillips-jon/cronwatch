<?php
/**
 * Runs a slice of /work/runs.json the way wp-cron.php runs an event
 * (wp_reschedule_event for a recurring one, wp_unschedule_event, then
 * do_action_ref_array), each with the clock set to its slot. The slice is
 * [from, to) in /work/slice.json.
 */
add_filter('wp_doing_cron', '__return_true');
$runs = json_decode(file_get_contents('/work/runs.json'), true);
[$from, $to] = json_decode(file_get_contents('/work/slice.json'), true);
$done = 0;
for ($i = $from; $i < $to; $i++) {
    [$at, $hook] = $runs[$i];
    $GLOBALS['cws_now'] = (int) $at;
    $ts = wp_next_scheduled($hook);
    if ($ts === false) {
        // A single event (wp_update_comment_type_batch): scheduled, then run.
        wp_schedule_single_event(time() + 60, $hook);
        $ts = wp_next_scheduled($hook);
    }
    $schedule = wp_get_schedule($hook);
    if ($schedule !== false) {
        wp_reschedule_event($ts, $schedule, $hook);
    }
    wp_unschedule_event($ts, $hook);
    ob_start();
    do_action_ref_array($hook, []);
    ob_end_clean();
    $done++;
}
echo "ran {$done}\n";
