// Seeds the Example Store's week of runs into the running WordPress
// (containers cws-wp and cws-db, which run.sh starts):
// successful runs through the steps wp-cron.php takes (seed.php), the
// warehouse feed's failures as real wp-cron.php requests that end on the
// uncaught exception. Times are written for a "now" of 2026-09-28 15:44 UTC
// (V) and shifted by R - V, R being the capture time given as argv[2] (ms).
import { execFileSync } from "node:child_process";
import { writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const WPC = path.join(HERE, "wpc");
const WORK = process.env.CWS_WORK;
const R = Number(process.argv[2]);
const V = Date.UTC(2026, 8, 28, 15, 44);
const delta = R - V;
const START = Date.UTC(2026, 8, 21, 16, 0);
const H = 3600e3, M = 60e3;
const at = (d, h, m) => Date.UTC(2026, 8, d, h, m);

const runs = [];
const every = (hook, first, step, until = V) => {
  for (let t = first; t <= until; t += step) if (t >= START) runs.push([t, hook]);
};
every("store_sync_inventory", at(21, 16, 25), H);
every("store_fetch_exchange_rates", at(21, 16, 9), H, at(28, 12, 9));
every("store_purge_page_cache", at(21, 16, 16), 30 * M);
every("store_rebuild_sitemap", at(21, 16, 49), H);
every("wp_privacy_delete_old_export_files", at(21, 16, 56), H);
every("store_send_newsletter", at(22, 9, 0), 24 * H);
every("store_backup_database", at(22, 3, 0), 24 * H);
for (const hook of ["delete_expired_transients", "recovery_mode_clean_expired_keys", "wp_scheduled_delete"]) every(hook, at(22, 4, 13), 24 * H);
for (const hook of ["wp_privacy_personal_data_cleanup_requests", "wp_scheduled_auto_draft_delete"]) every(hook, at(22, 4, 12), 24 * H);
every("wp_update_plugins", at(21, 19, 41), 12 * H);
every("wp_update_themes", at(21, 19, 40), 12 * H);
every("wp_version_check", at(21, 19, 40), 12 * H);
every("wp_update_user_counts", at(22, 5, 10), 12 * H);
runs.push([at(25, 4, 12), "wp_delete_temp_updater_backups"], [at(25, 4, 12), "wp_site_health_scheduled_check"]);
runs.push([at(28, 4, 12), "wp_update_comment_type_batch"]);
runs.sort((a, b) => a[0] - b[0] || (a[1] < b[1] ? -1 : 1));
// Runs due in the same minute start a few seconds apart, as wp-cron.php runs them one after another.
for (let i = 1; i < runs.length; i++) if (runs[i][0] <= runs[i - 1][0]) runs[i][0] = runs[i - 1][0] + 3000;

const FAILS = new Set([at(25, 17, 25), at(25, 18, 25), at(28, 2, 25), ...[11, 12, 13, 14, 15].map((h) => at(28, h, 25))]);
const shifted = runs.map(([t, hook]) => [t + delta, hook, hook === "store_sync_inventory" && FAILS.has(t)]);
writeFileSync(path.join(WORK, "runs.json"), JSON.stringify(shifted));

const wp = (args, env = {}) => execFileSync(WPC, args, { encoding: "utf8", env: { ...process.env, ...env } });
const evalPhp = (code) => {
  writeFileSync(path.join(WORK, "tmp-eval.php"), "<?php\n" + code);
  return wp(["eval-file", "/work/tmp-eval.php"]);
};
const chunk = (from, to) => {
  if (to <= from) return;
  // wpc passes no environment through docker, so the slice goes in a file.
  writeFileSync(path.join(WORK, "slice.json"), JSON.stringify([from, to]));
  process.stdout.write(wp(["eval-file", "/work/seed.php"]));
};

let from = 0;
for (let i = 0; i < shifted.length; i++) {
  if (!shifted[i][2]) continue;
  chunk(from, i);
  const t = shifted[i][0];
  evalPhp(`update_option('cws_now', ${t}); update_option('cws_feed_down', 1); delete_transient('doing_cron');
wp_clear_scheduled_hook('store_sync_inventory'); wp_schedule_event(time() - 1, 'hourly', 'store_sync_inventory');`);
  let body = "";
  try {
    body = execFileSync("curl", ["-s", "-H", "Host: store.example.com", "http://127.0.0.1:8088/wp-cron.php?doing_wp_cron"], { encoding: "utf8" });
  } catch (e) { body = String(e); }
  evalPhp(`delete_option('cws_now'); delete_option('cws_feed_down'); delete_transient('doing_cron');`);
  console.log(`failed run ${new Date(t).toISOString()} (wp-cron.php answered ${body.length} bytes)`);
  from = i + 1;
}
chunk(from, shifted.length);

// The cron array as it stands at "now": each event next due where its cadence puts it.
const next = {
  store_sync_inventory: ["hourly", at(28, 16, 25)], store_fetch_exchange_rates: ["hourly", at(28, 13, 9)],
  store_purge_page_cache: ["every_thirty_minutes", at(28, 15, 46)], store_rebuild_sitemap: ["hourly", at(28, 15, 49)],
  wp_privacy_delete_old_export_files: ["hourly", at(28, 15, 56)], store_send_newsletter: ["daily", at(29, 9, 0)],
  store_backup_database: ["daily", at(29, 3, 0)], delete_expired_transients: ["daily", at(29, 4, 13)],
  recovery_mode_clean_expired_keys: ["daily", at(29, 4, 13)], wp_scheduled_delete: ["daily", at(29, 4, 13)],
  wp_privacy_personal_data_cleanup_requests: ["daily", at(29, 4, 12)], wp_scheduled_auto_draft_delete: ["daily", at(29, 4, 12)],
  wp_update_plugins: ["twicedaily", at(28, 19, 41)], wp_update_themes: ["twicedaily", at(28, 19, 40)],
  wp_version_check: ["twicedaily", at(28, 19, 40)], wp_update_user_counts: ["twicedaily", at(28, 17, 10)],
  wp_delete_temp_updater_backups: ["weekly", at(32, 4, 12)], wp_site_health_scheduled_check: ["weekly", at(32, 4, 12)],
};
let php = "";
for (const [hook, [rec, t]] of Object.entries(next)) {
  php += `wp_clear_scheduled_hook('${hook}'); wp_schedule_event(${Math.round((t + delta) / 1000)}, '${rec}', '${hook}');\n`;
}
php += `wp_clear_scheduled_hook('cronwatch_check'); wp_schedule_event(${Math.round(R / 1000) + 300}, 'cronwatch_five_minutes', 'cronwatch_check');\n`;
php += `update_option('cws_now', ${R});\n`;
evalPhp(php);
console.log("seeded", shifted.length, "runs; now is", new Date(R).toISOString());
