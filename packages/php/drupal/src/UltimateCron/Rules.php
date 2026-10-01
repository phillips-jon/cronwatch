<?php

declare(strict_types=1);

namespace Drupal\cronwatch\UltimateCron;

use Drupal\ultimate_cron\CronRule;
use Drupal\ultimate_cron\Entity\CronJob;
use Drupal\ultimate_cron\Plugin\ultimate_cron\Scheduler\Crontab;
use Drupal\ultimate_cron\Plugin\ultimate_cron\Scheduler\Simple;

/**
 * An Ultimate Cron job's schedule as a cron expression CronWatch reads.
 *
 * Ultimate Cron's two schedulers, Crontab and Simple (whose intervals are
 * Crontab rules from a list), run a job once a cron run comes after a time
 * its rules name and after its last run. A rule is a crontab line with two
 * additions: "+N" shifts the values a step names ("*\/10+2" is 2,12,...,52)
 * and "@" is the job's skew, a number from 0 to 255 fixed per job (the last
 * 8 hex digits of the SHA-1 of its id, its lowest 8 bits), taken modulo the
 * field's size. Ultimate Cron's own parser (CronRule::getIntervals()) gives
 * each field's values for the job's skew; they are written out as a plain
 * cron expression, so the reading is Ultimate Cron's, value for value.
 *
 * Ultimate Cron reads a rule in PHP's time zone, which Drupal sets to the
 * site's; the job is declared with that zone. Day of month and day of week
 * are matched either-or when both are narrowed, as in cron and croner, and
 * that is said with both fields written out; a rule Ultimate Cron reads
 * both-and with both narrowed (which only offsets that wrap past the end of
 * the month give) cannot be said, nor can a rule that never runs, a job with
 * several rules naming different times, or another scheduler plugin: those
 * jobs are declared without a schedule, and the recorder reports it once.
 */
final class Rules {

  /**
   * A job's schedule, or why it has none.
   *
   * @return array{?string, ?string}
   *   The cron expression, or null and the reason (a sentence's end, after
   *   the job's name).
   */
  public static function schedule(CronJob $job): array {
    try {
      $plugin = $job->getPlugin('scheduler');
    }
    catch (\Throwable $error) {
      return [NULL, 'its scheduler could not be made (' . $error->getMessage() . ')'];
    }
    $class = get_class($plugin);
    if ($class !== Crontab::class && $class !== Simple::class) {
      return [NULL, 'its scheduler "' . $plugin->getPluginId() . '" is neither of Ultimate Cron\'s own (Crontab and Simple)'];
    }
    $rules = $plugin->getConfiguration()['rules'] ?? [];
    $rules = is_array($rules) ? array_values($rules) : [$rules];
    $skew = $job->getUniqueID() & 0xff;
    $expressions = [];
    foreach ($rules as $rule) {
      [$expression, $problem] = self::expression((string) $rule, $skew);
      if ($expression === NULL) {
        return [NULL, 'its rule "' . $rule . '" ' . $problem];
      }
      $expressions[$expression] = TRUE;
    }
    if ($expressions === []) {
      return [NULL, 'it has no rule'];
    }
    if (count($expressions) > 1) {
      return [NULL, 'its rules ("' . implode('", "', array_map('strval', $rules)) . '") name times one cron expression cannot'];
    }
    return [(string) array_key_first($expressions), NULL];
  }

  /**
   * One rule, for a skew, as a cron expression, or why it cannot be one.
   *
   * @return array{?string, ?string}
   *   The cron expression, or null and the reason.
   */
  public static function expression(string $rule, int $skew): array {
    $intervals = CronRule::factory($rule, 0, $skew)->getIntervals();
    if (!is_array($intervals)) {
      return [NULL, 'is not one Ultimate Cron can read'];
    }
    $minutes = self::values($intervals['minutes'], 0, 59);
    $hours = self::values($intervals['hours'], 0, 23);
    $days = self::values($intervals['days'], 1, 31);
    $months = self::values($intervals['months'], 1, 12);
    $weekdays = self::values(array_keys($intervals['weekdays']), 0, 6);
    if ($minutes === [] || $hours === [] || $months === [] || $weekdays === []) {
      return [NULL, 'never runs'];
    }
    // CronRule::getLastSchedule(): the weekday counts when it is narrowed,
    // either-or with the day when that is narrowed too (counting the values
    // as given, before those past the month's end are dropped).
    $byWeekday = count($intervals['weekdays']) !== 7;
    $either = $byWeekday && count($intervals['days']) !== 31;
    if (!$byWeekday) {
      if ($days === []) {
        return [NULL, 'never runs'];
      }
      $dom = self::field($days, 1, 31);
      $dow = '*';
    }
    elseif ($either) {
      if ($days === [] || count($days) === 31) {
        // Either no day or every day: the weekday alone, or every day.
        $dom = '*';
        $dow = $days === [] ? self::field($weekdays, 0, 6) : '*';
      }
      else {
        $dom = self::field($days, 1, 31);
        $dow = self::field($weekdays, 0, 6);
      }
    }
    elseif (count($days) === 31) {
      $dom = '*';
      $dow = self::field($weekdays, 0, 6);
    }
    else {
      return [NULL, 'matches a day of the month and a day of the week both at once, which a cron expression cannot say'];
    }
    return [implode(' ', [self::field($minutes, 0, 59), self::field($hours, 0, 23), $dom, self::field($months, 1, 12), $dow]), NULL];
  }

  /**
   * A field's values in its range, sorted, each once.
   *
   * @param array<int|string> $values
   *   The values CronRule gave.
   *
   * @return list<int>
   *   The values a time can have.
   */
  private static function values(array $values, int $min, int $max): array {
    $kept = [];
    foreach ($values as $value) {
      $value = (int) $value;
      if ($value >= $min && $value <= $max) {
        $kept[$value] = $value;
      }
    }
    ksort($kept);
    return array_values($kept);
  }

  /**
   * A field written out: "*", "a-b", "*\/n" where those say it, else a list.
   *
   * @param list<int> $values
   *   Sorted values in the field's range, at least one.
   */
  private static function field(array $values, int $min, int $max): string {
    $count = count($values);
    if ($count === $max - $min + 1) {
      return '*';
    }
    if ($count > 2) {
      $step = $values[1] - $values[0];
      $even = TRUE;
      for ($i = 2; $i < $count; $i++) {
        $even = $even && $values[$i] - $values[$i - 1] === $step;
      }
      if ($even && $step === 1) {
        return $values[0] . '-' . $values[$count - 1];
      }
      if ($even && $values[0] === $min && $values[$count - 1] + $step > $max) {
        return '*/' . $step;
      }
    }
    return implode(',', $values);
  }

}
