package dev.cronwatch.web;

import dev.cronwatch.CheckResult;
import dev.cronwatch.Cronwatch;
import dev.cronwatch.CronwatchException;
import dev.cronwatch.JobSummary;
import dev.cronwatch.JobWithRuns;
import dev.cronwatch.Run;
import dev.cronwatch.internal.core.Access;
import dev.cronwatch.internal.duration.Durations;
import dev.cronwatch.internal.evaluate.Evaluate;
import dev.cronwatch.internal.js.Js;
import dev.cronwatch.internal.web.Html;
import dev.cronwatch.internal.web.Origins;
import dev.cronwatch.internal.web.Pwa;
import dev.cronwatch.internal.web.Requests;
import dev.cronwatch.internal.web.Text;
import dev.cronwatch.internal.web.Timeline;
import dev.cronwatch.internal.web.Timeline.LaneInput;
import dev.cronwatch.json.JsObject;
import java.io.IOException;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.security.SecureRandom;
import java.util.ArrayList;
import java.util.Base64;
import java.util.HashMap;
import java.util.HexFormat;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Objects;
import java.util.concurrent.atomic.AtomicBoolean;
import org.jspecify.annotations.Nullable;

/**
 * The dashboard and its small JSON API, the SDK's {@code cw.routes()} ({@code routes/index.ts}),
 * framework-free: {@link #handle} takes a {@link Request} and answers a {@link Response}, with the
 * same URLs, JSON, status codes, headers, cookie, redirects, cross-site rule and token rules as the
 * SDK's routes, so {@code @cronwatch/mcp} works against a Java app as it does against a Node one.
 * Every framework is an adapter over {@link #handle}: {@link WebServer} for the JDK's own server,
 * {@code cronwatch-servlet} for a servlet container, and the Spring Boot starter for Spring MVC and
 * WebFlux. Safe to share between threads.
 *
 * <pre>{@code
 * Routes routes = cw.routes(RoutesOptions.builder().token(System.getenv("CRONWATCH_TOKEN")).build());
 * WebServer.mount(server, "/cronwatch", routes);
 * }</pre>
 */
public final class Routes implements Endpoint {
  /** Where the dashboard is taken to be mounted when nothing else says. */
  public static final String DEFAULT_BASE_PATH = "/cronwatch";

  private static final String TOKEN_COOKIE = "cronwatch_token";

  /** The package {@code GET <base>/api} names: each port answers with its own. */
  private static final String LIBRARY = "dev.cronwatch:cronwatch";

  /**
   * The JSON API's version, which {@code GET <base>/api} answers. It goes up only for a change that
   * is not additive, in a major release.
   */
  private static final int API_VERSION = 1;

  /** Runs a JSON job read lists by default, and at most. */
  private static final int DEFAULT_RUNS = 20;

  private static final int MAX_RUNS = 500;

  /** Runs per job the board reads in one go: the table's sparkline, and most jobs' lanes. */
  private static final int BOARD_PAGE_RUNS = 20;

  private static final int COOKIE_MAX_AGE = 60 * 60 * 24 * 30;

  // 'self' only for what the app shell needs: app.js (which registers the service worker and
  // nothing else), the manifest, the worker and the icons. No inline script, and the pages work
  // without any.
  private static final String PAGE_CSP =
      "default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; img-src 'self' data:;"
          + " manifest-src 'self'; worker-src 'self'; form-action 'self'; frame-ancestors 'none';"
          + " base-uri 'none'";
  private static final String ASSET_CSP =
      "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'";

  /**
   * On every answer. same-origin rather than no-referrer: under no-referrer browsers send {@code
   * Origin: null} on form posts, which the cross-site check would refuse, and the forms redirect
   * back to the page named by the same-origin Referer.
   */
  private static final String[][] SECURITY_HEADERS = {
    {"x-content-type-options", "nosniff"},
    {"referrer-policy", "same-origin"},
    {"x-robots-tag", "noindex"}
  };

  private static final String SIGN_IN_INTRO =
      "[cronwatch] CRONWATCH_TOKEN is not set, so this development server made a token for the"
          + " dashboard. Sign in: ";

  private final Cronwatch cw;
  private final boolean optedOut;
  private final String token;
  private final boolean generated;
  private final String cookie;
  private final @Nullable String base;
  private final @Nullable String origin;
  private final boolean trustProxy;
  private final AtomicBoolean announced = new AtomicBoolean();

  private Routes(Cronwatch cw, RoutesOptions options) {
    this.cw = Objects.requireNonNull(cw, "cw");
    try {
      this.origin = Origins.configured(options.origin());
    } catch (IllegalArgumentException e) {
      throw CronwatchException.invalid(Objects.requireNonNullElse(e.getMessage(), "origin"));
    }
    this.optedOut = options.tokenGiven() && options.token() == null;
    String configured;
    String given = options.token();
    if (optedOut) {
      configured = "";
    } else if (given != null && !given.isEmpty()) {
      configured = given;
    } else {
      configured = Objects.requireNonNullElse(System.getenv("CRONWATCH_TOKEN"), "");
    }
    // A handler cannot tell a local caller from a remote one (proxies, tunnels and a server
    // listening on every interface all look alike), so development gets a token too: made here,
    // and shown only in the log.
    boolean generate =
        configured.isEmpty() && !optedOut && Access.client().environment(cw).equals("development");
    this.token = generate ? developmentToken() : configured;
    // Without the system's randomness no token was made, so there is nothing to announce and the
    // routes stay locked.
    this.generated = generate && !token.isEmpty();
    this.cookie = token.isEmpty() ? "" : cookieValue(token);
    String b = options.basePath();
    this.base = b == null ? null : trimTrailingSlashes(b);
    this.trustProxy = options.trustProxy();
  }

  /**
   * The dashboard and its JSON API for this client: {@code cw.routes(options)}.
   *
   * @throws CronwatchException for an {@code origin} that is not an http or https URL, with the
   *     SDK's message
   */
  public static Routes of(Cronwatch cw, RoutesOptions options) {
    return new Routes(cw, options);
  }

  private static String trimTrailingSlashes(String s) {
    int end = s.length();
    while (end > 0 && s.charAt(end - 1) == '/') {
      end--;
    }
    return s.substring(0, end);
  }

  /**
   * The cookie holds a digest of the token, so a leaked cookie does not reveal the bearer token
   * itself: the SHA-256 of {@code cronwatch-cookie:<token>}, as hex.
   */
  private static String cookieValue(String token) {
    try {
      MessageDigest sha = MessageDigest.getInstance("SHA-256");
      return HexFormat.of().formatHex(sha.digest(Js.utf8("cronwatch-cookie:" + token)));
    } catch (NoSuchAlgorithmException e) {
      throw new IllegalStateException(e);
    }
  }

  /** 32 random bytes, base64url (43 characters), or {@code ""} without system randomness. */
  private static String developmentToken() {
    byte[] b = new byte[32];
    try {
      new SecureRandom().nextBytes(b);
    } catch (RuntimeException e) {
      // No system randomness: a token nobody can guess cannot be made, so make one nobody can use
      // either.
      return "";
    }
    return Base64.getUrlEncoder().withoutPadding().encodeToString(b);
  }

  /**
   * The line a development token is announced with, once, on the routes' first request. {@code
   * shown} is the configured origin when set, otherwise that request's public origin when its host
   * is loopback, and null for any other host: the request's host is the client's to choose, so the
   * line then leaves it out rather than point the link, token and all, somewhere else.
   */
  static String developmentSignInLine(@Nullable String shown, String base, String token) {
    if (shown == null) {
      return SIGN_IN_INTRO
          + base
          + "/?token="
          + token
          + " on this server (the first request's host is not local, so the link leaves it out)";
    }
    return SIGN_IN_INTRO + shown + base + "/?token=" + token;
  }

  /**
   * The token the dashboard asks for (the generated one in development), or null when it is open or
   * locked for want of one.
   */
  public @Nullable String token() {
    return token.isEmpty() ? null : token;
  }

  /** Names the base and the origin, never the token. */
  @Override
  public String toString() {
    return "Routes[base=" + base + ", origin=" + origin + "]";
  }

  // ---- answers

  private static Response withSecurity(Response r) {
    Response out = r;
    for (String[] h : SECURITY_HEADERS) {
      out = out.withHeader(h[0], h[1]);
    }
    return out;
  }

  /** A JSON answer with the security headers. */
  private static Response api(JsObject body, int status) {
    return api(body, status, null);
  }

  private static Response api(JsObject body, int status, String @Nullable [] extra) {
    Response r =
        withSecurity(
            Response.of(status)
                .withHeader("content-type", "application/json; charset=utf-8")
                .withHeader("cache-control", "no-store"));
    if (extra != null) {
      r = r.withHeader(extra[0], extra[1]);
    }
    return r.withBody(Js.utf8(body.toJson()));
  }

  private static JsObject errorBody(String message) {
    return new JsObject().set("ok", false).set("error", message);
  }

  private static Response redirect(String location, String @Nullable [] extra) {
    Response r =
        withSecurity(
            Response.of(303)
                .withHeader("location", location)
                .withHeader("cache-control", "no-store"));
    return extra == null ? r : r.withHeader(extra[0], extra[1]);
  }

  private static Response html(String body, int status, String cache) {
    return withSecurity(
            Response.of(status)
                .withHeader("content-type", "text/html; charset=utf-8")
                .withHeader("cache-control", cache)
                .withHeader("content-security-policy", PAGE_CSP)
                .withHeader("x-frame-options", "DENY"))
        .withBody(Js.utf8(body));
  }

  private static Response page(String body, int status) {
    return html(body, status, "no-store");
  }

  /**
   * An app shell file. The worker may be scoped to the base (it is served from there anyway); the
   * SVGs get a CSP of their own.
   */
  private static Response shell(Pwa.Asset asset, String base) {
    Response r =
        withSecurity(
            Response.of(200)
                .withHeader("content-type", asset.contentType())
                .withHeader("cache-control", asset.cache()));
    if (asset.contentType().equals("image/svg+xml")) {
      r = r.withHeader("content-security-policy", ASSET_CSP);
    }
    if (asset.worker()) {
      r = r.withHeader("service-worker-allowed", base + "/");
    }
    return r.withBody(asset.body());
  }

  private static Response tooLarge(boolean wantsHtml, String base) {
    if (wantsHtml) {
      return page(Html.messagePage("Not silenced", "The request was too large.", base, false), 413);
    }
    return api(errorBody("Request body too large"), 413);
  }

  // ---- reading a request

  /** The first entry of a comma-separated header, trimmed, or null when there is none. */
  private static @Nullable String firstValue(Request req, String name) {
    String value = req.header(name);
    if (value == null) {
      return null;
    }
    int comma = value.indexOf(',');
    String first = Js.trim(comma < 0 ? value : value.substring(0, comma));
    return first.isEmpty() ? null : first;
  }

  /** The named cookie, decoded, or null; a malformed escape counts as no cookie. */
  private static @Nullable String readCookie(Request req, String name) {
    String value = req.header("cookie");
    if (value == null || value.isEmpty()) {
      return null;
    }
    for (String part : value.split(";", -1)) {
      String p = Js.trim(part);
      int eq = p.indexOf('=');
      String key = eq < 0 ? p : p.substring(0, eq);
      if (key.equals(name)) {
        return Requests.safeDecode(eq < 0 ? "" : p.substring(eq + 1));
      }
    }
    return null;
  }

  /**
   * A browser attaches {@code Origin} or {@code Sec-Fetch-Site} to a cross-site form post, and a
   * page cannot forge either. Non-browser clients send neither.
   */
  private static boolean crossSite(Request req, String publicOrigin) {
    String o = req.header("origin");
    if (o != null && !o.equals(publicOrigin)) {
      return true;
    }
    String site = req.header("sec-fetch-site");
    return site != null && !site.equals("same-origin") && !site.equals("none");
  }

  private static boolean isBearerPrefix(String text) {
    if (text.length() <= 6) {
      return false;
    }
    String word = "bearer";
    for (int i = 0; i < 6; i++) {
      char c = text.charAt(i);
      char lower = c >= 'A' && c <= 'Z' ? (char) (c + 32) : c;
      if (lower != word.charAt(i)) {
        return false;
      }
    }
    return true;
  }

  /**
   * The {@code Authorization} header without its {@code Bearer } (in any case, with any spaces
   * after it), or null when there is none.
   */
  private static @Nullable String bearer(Request req) {
    String text = req.header("authorization");
    if (text == null) {
      return null;
    }
    if (isBearerPrefix(text)) {
      int i = 6;
      while (i < text.length() && Js.isSpace(text.charAt(i))) {
        i++;
      }
      if (i > 6) {
        return text.substring(i);
      }
    }
    return text;
  }

  /**
   * Absent means one hour; a number or numeric string is milliseconds.
   *
   * @throws IllegalArgumentException with the SDK's message for anything else
   */
  static double silenceDuration(@Nullable String value) {
    if (value == null) {
      return Durations.parseValue("1h", "silence duration");
    }
    String text = Js.trim(value);
    Object duration = isNumeric(text) ? (Object) Double.parseDouble(text) : text;
    return Durations.parseValue(duration, "silence duration");
  }

  /** {@code /^\d+(\.\d+)?$/}. */
  private static boolean isNumeric(String text) {
    int dot = text.indexOf('.');
    String whole = dot < 0 ? text : text.substring(0, dot);
    String fraction = dot < 0 ? null : text.substring(dot + 1);
    return digits(whole) && (fraction == null || digits(fraction));
  }

  private static boolean digits(String s) {
    if (s.isEmpty()) {
      return false;
    }
    for (int i = 0; i < s.length(); i++) {
      if (s.charAt(i) < '0' || s.charAt(i) > '9') {
        return false;
      }
    }
    return true;
  }

  static int runsLimit(@Nullable String value) {
    if (value == null || Js.trim(value).isEmpty()) {
      return DEFAULT_RUNS;
    }
    double n = Evaluate.jsNumber(value);
    if (!Double.isFinite(n)) {
      return DEFAULT_RUNS;
    }
    n = n < 0 ? Math.ceil(n) : Math.floor(n);
    return (int) Math.max(1, Math.min(MAX_RUNS, n));
  }

  /** Where the dashboard is mounted for this request: the option, else the adapter's, else ours. */
  private String basePath(Request req) {
    if (base != null) {
      return base;
    }
    String mount = req.mount();
    return mount != null ? trimTrailingSlashes(mount) : DEFAULT_BASE_PATH;
  }

  /** The origin a browser sees: the configured one, the forwarded one under trustProxy, or ours. */
  private String publicOrigin(Request req) {
    if (origin != null) {
      return origin;
    }
    String host = Objects.requireNonNullElse(req.header("host"), "");
    String own = Origins.ofRequest(req.isTls(), host);
    if (!trustProxy) {
      return own;
    }
    String proto = firstValue(req, "x-forwarded-proto");
    if (proto != null) {
      proto = proto.toLowerCase(Locale.ROOT);
    }
    String forwardedHost = firstValue(req, "x-forwarded-host");
    if (proto == null && forwardedHost == null) {
      return own;
    }
    if (proto != null && !proto.equals("http") && !proto.equals("https")) {
      return own;
    }
    int sep = own.indexOf("://");
    String ownScheme = sep < 0 ? own : own.substring(0, sep);
    String ownHost = sep < 0 ? "" : own.substring(sep + 3);
    String built =
        Origins.bare(
            (proto != null ? proto : ownScheme)
                + "://"
                + (forwardedHost != null ? forwardedHost : ownHost));
    return built != null ? built : own;
  }

  /** What a request says, read before anything is served. */
  private record Said(
      String method,
      String publicOrigin,
      List<Map.Entry<String, String>> query,
      @Nullable String bearer,
      @Nullable String cookie,
      String referer,
      String contentType,
      boolean crossSite) {}

  // ---- serving

  /**
   * Answers one request as the SDK's routes answer it. A store failure (or anything else thrown) is
   * reported to the client's error handler as {@code routes} and answered 500; an {@link Error} is
   * reported and thrown again.
   */
  @Override
  public Response handle(Request req) {
    String[] target = Requests.target(req.target());
    String b = basePath(req);
    String pathname = Requests.normalizePath(target[0]);
    String path = Requests.stripBase(pathname, b);
    boolean wantsHtml = !path.startsWith("/api");
    try {
      return serve(req, pathname, path, target[1], b, wantsHtml);
    } catch (Error e) {
      cw.reportError(e, "routes");
      throw e;
    } catch (RuntimeException e) {
      cw.reportError(e, "routes");
      if (wantsHtml) {
        return page(
            Html.messagePage(
                "Something went wrong", "The request failed and the error was reported.", b, false),
            500);
      }
      return api(errorBody("Internal error"), 500);
    }
  }

  private Said read(Request req, String rawQuery) {
    String publicOrigin = publicOrigin(req);
    return new Said(
        req.method().toUpperCase(Locale.ROOT),
        publicOrigin,
        Requests.parseQuery(rawQuery),
        bearer(req),
        readCookie(req, TOKEN_COOKIE),
        Objects.requireNonNullElse(req.header("referer"), ""),
        Objects.requireNonNullElse(req.header("content-type"), ""),
        crossSite(req, publicOrigin));
  }

  /** The body up to the cap, none when it could not be read to its end, or null past the cap. */
  private static byte @Nullable [] readLimited(Request req) {
    try {
      return req.readBody(Request.MAX_BODY);
    } catch (Request.BodyTooLargeException e) {
      return null;
    } catch (IOException e) {
      // A body cut short is none, as the SDK's readBody has it, never the part that arrived:
      // "for=7d" cut short is "for=7", a silence of 7 ms.
      return new byte[0];
    }
  }

  private Response serve(
      Request req, String pathname, String path, String rawQuery, String base, boolean wantsHtml) {
    Said said = read(req, rawQuery);
    String method = said.method();

    if (generated && !announced.getAndSet(true)) {
      String shown = origin;
      if (shown == null && Origins.isLoopback(said.publicOrigin())) {
        shown = said.publicOrigin();
      }
      // System.out never throws; a closed output is ignored, as console.info never throws.
      System.out.println(developmentSignInLine(shown, base, token));
    }

    // The app shell: the manifest, icons, service worker, app.js and the offline page. Served to
    // anyone, since a browser fetches some of it without cookies and none of it says anything about
    // the jobs.
    if (method.equals("GET") || method.equals("HEAD")) {
      if (path.equals("/offline")) {
        return html(
            Html.messagePage(
                "You are offline",
                "CronWatch shows live data from your app, so it needs a connection.",
                base,
                false),
            200,
            "no-cache");
      }
      Pwa.Asset asset = Pwa.asset(path, base);
      if (asset != null) {
        return shell(asset, base);
      }
    }

    // No token outside development: fail closed.
    if (token.isEmpty() && !optedOut) {
      if (wantsHtml) {
        return page(
            Html.messagePage(
                "CronWatch routes are locked",
                "Set CRONWATCH_TOKEN (or pass RoutesOptions.token to cw.routes(), or set"
                    + " cronwatch.web.token in Spring Boot), or pass RoutesOptions.noToken() to"
                    + " serve them open behind your own auth.",
                base,
                false),
            503);
      }
      return api(errorBody("CRONWATCH_TOKEN is not set"), 503);
    }

    if (!method.equals("GET") && !method.equals("HEAD") && said.crossSite()) {
      if (wantsHtml) {
        return page(
            Html.messagePage(
                "Cross-site request refused",
                "Changes can only be made from the dashboard itself.",
                base,
                false),
            403);
      }
      return api(errorBody("Cross-site request refused"), 403);
    }

    if (!token.isEmpty()) {
      // ?token= is only the sign-in that moves the token into a cookie.
      String queryToken =
          wantsHtml && method.equals("GET") ? Requests.param(said.query(), "token") : null;
      String secret = cw.cronSecret();
      boolean cronSecretOk =
          path.equals("/api/check")
              && said.bearer() != null
              && secret != null
              && Text.constantTimeEquals(said.bearer(), secret);
      boolean tokenOk;
      if (said.bearer() != null) {
        tokenOk = Text.constantTimeEquals(said.bearer(), token);
      } else if (queryToken != null) {
        tokenOk = Text.constantTimeEquals(queryToken, token);
      } else if (said.cookie() != null) {
        tokenOk = Text.constantTimeEquals(said.cookie(), cookie);
      } else {
        tokenOk = false;
      }
      if (!cronSecretOk && !tokenOk) {
        if (generated) {
          if (wantsHtml) {
            return page(
                Html.messagePage(
                    "Sign in",
                    "CRONWATCH_TOKEN is not set, so this development server made a token. The"
                        + " sign-in link is in the server log: open it once and this browser stays"
                        + " signed in.",
                    base,
                    true),
                401);
          }
          return api(
              errorBody(
                  "Unauthorized: CRONWATCH_TOKEN is not set, so this development server made a"
                      + " token; it is in the server log"),
              401);
        }
        if (wantsHtml) {
          return page(
              Html.messagePage(
                  "Sign in",
                  "Open this page with ?token=<your CRONWATCH_TOKEN> once and it will stay signed"
                      + " in.",
                  base,
                  true),
              401);
        }
        return api(errorBody("Unauthorized"), 401);
      }
      if (queryToken != null) {
        // Move the token from the URL into a cookie so it is not in history or logs.
        List<String> rest = new ArrayList<>();
        for (Map.Entry<String, String> p : said.query()) {
          if (!p.getKey().equals("token")) {
            rest.add(Requests.formEncode(p.getKey()) + "=" + Requests.formEncode(p.getValue()));
          }
        }
        String search = rest.isEmpty() ? "" : "?" + String.join("&", rest);
        String secure = said.publicOrigin().startsWith("https:") ? "; Secure" : "";
        String cookiePath = base.isEmpty() ? "/" : base;
        return redirect(
            pathname + search,
            new String[] {
              "set-cookie",
              TOKEN_COOKIE
                  + "="
                  + cookie
                  + "; Path="
                  + cookiePath
                  + "; HttpOnly; SameSite=Lax; Max-Age="
                  + COOKIE_MAX_AGE
                  + secure
            });
      }
    }

    List<String> parts = new ArrayList<>();
    for (String part : path.split("/", -1)) {
      if (part.isEmpty()) {
        continue;
      }
      String decoded = Requests.safeDecode(part);
      if (decoded == null) {
        if (wantsHtml) {
          return page(Html.messagePage("Bad request", "The path is not valid.", base, false), 400);
        }
        return api(errorBody("Bad path"), 400);
      }
      parts.add(decoded);
    }

    // HTML
    if (method.equals("GET") && path.equals("/")) {
      List<JobWithRuns> entries = cw.jobsWithRuns(BOARD_PAGE_RUNS);
      long now = cw.now();
      Map<String, List<Run>> runsByJob = new HashMap<>();
      List<JobSummary> jobs = new ArrayList<>();
      for (JobWithRuns e : entries) {
        runsByJob.put(e.job().name(), e.runs());
        jobs.add(e.job());
      }
      List<LaneInput> lanes = boardLanes(entries, now);
      return page(Html.dashboardPage(jobs, runsByJob, now, base, null, lanes), 200);
    }
    if (method.equals("GET") && parts.size() == 2 && parts.get(0).equals("jobs")) {
      String name = parts.get(1);
      JobSummary job = cw.jobSummary(name);
      if (job == null) {
        return page(
            Html.messagePage("No such job", name + " is not in the store.", base, false), 404);
      }
      long now = cw.now();
      // Enough runs to draw the job's week; the page lists the newest fifty.
      int limit = Timeline.weekRunsLimit(job, now);
      List<Run> runs = cw.runs(job.name(), limit);
      return page(Html.jobPage(job, runs, now, base, runs.size() < limit), 200);
    }
    if (method.equals("POST") && path.equals("/check")) {
      cw.check();
      return redirectBack(said, base);
    }
    if (method.equals("POST") && parts.size() == 3 && parts.get(0).equals("jobs")) {
      String name = parts.get(1);
      String action = parts.get(2);
      if (action.equals("forget")) {
        cw.forget(name);
        return redirect(base + "/", null);
      }
      if (!action.equals("silence") && !action.equals("unsilence")) {
        return page(Html.messagePage("Not found", path, base, false), 404);
      }
      if (cw.jobSummary(name) == null) {
        return page(
            Html.messagePage("No such job", name + " is not in the store.", base, false), 404);
      }
      if (action.equals("silence")) {
        byte[] data = readLimited(req);
        if (data == null) {
          return tooLarge(true, base);
        }
        String value = Requests.bodyField(said.contentType(), data, "for");
        double ms;
        try {
          ms = silenceDuration(value);
        } catch (IllegalArgumentException e) {
          return page(
              Html.messagePage(
                  "Not silenced", Objects.requireNonNullElse(e.getMessage(), ""), base, false),
              400);
        }
        Access.client().silence(cw, name, ms);
      } else {
        cw.unsilence(name);
      }
      return redirectBack(said, base);
    }

    // JSON API
    if (!parts.isEmpty() && parts.get(0).equals("api")) {
      return serveApi(req, method, parts.subList(1, parts.size()), said);
    }
    return page(Html.messagePage("Not found", path, base, false), 404);
  }

  private static Response redirectBack(Said said, String base) {
    if (said.referer().startsWith(said.publicOrigin() + "/")) {
      return redirect(said.referer(), null);
    }
    return redirect(base + "/", null);
  }

  /**
   * The board's timeline lanes, the first {@link Timeline#BOARD_LANES} jobs. The runs already read
   * for the table usually cover the last day; only a job whose twenty newest runs all fall inside
   * it is read again, deeper.
   */
  private List<LaneInput> boardLanes(List<JobWithRuns> entries, long now) {
    long from = now - Timeline.BOARD_BEHIND_MS;
    List<LaneInput> lanes = new ArrayList<>();
    for (JobWithRuns e : entries.subList(0, Math.min(entries.size(), Timeline.BOARD_LANES))) {
      List<Run> runs = e.runs();
      boolean isShort =
          runs.size() >= BOARD_PAGE_RUNS && runs.get(runs.size() - 1).startedAt() > from;
      if (!isShort) {
        lanes.add(new LaneInput(e.job(), runs, true));
        continue;
      }
      List<Run> deeper = cw.runs(e.job().name(), Timeline.BOARD_RUNS);
      lanes.add(new LaneInput(e.job(), deeper, deeper.size() < Timeline.BOARD_RUNS));
    }
    return lanes;
  }

  /** A silence's or an unsilence's answer: the job's summary after it, as GET answers it. */
  private Response summaryAnswer(String name) {
    JobSummary job = cw.jobSummary(name);
    return api(new JsObject().set("ok", true).set("job", job == null ? null : job.toValue()), 200);
  }

  private Response serveApi(Request req, String method, List<String> rest, Said said) {
    int n = rest.size();
    String first = n > 0 ? rest.get(0) : "";
    // What is serving the API, so a client such as @cronwatch/mcp can tell.
    if (method.equals("GET") && n == 0) {
      return api(
          new JsObject()
              .set("ok", true)
              .set("library", LIBRARY)
              .set("language", "java")
              .set("version", Cronwatch.VERSION)
              .set("api", API_VERSION),
          200);
    }
    if (method.equals("GET") && n == 1 && first.equals("jobs")) {
      List<Object> list = new ArrayList<>();
      for (JobSummary j : cw.jobs()) {
        list.add(j.toValue());
      }
      return api(new JsObject().set("ok", true).set("jobs", list), 200);
    }
    if (n == 2 && first.equals("jobs")) {
      String name = rest.get(1);
      if (method.equals("GET")) {
        JobSummary job = cw.jobSummary(name);
        if (job == null) {
          return api(errorBody("No such job"), 404);
        }
        List<Object> runs = new ArrayList<>();
        for (Run r : cw.runs(name, runsLimit(Requests.param(said.query(), "runs")))) {
          runs.add(r.toValue());
        }
        return api(new JsObject().set("ok", true).set("job", job.toValue()).set("runs", runs), 200);
      }
      if (method.equals("DELETE")) {
        if (cw.jobSummary(name) == null) {
          return api(errorBody("No such job"), 404);
        }
        cw.forget(name);
        return api(new JsObject().set("ok", true), 200);
      }
    }
    if (method.equals("POST") && n == 3 && first.equals("jobs")) {
      String name = rest.get(1);
      if (cw.jobSummary(name) == null) {
        return api(errorBody("No such job"), 404);
      }
      String action = rest.get(2);
      if (action.equals("silence")) {
        byte[] data = readLimited(req);
        if (data == null) {
          return tooLarge(false, "");
        }
        String value = Requests.bodyField(said.contentType(), data, "for");
        if (value == null) {
          value = Requests.param(said.query(), "for");
        }
        double ms;
        try {
          ms = silenceDuration(value);
        } catch (IllegalArgumentException e) {
          return api(errorBody(Objects.requireNonNullElse(e.getMessage(), "")), 400);
        }
        Access.client().silence(cw, name, ms);
        return summaryAnswer(name);
      }
      if (action.equals("unsilence")) {
        cw.unsilence(name);
        return summaryAnswer(name);
      }
    }
    if (n == 1 && first.equals("check")) {
      // A page cannot send an Authorization header cross-site, so a GET may only run the check
      // when it carries a bearer (token or cron secret).
      if (method.equals("GET") && said.bearer() == null) {
        return api(
            errorBody("Use POST, or GET with an Authorization bearer"),
            405,
            new String[] {"allow", "POST"});
      }
      if (method.equals("GET") || method.equals("POST")) {
        CheckResult result = cw.check();
        JsObject body = new JsObject().set("ok", true);
        for (Map.Entry<String, @Nullable Object> e : result.toValue().entries()) {
          body.set(e.getKey(), e.getValue());
        }
        return api(body, 200);
      }
    }
    if (method.equals("GET") && n == 2 && first.equals("runs")) {
      Run run = cw.getRun(rest.get(1));
      return run != null
          ? api(new JsObject().set("ok", true).set("run", run.toValue()), 200)
          : api(errorBody("No such run"), 404);
    }
    return api(errorBody("Not found"), 404);
  }
}
