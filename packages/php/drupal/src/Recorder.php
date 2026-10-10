<?php

declare(strict_types=1);

namespace Drupal\cronwatch;

use Cronwatch\Alert;
use Cronwatch\Alerts\Slack;
use Cronwatch\Alerts\Webhook;
use Cronwatch\Bridge\ChannelSettings;
use Cronwatch\Bridge\JobName;
use Cronwatch\Bridge\Unscheduled;
use Cronwatch\CheckResult;
use Cronwatch\Cronwatch;
use Cronwatch\Duration;
use Cronwatch\Job\JobHandle;
use Cronwatch\Watch;
use Drupal\Core\Config\ConfigFactoryInterface;
use Drupal\Core\Config\ImmutableConfig;
use Drupal\Core\Extension\ModuleHandlerInterface;
use Drupal\Core\Language\LanguageManagerInterface;
use Drupal\Core\Mail\MailManagerInterface;
use Drupal\Core\Site\Settings;
use Drupal\Core\Queue\QueueWorkerManagerInterface;
use Drupal\Core\Url;
use Psr\Log\LoggerInterface;

/**
 * CronWatch in a Drupal site: the client, the jobs, and the runs of cron.
 *
 * - Every cron run (Automated Cron after a page, `drush cron`, /cron/<key>
 *   from a system cron) is a run of the job "drupal:cron", and each module's
 *   hook_cron in it a run of "drupal:<module>" (WatchedCron calls in here).
 * - Drupal's cron has no schedule per hook: every hook_cron runs on every
 *   cron run. So only "drupal:cron" has a schedule, the site's: the one set
 *   under CronWatch's settings (what the system crontab does), else Automated
 *   Cron's interval as "every <interval>s", else none. A cron that stops is
 *   one missed alert, not one per module; each module's own job reports its
 *   failures, slow runs, and stuck runs.
 * - Queue workers opt in (the settings' list, or #[Cronwatch\Watch] on the
 *   worker's class), and then every item processed is a run of
 *   "drupal:queue:<worker id>", in cron, `drush queue:run` or anywhere else.
 * - Under Ultimate Cron, which runs each job on a schedule of its own, every
 *   cron run is still "drupal:cron" (WatchedUltimateCron), and each run of
 *   one of its jobs is a run of that job (WatchedCronJob): "drupal:<module>"
 *   for a module's hook_cron, "drupal:job:<id>" for any other, each with
 *   the job's own schedule.
 */
final class Recorder {

  /**
   * The job of the whole cron run.
   */
  public const CRON_JOB = 'drupal:cron';

  public const TRIGGER_CRON = 'drupal-cron';

  public const TRIGGER_QUEUE = 'drupal-queue';

  public const TAG_CRON = 'drupal-cron';

  public const TAG_QUEUE = 'drupal-queue';

  /**
   * An Ultimate Cron job's run launched by a cron run.
   */
  public const TRIGGER_ULTIMATE_CRON = 'ultimate-cron';

  /**
   * An Ultimate Cron job's run launched on its own: its "Run" button, or
   * `drush cron:run <job>`.
   */
  public const TRIGGER_ULTIMATE_CRON_MANUAL = 'ultimate-cron-manual';

  private ?Cronwatch $client = NULL;

  /**
   * Whether a cron run is going in this process (between cronStarted() and
   * cronFinished()), so an Ultimate Cron job knows who launched it.
   */
  private bool $inCron = FALSE;

  /**
   * Problems reported once per process, by where and message.
   *
   * @var array<string, true>
   */
  private array $reported = [];

  /**
   * The open run of the whole cron run, its execution key.
   */
  private ?int $cronKey = NULL;

  /**
   * The modules whose hook_cron ran in this cron run, name => whether it failed.
   *
   * @var array<string, bool>
   */
  private array $modules = [];

  /**
   * Job handles declared in this process, by name.
   *
   * @var array<string, \Cronwatch\Job\JobHandle>
   */
  private array $handles = [];

  public function __construct(
    private readonly ConfigFactoryInterface $configFactory,
    private readonly ModuleHandlerInterface $moduleHandler,
    private readonly LoggerInterface $logger,
    private readonly MailManagerInterface $mail,
    private readonly LanguageManagerInterface $languages,
    private readonly QueueWorkerManagerInterface $queues,
  ) {
  }

  /**
   * The recorder, or null when it cannot be had (a broken container).
   */
  public static function service(): ?self {
    try {
      $recorder = \Drupal::service('cronwatch.recorder');
      return $recorder instanceof self ? $recorder : NULL;
    }
    catch (\Throwable) {
      return NULL;
    }
  }

  /**
   * Which cron service runs cron: "core", "ultimate_cron", or "" for one
   * CronWatch does not know (see CronServicePass).
   */
  public function cronService(): string {
    try {
      $container = \Drupal::getContainer();
      return $container->hasParameter('cronwatch.cron_service') ? (string) $container->getParameter('cronwatch.cron_service') : 'core';
    }
    catch (\Throwable) {
      return 'core';
    }
  }

  /**
   * The module's settings.
   */
  public function settings(): ImmutableConfig {
    return $this->configFactory->get('cronwatch.settings');
  }

  /**
   * The client for this request, on the site's database.
   */
  public function client(): Cronwatch {
    if ($this->client !== NULL) {
      return $this->client;
    }
    $channels = $this->channels();
    return $this->client = new Cronwatch(
      store: Storage::store(),
      alerts: $channels === [] ? [new LogChannel($this->logger)] : $channels,
      defaults: ['grace' => self::grace((string) $this->settings()->get('grace'))],
      onError: $this->report(...),
    );
  }

  /**
   * Forgets the client, so the next call reads the settings again.
   */
  public function reset(): void {
    $this->client = NULL;
    $this->handles = [];
  }

  /**
   * Anything that goes wrong outside a job: Drupal's log.
   */
  public function report(\Throwable $error, string $where): void {
    $this->logger->error('@where: @class: @message', [
      '@where' => $where,
      '@class' => get_class($error),
      '@message' => $error->getMessage(),
    ]);
  }

  /**
   * The alert channels the settings name, and any a module adds.
   *
   * Other modules add or change channels with hook_cronwatch_alerts_alter().
   * With none, alerts go to Drupal's log.
   *
   * @return list<mixed>
   *   The channels.
   */
  public function channels(): array {
    $settings = $this->settings();
    $link = fn (Alert $alert): string => $this->jobUrl($alert->job);
    $channels = [];
    $site = (string) $this->configFactory->get('system.site')->get('name');
    $prefix = $site !== '' ? "[{$site}]" : NULL;
    $email = trim((string) $settings->get('email_to'));
    if ($email !== '') {
      $channels[] = new MailChannel($this->mail, $this->languages, $email, $prefix, $link);
    }
    $slack = trim((string) $settings->get('slack_webhook_url'));
    if ($slack !== '') {
      $channels[] = new Slack($slack, $link);
    }
    $webhook = trim((string) $settings->get('webhook_url'));
    if ($webhook !== '') {
      $secret = (string) $settings->get('webhook_secret');
      $channels[] = new Webhook($webhook, [], $secret !== '' ? $secret : NULL);
    }
    // Discord, the email providers, Twilio, and the error trackers, each once its required fields are set.
    array_push($channels, ...ChannelSettings::channels(
      fn (string $key): string => (string) $settings->get($key),
      $link,
      $prefix,
      NULL,
      fn (\Throwable $error) => $this->report($error, 'settings'),
    ));
    $this->moduleHandler->alter('cronwatch_alerts', $channels);
    return array_values($channels);
  }

  /**
   * The dashboard's page for a job, for alert links.
   *
   * The site's address is $settings['cronwatch_base_url'] when set. Else it
   * is the request's, only where the host is known good: under Drush (its
   * --uri) or with $settings['trusted_host_patterns'], which Drupal checks
   * each request's host against. Otherwise (Automated Cron after a
   * visitor's request, on a site that trusts any host) the host is the
   * visitor's to choose, and the alert goes without a link.
   */
  public function jobUrl(string $job): string {
    $options = ['absolute' => TRUE, 'query' => ['job' => $job]];
    $base = trim((string) Settings::get('cronwatch_base_url', ''));
    if ($base !== '') {
      $options['base_url'] = rtrim($base, '/');
    }
    elseif (PHP_SAPI !== 'cli' && Settings::get('trusted_host_patterns', []) === []) {
      return '';
    }
    try {
      return Url::fromRoute('cronwatch.dashboard', [], $options)->toString(TRUE)->getGeneratedUrl();
    }
    catch (\Throwable) {
      return '';
    }
  }

  /**
   * A grace that parses, or the library's default.
   */
  private static function grace(string $grace): string {
    try {
      Duration::parse($grace, 'grace');
      return $grace;
    }
    catch (\Throwable) {
      return '10m';
    }
  }

  // ------------------------------------------------------------ the jobs

  /**
   * The schedule of "drupal:cron", and where it came from.
   *
   * @return array{?string, string}
   *   The schedule (null for none) and its source: "settings",
   *   "automated_cron", or "none".
   */
  public function cronSchedule(): array {
    $set = trim((string) $this->settings()->get('schedule'));
    if ($set !== '') {
      return [$set, 'settings'];
    }
    if ($this->moduleHandler->moduleExists('automated_cron')) {
      // The interval a page request sees. Drush sets it to 0 for its own
      // commands (as a settings override), so under Drush the stored value
      // is read instead.
      $config = $this->configFactory->get('automated_cron.settings');
      $interval = (int) (class_exists('Drush\Drush', FALSE) ? $config->getOriginal('interval', FALSE) : $config->get('interval'));
      if ($interval > 0) {
        return ['every ' . \Cronwatch\Duration::interval((int) $interval), 'automated_cron'];
      }
    }
    return [NULL, 'none'];
  }

  /**
   * The modules implementing hook_cron, in the order cron calls them.
   *
   * @return list<string>
   *   Module names.
   */
  public function cronModules(): array {
    $modules = [];
    // invokeAllWith() hands each implementation over without calling it.
    $this->moduleHandler->invokeAllWith('cron', function (callable $hook, string $module) use (&$modules): void {
      $modules[] = $module;
    });
    return array_values(array_unique($modules));
  }

  /**
   * Declares a job with hook_cronwatch_job_options_alter() applied.
   *
   * Options the library refuses (an alter hook's, a worker's #[Watch], a
   * schedule imported with the configuration) are reported, and the job is
   * declared with fewer: the module's own options without the alter hooks,
   * then those without their schedule, so one bad job never stops the
   * others or its own runs being recorded.
   *
   * @param array<string, mixed> $options
   *   The job's options.
   * @param array<string, string> $context
   *   What the job is: kind (cron, module, or queue) and module or queue.
   */
  private function declare(string $name, array $options, array $context): JobHandle {
    $altered = $options;
    try {
      $this->moduleHandler->alter('cronwatch_job_options', $altered, $name, $context);
      return $this->handles[$name] = $this->client()->job($name, $altered);
    }
    catch (\Throwable $error) {
      $this->safeReport($error, "declaring {$name}");
    }
    try {
      return $this->handles[$name] = $this->client()->job($name, $options);
    }
    catch (\Throwable $error) {
      if (!isset($options['schedule'])) {
        throw $error;
      }
      $this->safeReport($error, "declaring {$name}");
    }
    unset($options['schedule'], $options['timezone']);
    return $this->handles[$name] = $this->client()->job($name, $options);
  }

  /**
   * The job of the whole cron run.
   */
  public function cronJob(): JobHandle {
    [$schedule] = $this->cronSchedule();
    $options = ['description' => $this->cronService() === 'ultimate_cron'
      ? 'Drupal cron, run by Ultimate Cron: each of its jobs that is due'
      : 'Drupal cron: every hook_cron, then the queues cron processes',
    ];
    if ($schedule !== NULL) {
      $options['schedule'] = $schedule;
    }
    $options['tags'] = [self::TAG_CRON, $this->appTag(self::TAG_CRON)];
    return $this->declare(self::CRON_JOB, $options, ['kind' => 'cron']);
  }

  /**
   * This site's tag under an integration's tag, from the site's UUID, so two
   * sites sharing one store and prefix never declare each other's jobs
   * without a schedule (see Unscheduled).
   */
  public function appTag(string $tag): string {
    $uuid = (string) ($this->configFactory->get('system.site')->get('uuid') ?? '');
    return Unscheduled::appTag($tag, $uuid !== '' ? $uuid : 'drupal');
  }

  /**
   * The job of one module's hook_cron.
   */
  public function moduleJob(string $module): JobHandle {
    $name = 'drupal:' . $module;
    return $this->handles[$name] ?? $this->declare($name, [
      'description' => "hook_cron of the {$module} module",
      'tags' => [self::TAG_CRON, $this->appTag(self::TAG_CRON)],
    ], ['kind' => 'module', 'module' => $module]);
  }

  /**
   * The CronWatch job name of an Ultimate Cron job: "drupal:<module>" for
   * the job Ultimate Cron made for a module's hook_cron (its id
   * "<module>_cron", its callback "<module>#cron", or "<module>_cron" before
   * Ultimate Cron's update to that form), so the module's history goes on
   * from core's cron; "drupal:job:<id>" for any other.
   */
  public static function ultimateJobName(string $id, string $module, string $callback): string {
    if ($module !== '' && $id === "{$module}_cron" && ($callback === "{$module}#cron" || $callback === "{$module}_cron")) {
      return 'drupal:' . $module;
    }
    return JobName::clean('drupal:job:' . $id);
  }

  /**
   * The job of an Ultimate Cron job, with the job's own schedule.
   *
   * The schedule is its rules as a cron expression in the site's time zone
   * (UltimateCron\Rules). A job Ultimate Cron does not run (disabled) has
   * none; a job whose rules cannot be said as one is declared without, and
   * that is reported once.
   *
   * @param \Drupal\ultimate_cron\Entity\CronJob $job
   *   The job.
   */
  public function ultimateJob(object $job): JobHandle {
    $id = (string) $job->id();
    $module = (string) $job->getModule();
    $callback = (string) $job->getCallbackString();
    $name = self::ultimateJobName($id, $module, $callback);
    if (isset($this->handles[$name])) {
      return $this->handles[$name];
    }
    $options = ['description' => $name === 'drupal:' . $module
      ? "hook_cron of the {$module} module, run by Ultimate Cron"
      : 'Ultimate Cron: ' . (string) $job->getTitle(),
    ];
    if ($job->status()) {
      [$schedule, $problem] = UltimateCron\Rules::schedule($job);
      if ($schedule !== NULL) {
        $options['schedule'] = $schedule;
        $options['timezone'] = $this->siteTimezone();
      }
      else {
        $this->reportOnce(new \RuntimeException("Ultimate Cron job {$id}: {$problem}, so the job is watched without a schedule"), "declaring {$name}");
      }
    }
    $options['tags'] = [self::TAG_CRON, $this->appTag(self::TAG_CRON)];
    return $this->declare($name, $options, ['kind' => 'ultimate_cron', 'job' => $id, 'module' => $module]);
  }

  /**
   * The zone Ultimate Cron reads its rules in: PHP's, which Drupal sets to
   * the site's default time zone for cron.
   */
  private function siteTimezone(): string {
    $zone = (string) ($this->configFactory->get('system.date')->get('timezone.default') ?? '');
    return $zone !== '' ? $zone : date_default_timezone_get();
  }

  /**
   * Ultimate Cron's jobs, enabled or not.
   *
   * @return array<string, \Drupal\ultimate_cron\Entity\CronJob>
   *   The jobs, by id.
   */
  private function ultimateJobs(): array {
    return \Drupal::entityTypeManager()->getStorage('ultimate_cron_job')->loadMultiple();
  }

  /**
   * The job of a watched queue worker.
   */
  public function queueJob(string $id, string $class): JobHandle {
    $options = self::queueOptions($class) ?? [];
    $name = is_string($options['name'] ?? NULL) && $options['name'] !== '' ? $options['name'] : JobName::clean('drupal:queue:' . $id);
    unset($options['name']);
    if (isset($this->handles[$name])) {
      return $this->handles[$name];
    }
    $options = $options + ['description' => "Items of the {$id} queue"];
    $options['tags'] = array_values(array_unique([...array_map('strval', (array) ($options['tags'] ?? [])), self::TAG_QUEUE, $this->appTag(self::TAG_QUEUE)]));
    return $this->declare($name, $options, ['kind' => 'queue', 'queue' => $id]);
  }

  /**
   * A worker class's #[Cronwatch\Watch] options, with its name; null without.
   *
   * @return array<string, mixed>|null
   *   The options, or null when the class has no attribute.
   */
  public static function queueOptions(string $class): ?array {
    $watch = class_exists($class) ? Watch::of($class) : NULL;
    if ($watch === NULL) {
      return NULL;
    }
    $options = $watch->options();
    if ($watch->name !== NULL) {
      $options = ['name' => $watch->name] + $options;
    }
    return $options;
  }

  /**
   * Whether a queue worker is watched.
   *
   * It is when the settings list it, or its class has #[Cronwatch\Watch]
   * (and not enabled: false).
   *
   * @param list<string> $listed
   *   The settings' list of worker IDs.
   */
  public static function watchesQueue(string $id, string $class, array $listed): bool {
    $watch = class_exists($class) ? Watch::of($class) : NULL;
    if ($watch !== NULL && !$watch->enabled) {
      return FALSE;
    }
    return $watch !== NULL || in_array($id, $listed, TRUE);
  }

  /**
   * What a check starts with: every job declared, and old ones unscheduled.
   *
   * The cron run, every module's hook_cron (under Ultimate Cron, each of its
   * jobs instead) and every watched queue worker is declared, and jobs of
   * this module's no longer declared (a schedule taken away, a queue no
   * longer watched, Ultimate Cron's jobs once it is gone) are declared again
   * without their schedule, so they are never reported missed.
   */
  public function prepare(): Cronwatch {
    $cw = $this->client();
    $declarations = [self::CRON_JOB => fn () => $this->cronJob()];
    if ($this->cronService() === 'ultimate_cron') {
      try {
        foreach ($this->ultimateJobs() as $id => $job) {
          // Only jobs whose runs are recorded (a module that swapped the
          // entity's class too is left alone), else they would be missed.
          if ($job instanceof UltimateCron\WatchedCronJob) {
            $declarations['Ultimate Cron job ' . $id] = fn () => $this->ultimateJob($job);
          }
        }
      }
      catch (\Throwable $error) {
        $this->safeReport($error, 'reading the Ultimate Cron jobs');
      }
    }
    else {
      foreach ($this->cronModules() as $module) {
        $declarations['drupal:' . $module] = fn () => $this->moduleJob($module);
      }
    }
    foreach ($this->queues->getDefinitions() as $id => $definition) {
      $class = (string) ($definition['cronwatch_class'] ?? '');
      if ($class !== '') {
        $declarations['drupal:queue:' . $id] = fn () => $this->queueJob((string) $id, $class);
      }
    }
    // One job the library refuses is reported; the rest are still declared and checked.
    foreach ($declarations as $name => $declaration) {
      try {
        $declaration();
      }
      catch (\Throwable $error) {
        $this->safeReport($error, "declaring {$name}");
      }
    }
    foreach ([self::TAG_CRON, self::TAG_QUEUE] as $tag) {
      Unscheduled::declare($cw, $tag, $this->appTag($tag), $this->report(...));
    }
    return $cw;
  }

  /**
   * One check: prepare(), then the library's check.
   */
  public function check(): CheckResult {
    return $this->prepare()->check();
  }

  // ------------------------------------------------------------ a cron run

  /**
   * The cron lock was taken and hook_cron is about to run (under Ultimate
   * Cron, which takes no lock: a cron run is about to launch its jobs).
   */
  public function cronStarted(): void {
    $this->modules = [];
    $this->cronKey = NULL;
    $this->inCron = TRUE;
    try {
      $this->cronKey = $this->client()->startExecution($this->cronJob()->definition, self::TRIGGER_CRON);
    }
    catch (\Throwable $error) {
      $this->safeReport($error, 'starting ' . self::CRON_JOB);
    }
  }

  /**
   * A module's hook_cron is about to run; returns its run's key, or null.
   *
   * A module with several implementations (Drupal 11.1's #[Hook('cron')]
   * methods) is one run, started before the first and finished after the
   * last (WatchedCron), and a failure of any keeps it failed.
   */
  public function hookStarted(string $module): ?int {
    $this->modules[$module] ??= FALSE;
    if ($this->cronKey === NULL) {
      return NULL;
    }
    try {
      return $this->client()->startExecution($this->moduleJob($module)->definition, self::TRIGGER_CRON);
    }
    catch (\Throwable $error) {
      $this->safeReport($error, "starting drupal:{$module}");
      return NULL;
    }
  }

  /**
   * A module's hook_cron ended: ok, or failed with what it threw.
   */
  public function hookFinished(?int $key, string $module, ?\Throwable $error): void {
    if ($error !== NULL) {
      $this->modules[$module] = TRUE;
    }
    if ($key === NULL) {
      return;
    }
    try {
      $this->client()->finishExecution($key, NULL, $error, $error !== NULL);
    }
    catch (\Throwable $problem) {
      $this->safeReport($problem, "finishing drupal:{$module}");
    }
  }

  /**
   * The cron run ended (after its queues), ok or with what it threw.
   *
   * Returns whether a run was open, so the caller knows this process ran
   * cron rather than finding it locked.
   */
  public function cronFinished(?\Throwable $error): bool {
    $key = $this->cronKey;
    $this->cronKey = NULL;
    $this->inCron = FALSE;
    if ($key === NULL) {
      return FALSE;
    }
    $failed = array_keys(array_filter($this->modules));
    $output = ($this->cronService() === 'ultimate_cron' ? 'jobs: ' : 'hook_cron: ') . ($this->modules === [] ? 'none' : implode(', ', array_keys($this->modules)));
    if ($failed !== []) {
      $output .= "\nfailed: " . implode(', ', $failed);
    }
    try {
      $this->client()->finishExecution($key, NULL, $error, $error !== NULL, $output);
    }
    catch (\Throwable $problem) {
      $this->safeReport($problem, 'finishing ' . self::CRON_JOB);
    }
    return TRUE;
  }

  /**
   * An Ultimate Cron job is about to run its callback (it holds its lock);
   * returns its run's key, or null.
   *
   * Launched by a cron run, the trigger is "ultimate-cron" and the job is
   * listed in the cron run's output; launched on its own (its "Run" button,
   * `drush cron:run <job>`), "ultimate-cron-manual".
   *
   * @param \Drupal\ultimate_cron\Entity\CronJob $job
   *   The job.
   */
  public function ultimateJobStarted(object $job): ?int {
    $id = (string) $job->id();
    if ($this->inCron) {
      $this->modules[$id] ??= FALSE;
    }
    try {
      return $this->client()->startExecution($this->ultimateJob($job)->definition, $this->inCron ? self::TRIGGER_ULTIMATE_CRON : self::TRIGGER_ULTIMATE_CRON_MANUAL);
    }
    catch (\Throwable $error) {
      $this->safeReport($error, "starting the Ultimate Cron job {$id}");
      return NULL;
    }
  }

  /**
   * An Ultimate Cron job's callback ended: ok, or failed with what it threw.
   */
  public function ultimateJobFinished(?int $key, string $id, ?\Throwable $error): void {
    if ($error !== NULL && $this->inCron) {
      $this->modules[$id] = TRUE;
    }
    if ($key === NULL) {
      return;
    }
    try {
      $this->client()->finishExecution($key, NULL, $error, $error !== NULL);
    }
    catch (\Throwable $problem) {
      $this->safeReport($problem, "finishing the Ultimate Cron job {$id}");
    }
  }

  /**
   * The check at the end of a cron run, when the settings ask for it.
   */
  public function checkAfterCron(): void {
    if (!$this->settings()->get('check_on_cron')) {
      return;
    }
    try {
      $this->check();
    }
    catch (\Throwable $error) {
      $this->safeReport($error, 'check');
    }
  }

  /**
   * One queue item, processed by `process` as a run of the worker's job.
   *
   * What it throws is recorded as the failure and thrown again, so the
   * queue runner releases, delays, or keeps the item as it would.
   */
  public function queueItem(string $id, string $class, callable $process): mixed {
    $key = NULL;
    try {
      $key = $this->client()->startExecution($this->queueJob($id, $class)->definition, self::TRIGGER_QUEUE);
    }
    catch (\Throwable $error) {
      $this->safeReport($error, "starting drupal:queue:{$id}");
    }
    try {
      $result = $process();
    }
    catch (\Throwable $error) {
      if ($key !== NULL) {
        $this->client()->finishExecution($key, NULL, $error, TRUE);
      }
      throw $error;
    }
    if ($key !== NULL) {
      $this->client()->finishExecution($key, is_string($result) ? $result : NULL);
    }
    return $result;
  }

  /**
   * Reports a problem once in this process, however often it is met.
   */
  private function reportOnce(\Throwable $error, string $where): void {
    $key = $where . "\n" . $error->getMessage();
    if (isset($this->reported[$key])) {
      return;
    }
    $this->reported[$key] = TRUE;
    $this->safeReport($error, $where);
  }

  /**
   * Reports without ever throwing: cron must go on whatever CronWatch does.
   */
  private function safeReport(\Throwable $error, string $where): void {
    try {
      $this->report($error, $where);
    }
    catch (\Throwable) {
    }
  }

}
