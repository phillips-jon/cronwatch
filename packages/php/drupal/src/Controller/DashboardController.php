<?php

declare(strict_types=1);

namespace Drupal\cronwatch\Controller;

use Cronwatch\Bridge\EmbeddedDashboard;
use Cronwatch\Env;
use Cronwatch\Web\Dashboard;
use Cronwatch\Web\HttpFoundation;
use Drupal\Core\Access\CsrfTokenGenerator;
use Drupal\Core\Controller\ControllerBase;
use Drupal\Core\Site\Settings;
use Drupal\Core\Url;
use Drupal\cronwatch\Recorder;
use Symfony\Component\DependencyInjection\ContainerInterface;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\HttpFoundation\Response;
use Symfony\Component\HttpKernel\Exception\AccessDeniedHttpException;
use Symfony\Component\HttpKernel\Exception\NotFoundHttpException;

/**
 * The library's dashboard, behind Drupal's sign-in and permissions.
 *
 * /admin/reports/cronwatch is an admin page with the dashboard in a frame
 * (the dashboard is a page of its own, with its own styles and a strict
 * CSP). /admin/reports/cronwatch/view?cw=<path> is the dashboard's page at
 * <path>: Drupal has checked the "view cronwatch dashboard" permission by
 * then, so the dashboard runs open (token false), Drupal's sign-in standing
 * for its token. A change (silence, forget, "Run check now", all POSTs)
 * also needs "administer cronwatch" and Drupal's CSRF token, which every
 * form's action carries, besides the dashboard's own same-origin check.
 * Links, forms and redirects are rewritten to that route (see
 * EmbeddedDashboard), and the app shell is left out.
 *
 * /cronwatch/api/... is the JSON API for @cronwatch/mcp, with the
 * dashboard's token ($settings['cronwatch_token'] in settings.php, else
 * CRONWATCH_TOKEN). Without a token it is not there (404).
 */
final class DashboardController extends ControllerBase {

  /**
   * The CSRF token's value, for the dashboard's forms.
   */
  public const CSRF = 'cronwatch-dashboard';

  public function __construct(
    private readonly Recorder $recorder,
    private readonly CsrfTokenGenerator $csrf,
  ) {
  }

  /**
   * {@inheritdoc}
   */
  public static function create(ContainerInterface $container) {
    return new static($container->get('cronwatch.recorder'), $container->get('csrf_token'));
  }

  /**
   * The admin page: the dashboard in a frame, at a job's page when asked.
   *
   * @return array<string, mixed>
   *   A render array.
   */
  public function page(Request $request): array {
    $job = (string) $request->query->get('job', '');
    $at = $job === '' ? '/' : '/jobs/' . rawurlencode($job);
    $src = $this->viewUrl($at);
    return [
      '#attached' => ['library' => ['cronwatch/admin']],
      'links' => [
        '#type' => 'html_tag',
        '#tag' => 'p',
        '#attributes' => ['class' => ['cronwatch-dashboard-links']],
        'open' => [
          '#type' => 'link',
          '#title' => $this->t('Open on its own'),
          '#url' => Url::fromRoute('cronwatch.dashboard_view', [], ['query' => ['cw' => $at]]),
          '#attributes' => ['target' => '_blank', 'rel' => 'noopener'],
        ],
      ],
      'frame' => [
        '#type' => 'html_tag',
        '#tag' => 'iframe',
        '#attributes' => [
          'class' => ['cronwatch-dashboard-frame'],
          'title' => $this->t('CronWatch dashboard'),
          'src' => $src,
        ],
      ],
      '#cache' => ['max-age' => 0],
    ];
  }

  /**
   * The dashboard's page at ?cw=<path>, rewritten for Drupal.
   */
  public function view(Request $request): Response {
    $method = strtoupper($request->getMethod());
    $path = (string) $request->query->get('cw', '/');
    if ($method !== 'GET' && $method !== 'HEAD') {
      if (!$this->currentUser()->hasPermission('administer cronwatch')) {
        throw new AccessDeniedHttpException('Changing CronWatch needs the "administer cronwatch" permission.');
      }
      if (!$this->csrf->validate((string) $request->query->get('token', ''), self::CSRF)) {
        throw new AccessDeniedHttpException('The form has expired. Go back, reload the page and try again.');
      }
      if ($path === '/check') {
        // The module's check: every job declared first.
        $this->recorder->prepare();
      }
    }
    $dashboard = new Dashboard($this->recorder->client(), token: FALSE, basePath: EmbeddedDashboard::MARKER, origin: $request->getSchemeAndHttpHost());
    $inner = EmbeddedDashboard::request(HttpFoundation::toRequest($request), $path, ['cw', 'token']);
    $answer = EmbeddedDashboard::rewrite(
      $dashboard->handle($inner),
      fn (string $path, array $query): string => $this->viewUrl($path, $query),
      fn (string $url): string => $url . (str_contains($url, '?') ? '&' : '?') . 'token=' . rawurlencode($this->csrf->get(self::CSRF)),
    );
    return HttpFoundation::toResponse($answer);
  }

  /**
   * The JSON API, for @cronwatch/mcp, with the dashboard's token.
   */
  public function api(Request $request): Response {
    $token = Settings::get('cronwatch_token');
    $token = is_string($token) && $token !== '' ? $token : Env::read('CRONWATCH_TOKEN');
    if ($token === NULL || $token === '') {
      throw new NotFoundHttpException();
    }
    $inner = HttpFoundation::toRequest($request);
    $at = strpos($inner->path, '/cronwatch/api');
    if ($at === FALSE) {
      throw new NotFoundHttpException();
    }
    if (strtoupper($request->getMethod()) === 'POST' && str_ends_with(rtrim($inner->path, '/'), '/cronwatch/api/check')) {
      $this->recorder->prepare();
    }
    $dashboard = new Dashboard($this->recorder->client(), token: $token, basePath: substr($inner->path, 0, $at) . '/cronwatch');
    return HttpFoundation::toResponse($dashboard->handle($inner));
  }

  /**
   * The route of the dashboard's page at a path.
   *
   * @param array<string, string> $query
   *   The page's own query.
   */
  private function viewUrl(string $path, array $query = []): string {
    return Url::fromRoute('cronwatch.dashboard_view', [], ['query' => ['cw' => $path] + $query])->toString(TRUE)->getGeneratedUrl();
  }

}
