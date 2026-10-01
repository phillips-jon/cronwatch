defmodule Cronwatch.Web.Routes do
  @moduledoc false
  # The dashboard and its small JSON API (routes/index.ts), carried over from
  # the Go port's routes.go through the Rust port's web/routes.rs: the same
  # URLs, JSON, status codes, headers, cookie, redirects, cross-site rule and
  # token rules as the SDK's routes, so @cronwatch/mcp works against an
  # Elixir app as it does against a Node one. Framework-free: `handle/2`
  # takes a Cronwatch.Web.Request and answers {status, headers, body};
  # Cronwatch.Web is the Plug in front of it.

  alias Cronwatch.CheckResult
  alias Cronwatch.Config
  alias Cronwatch.Duration
  alias Cronwatch.Env
  alias Cronwatch.Evaluate
  alias Cronwatch.JobSummary
  alias Cronwatch.JS
  alias Cronwatch.JS.Object
  alias Cronwatch.Run
  alias Cronwatch.Runs
  alias Cronwatch.Web.HTML
  alias Cronwatch.Web.Origin
  alias Cronwatch.Web.PWA
  alias Cronwatch.Web.Request
  alias Cronwatch.Web.Text
  alias Cronwatch.Web.Timeline

  @token_cookie "cronwatch_token"
  # Runs a JSON job read lists by default, and at most.
  @default_runs 20
  @max_runs 500
  # Runs per job the board reads in one go: the table's sparkline, and most
  # jobs' lanes.
  @board_page_runs 20
  @cookie_max_age 60 * 60 * 24 * 30
  @default_base "/cronwatch"

  # What GET <base>/api says is serving it: the package, as its registry
  # names it, the language, and the API's version, which goes up only with a
  # change that is not additive, in a major release.
  @library "cronwatch"
  @language "elixir"
  @api_version 1

  # The most of a request body the dashboard reads: its forms and JSON are a
  # few bytes. A body past it is answered 413; the SDK leaves this to the
  # server in front of it.
  @max_body 1_048_576

  @doc "The most of a request body the dashboard reads; past it the answer is 413."
  def max_body, do: @max_body

  # 'self' only for what the app shell needs: app.js (which registers the
  # service worker and nothing else), the manifest, the worker and the icons.
  # No inline script, and the pages work without any.
  @page_csp "default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; img-src 'self' data:; manifest-src 'self'; worker-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'"
  @asset_csp "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'"

  # On every answer. same-origin rather than no-referrer: under no-referrer
  # browsers send `Origin: null` on form posts, which the cross-site check
  # would refuse, and the forms redirect back to the page named by the
  # same-origin Referer.
  @security_headers [
    {"x-content-type-options", "nosniff"},
    {"referrer-policy", "same-origin"},
    {"x-robots-tag", "noindex"}
  ]

  ## The token

  @doc """
  The token the dashboard asks for, as `{kind, token}`: `{:open, nil}` with
  `token: false`, `{:configured, token}`, `{:generated, token}` in
  development with none set, or `{:locked, nil}` outside it. Read on each
  request, so a release does not bake in its build machine's environment.
  """
  def token_state(opts) do
    configured =
      case opts.token do
        false -> :open
        {:system, var} -> Env.read(var) || Env.read("CRONWATCH_TOKEN")
        t when is_binary(t) and t != "" -> t
        _ -> Env.read("CRONWATCH_TOKEN")
      end

    cond do
      configured == :open -> {:open, nil}
      is_binary(configured) -> {:configured, configured}
      Env.development?() -> {:generated, development_token(opts)}
      true -> {:locked, nil}
    end
  end

  # One token per mount's options, made on first need and kept in the
  # instance's table, so every request process sees the same one.
  defp development_token(opts) do
    table = Runs.table(opts.instance, :flags)
    key = {Cronwatch.Web, :token, opts}

    case :ets.lookup(table, key) do
      [{_, token}] ->
        token

      [] ->
        :ets.insert_new(table, {key, Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)})
        [{_, token}] = :ets.lookup(table, key)
        token
    end
  end

  @doc "The cookie's value for a token: the SHA-256 of `cronwatch-cookie:<token>`, as hex."
  def cookie_value(token), do: :sha256 |> :crypto.hash("cronwatch-cookie:" <> token) |> Base.encode16(case: :lower)

  @doc "The instance's cron secret, or nil: the option, else `CRON_SECRET`, `\"\"` counting as unset."
  def cron_secret(%Config{cron_secret: false}), do: nil
  def cron_secret(%Config{cron_secret: :env}), do: Env.read("CRON_SECRET")
  def cron_secret(%Config{cron_secret: ""}), do: nil
  def cron_secret(%Config{cron_secret: s}) when is_binary(s), do: s
  def cron_secret(_), do: nil

  @doc """
  The line a development token is announced with, once, on the first
  request. `origin` is the configured origin when set, otherwise that
  request's public origin when its host is loopback, and nil for any other
  host: the request's host is the client's to choose, so the line then
  leaves it out rather than point the link, token and all, somewhere else.
  """
  def sign_in_line(origin, base, token) do
    intro =
      "[cronwatch] CRONWATCH_TOKEN is not set, so this development server made a token for the dashboard. Sign in: "

    case origin do
      nil ->
        "#{intro}#{base}/?token=#{token} on this server (the first request's host is not local, so the link leaves it out)"

      origin ->
        "#{intro}#{origin}#{base}/?token=#{token}"
    end
  end

  # On standard output, where console.info writes it. A closed output (the
  # Rust audit's case) must not turn the request into a 500; console.info
  # never throws.
  defp announce(line) do
    IO.puts(line)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  ## Answers

  defp with_security(headers), do: headers ++ @security_headers

  defp api(body, status, extra \\ []) do
    headers =
      with_security([{"content-type", "application/json; charset=utf-8"}, {"cache-control", "no-store"}]) ++ extra

    {status, headers, JS.stringify(body)}
  end

  defp error_body(message), do: Object.new([{"ok", false}, {"error", message}])
  defp ok_body(pairs), do: Object.new([{"ok", true} | pairs])

  defp redirect(location, extra \\ []) do
    {303, with_security([{"location", location}, {"cache-control", "no-store"}]) ++ extra, ""}
  end

  defp html(body, status, cache \\ "no-store") do
    headers =
      with_security([
        {"content-type", "text/html; charset=utf-8"},
        {"cache-control", cache},
        {"content-security-policy", @page_csp},
        {"x-frame-options", "DENY"}
      ])

    {status, headers, body}
  end

  defp page(title, message, base, status, sign_in \\ false),
    do: html(HTML.message_page(title, message, base, sign_in), status)

  # An app shell file. The worker may be scoped to the base (it is served
  # from there anyway); the SVGs get a CSP of their own.
  defp shell({type, body, cache, worker}, base) do
    headers = with_security([{"content-type", type}, {"cache-control", cache}])
    headers = if type == "image/svg+xml", do: headers ++ [{"content-security-policy", @asset_csp}], else: headers
    headers = if worker, do: headers ++ [{"service-worker-allowed", "#{base}/"}], else: headers
    {200, headers, body}
  end

  defp too_large(true, base), do: page("Not silenced", "The request was too large.", base, 413)
  defp too_large(false, _base), do: api(error_body("Request body too large"), 413)

  ## Reading a request

  defp header_text(req, name) do
    case Request.header(req, name) do
      nil -> nil
      v -> Text.latin1(v)
    end
  end

  # The first entry of a comma-separated header, trimmed, or nil when there
  # is none.
  defp first_value(req, name) do
    case header_text(req, name) do
      nil ->
        nil

      v ->
        first = v |> :binary.split(",") |> hd() |> JS.trim()
        if first != "", do: first
    end
  end

  # The named cookie, decoded, or nil; a malformed escape counts as no
  # cookie.
  defp read_cookie(req, name) do
    case header_text(req, "cookie") do
      nil ->
        nil

      v ->
        v
        |> String.split(";")
        |> Enum.find_value(:none, fn part ->
          case part |> JS.trim() |> String.split("=") do
            [^name | rest] -> {:found, Request.safe_decode(Enum.join(rest, "="))}
            _ -> nil
          end
        end)
        |> case do
          {:found, value} -> value
          :none -> nil
        end
    end
  end

  # A browser attaches Origin or Sec-Fetch-Site to a cross-site form post,
  # and a page cannot forge either. Non-browser clients send neither.
  defp cross_site?(req, public_origin) do
    origin = Request.header(req, "origin")
    site = Request.header(req, "sec-fetch-site")
    (origin != nil and origin != public_origin) or (site != nil and site not in ["same-origin", "none"])
  end

  # The Authorization header without its "Bearer " (in any case, with any
  # spaces after it), or nil when there is none.
  defp bearer(req) do
    case header_text(req, "authorization") do
      nil ->
        nil

      <<b::binary-size(6), rest::binary>> = text when rest != "" ->
        trimmed = JS.trim_start(rest)
        if ascii_downcase(b) == "bearer" and byte_size(trimmed) < byte_size(rest), do: trimmed, else: text

      text ->
        text
    end
  end

  defp ascii_downcase(s), do: for(<<c <- s>>, into: "", do: <<if(c in ?A..?Z, do: c + 32, else: c)>>)

  @doc """
  Absent means one hour; a number or numeric string is milliseconds. The
  error is the SDK's for anything else.
  """
  def silence_duration(nil), do: {:ok, "1h"}

  def silence_duration(value) do
    text = JS.trim(value)
    duration = if Regex.match?(~r/\A\d+(\.\d+)?\z/, text), do: Evaluate.js_number(text), else: text

    case Duration.parse(duration, "silence duration") do
      {:ok, _} -> {:ok, duration}
      {:error, message} -> {:error, message}
    end
  end

  @doc "`?runs=`: a whole number from 1 to 500, 20 when it is not a number."
  def runs_limit(nil), do: @default_runs

  def runs_limit(value) do
    n = if JS.trim(value) == "", do: :nan, else: Evaluate.js_number(value)

    if JS.finite?(n),
      do: n |> trunc() |> max(1) |> min(@max_runs),
      else: @default_runs
  end

  # Where the dashboard is mounted for this request: the configured base
  # path, else where a router mounted the plug, else /cronwatch.
  defp base_path(opts, req) do
    cond do
      opts.base_path != nil -> String.trim_trailing(opts.base_path, "/")
      req.mount != nil -> String.trim_trailing(req.mount, "/")
      true -> @default_base
    end
  end

  # The origin a browser sees: the configured one, the forwarded one under
  # trust_proxy, else the request's own.
  defp public_origin(%{origin: origin}, _req) when is_binary(origin), do: origin

  defp public_origin(opts, req) do
    own = Origin.request_origin(req.tls, Request.header(req, "host") || "")
    proto = first_value(req, "x-forwarded-proto")
    proto = proto && String.downcase(proto)
    host = first_value(req, "x-forwarded-host")

    cond do
      not opts.trust_proxy ->
        own

      proto == nil and host == nil ->
        own

      proto != nil and proto not in ["http", "https"] ->
        own

      true ->
        [own_scheme, own_host] = :binary.split(own, "://")
        Origin.bare("#{proto || own_scheme}://#{host || own_host}") || own
    end
  end

  ## Serving

  @doc """
  Answers one request as the SDK's routes answer it. A store failure (or a
  raise) is reported to the instance's error handler as `routes` and
  answered 500.
  """
  def handle(opts, %Request{} = req) do
    base = base_path(opts, req)
    pathname = req.path |> Request.target_path() |> Request.normalize_path()
    path = Request.strip_base(pathname, base)
    wants_html = not String.starts_with?(path, "/api")

    try do
      serve(opts, req, pathname, path, base, wants_html)
    rescue
      e -> failed(opts, e, base, wants_html)
    catch
      kind, reason -> failed(opts, {kind, reason}, base, wants_html)
    end
  end

  defp failed(opts, error, base, wants_html) do
    try do
      Config.report(Config.get(opts.instance), error, "routes")
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

    if wants_html,
      do: page("Something went wrong", "The request failed and the error was reported.", base, 500),
      else: api(error_body("Internal error"), 500)
  end

  defp serve(opts, req, pathname, path, base, wants_html) do
    method = String.upcase(req.method)
    public_origin = public_origin(opts, req)
    query = Request.parse_form(req.query)
    {kind, token} = token_state(opts)

    if kind == :generated and Runs.flag(opts.instance, {Cronwatch.Web, :announced, opts}) do
      shown = opts.origin || if(Origin.loopback?(public_origin), do: public_origin)
      announce(sign_in_line(shown, base, token))
    end

    get = method in ["GET", "HEAD"]
    asset = if get and path != "/offline", do: PWA.static_asset(path, base)

    cond do
      # The app shell: the manifest, icons, service worker, app.js and the
      # offline page. Served to anyone, since a browser fetches some of it
      # without cookies and none of it says anything about the jobs.
      get and path == "/offline" ->
        html(
          HTML.message_page(
            "You are offline",
            "CronWatch shows live data from your app, so it needs a connection.",
            base
          ),
          200,
          "no-cache"
        )

      asset != nil ->
        shell(asset, base)

      # No token outside development: fail closed.
      kind == :locked ->
        if wants_html,
          do:
            page(
              "CronWatch routes are locked",
              "Set CRONWATCH_TOKEN (or pass token: to Cronwatch.Web), or pass token: false to serve them open behind your own auth.",
              base,
              503
            ),
          else: api(error_body("CRONWATCH_TOKEN is not set"), 503)

      not get and cross_site?(req, public_origin) ->
        if wants_html,
          do: page("Cross-site request refused", "Changes can only be made from the dashboard itself.", base, 403),
          else: api(error_body("Cross-site request refused"), 403)

      true ->
        said = %{method: method, public_origin: public_origin, query: query, bearer: bearer(req)}
        at = %{pathname: pathname, path: path, base: base, wants_html: wants_html}
        signed_in(opts, req, said, {kind, token}, at)
    end
  end

  defp signed_in(opts, req, said, {kind, token}, at) do
    %{pathname: pathname, path: path, base: base, wants_html: wants_html} = at
    query_token = if token && wants_html && said.method == "GET", do: Request.param(said.query, "token")

    denied =
      if token do
        c = Config.get(opts.instance)
        secret = cron_secret(c)
        cookie = read_cookie(req, @token_cookie)

        cron_secret_ok =
          path == "/api/check" and said.bearer != nil and secret != nil and Text.constant_time_eq(said.bearer, secret)

        token_ok =
          cond do
            said.bearer != nil -> Text.constant_time_eq(said.bearer, token)
            query_token != nil -> Text.constant_time_eq(query_token, token)
            cookie != nil -> Text.constant_time_eq(cookie, cookie_value(token))
            true -> false
          end

        not cron_secret_ok and not token_ok
      else
        false
      end

    cond do
      denied and kind == :generated ->
        if wants_html,
          do:
            page(
              "Sign in",
              "CRONWATCH_TOKEN is not set, so this development server made a token. The sign-in link is in the server log: open it once and this browser stays signed in.",
              base,
              401,
              true
            ),
          else:
            api(
              error_body(
                "Unauthorized: CRONWATCH_TOKEN is not set, so this development server made a token; it is in the server log"
              ),
              401
            )

      denied ->
        if wants_html,
          do:
            page(
              "Sign in",
              "Open this page with ?token=<your CRONWATCH_TOKEN> once and it will stay signed in.",
              base,
              401,
              true
            ),
          else: api(error_body("Unauthorized"), 401)

      query_token != nil ->
        # Move the token from the URL into a cookie so it is not in history or logs.
        rest =
          for {n, v} <- said.query, n != "token", do: "#{Request.form_encode(n)}=#{Request.form_encode(v)}"

        search = if rest == [], do: "", else: "?" <> Enum.join(rest, "&")
        secure = if String.starts_with?(said.public_origin, "https:"), do: "; Secure", else: ""
        cookie_path = if base == "", do: "/", else: base

        redirect(pathname <> search, [
          {"set-cookie",
           "#{@token_cookie}=#{cookie_value(token)}; Path=#{cookie_path}; HttpOnly; SameSite=Lax; Max-Age=#{@cookie_max_age}#{secure}"}
        ])

      true ->
        route(opts, req, said, path, base, wants_html)
    end
  end

  defp redirect_back(req, said, base) do
    referer = Request.header(req, "referer") || ""
    if String.starts_with?(referer, said.public_origin <> "/"), do: redirect(referer), else: redirect("#{base}/")
  end

  defp decode_parts(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.reduce_while([], fn part, acc ->
      case Request.safe_decode(part) do
        nil -> {:halt, :bad}
        decoded -> {:cont, [decoded | acc]}
      end
    end)
    |> case do
      :bad -> :bad
      parts -> Enum.reverse(parts)
    end
  end

  defp route(opts, req, said, path, base, wants_html) do
    inst = [instance: opts.instance]

    case decode_parts(path) do
      :bad ->
        if wants_html,
          do: page("Bad request", "The path is not valid.", base, 400),
          else: api(error_body("Bad path"), 400)

      parts ->
        case {said.method, parts} do
          {"GET", []} when path == "/" ->
            entries = Cronwatch.jobs_with_runs!(@board_page_runs, inst)
            now = Config.now(Config.get(opts.instance))
            runs_by_job = Map.new(entries, fn {job, runs} -> {job.name, runs} end)
            jobs = Enum.map(entries, &elem(&1, 0))
            lanes = board_lanes(entries, now, inst)
            html(HTML.dashboard_page(jobs, runs_by_job, now, base, nil, lanes), 200)

          {"GET", ["jobs", name]} ->
            case Cronwatch.job_summary!(name, inst) do
              nil ->
                page("No such job", "#{name} is not in the store.", base, 404)

              job ->
                now = Config.now(Config.get(opts.instance))
                # Enough runs to draw the job's week; the page lists the newest fifty.
                limit = Timeline.week_runs_limit(job, now)
                runs = Cronwatch.runs!(job.name, limit, inst)
                html(HTML.job_page(job, runs, now, base, length(runs) < limit), 200)
            end

          {"POST", _} when path == "/check" ->
            Cronwatch.check!(inst)
            redirect_back(req, said, base)

          {"POST", ["jobs", name, "forget"]} ->
            Cronwatch.forget!(name, inst)
            redirect("#{base}/")

          {"POST", ["jobs", name, action]} when action in ["silence", "unsilence"] ->
            form_action(req, said, name, action, base, inst)

          {"POST", ["jobs", _, _]} ->
            page("Not found", path, base, 404)

          {method, ["api" | rest]} ->
            serve_api(req, method, rest, said, inst)

          _ ->
            page("Not found", path, base, 404)
        end
    end
  end

  defp form_action(req, said, name, action, base, inst) do
    cond do
      Cronwatch.job_summary!(name, inst) == nil ->
        page("No such job", "#{name} is not in the store.", base, 404)

      action == "unsilence" ->
        Cronwatch.unsilence!(name, inst)
        redirect_back(req, said, base)

      true ->
        case body_field(req, "for") do
          :too_large ->
            too_large(true, base)

          value ->
            case silence_duration(value) do
              {:ok, duration} ->
                Cronwatch.silence!(name, duration, inst)
                redirect_back(req, said, base)

              {:error, message} ->
                page("Not silenced", message, base, 400)
            end
        end
    end
  end

  # A field of the request's body, nil when it has none, or :too_large past
  # the cap. A body that could not be read to its end (the client went away,
  # a read deadline) is none, as the SDK's readBody has it, never the part
  # that arrived: `for=7d` cut short is `for=7`, a silence of 7 ms.
  defp body_field(req, name) do
    read =
      case req.body do
        nil -> {:ok, ""}
        fun when is_function(fun, 1) -> fun.(max_body())
        other -> other
      end

    case read do
      :too_large -> :too_large
      {:ok, data} when byte_size(data) > @max_body -> :too_large
      {:ok, data} -> Request.body_field(header_text(req, "content-type") || "", data, name)
      {:parsed, params} -> Request.parsed_field(params, name)
      {:error, _} -> nil
    end
  end

  # The board's timeline lanes, the first BOARD_LANES jobs. The runs already
  # read for the table usually cover the last day; only a job whose twenty
  # newest runs all fall inside it is read again, deeper.
  defp board_lanes(entries, now, inst) do
    from = now - Timeline.board_behind_ms()

    entries
    |> Enum.take(Timeline.board_lanes())
    |> Enum.map(fn {job, runs} ->
      short = length(runs) >= @board_page_runs and List.last(runs).started_at > from

      if short do
        deeper = Cronwatch.runs!(job.name, Timeline.board_runs(), inst)
        {job, deeper, length(deeper) < Timeline.board_runs()}
      else
        {job, runs, true}
      end
    end)
  end

  defp no_such_job, do: api(error_body("No such job"), 404)

  # A silence's or an unsilence's answer: the job's summary after it.
  defp summary_answer(name, inst) do
    job = Cronwatch.job_summary!(name, inst)
    api(ok_body([{"job", if(job, do: JobSummary.to_value(job))}]), 200)
  end

  defp serve_api(req, method, rest, said, inst) do
    case {method, rest} do
      # What is serving the API, so a client such as @cronwatch/mcp can tell.
      {"GET", []} ->
        api(
          ok_body([
            {"library", @library},
            {"language", @language},
            {"version", Cronwatch.version()},
            {"api", @api_version}
          ]),
          200
        )

      {"GET", ["jobs"]} ->
        jobs = Cronwatch.jobs!(inst)
        api(ok_body([{"jobs", Enum.map(jobs, &JobSummary.to_value/1)}]), 200)

      {"GET", ["jobs", name]} ->
        case Cronwatch.job_summary!(name, inst) do
          nil ->
            no_such_job()

          job ->
            runs = Cronwatch.runs!(name, runs_limit(Request.param(said.query, "runs")), inst)
            api(ok_body([{"job", JobSummary.to_value(job)}, {"runs", Enum.map(runs, &Run.to_value/1)}]), 200)
        end

      {"DELETE", ["jobs", name]} ->
        if Cronwatch.job_summary!(name, inst) == nil do
          no_such_job()
        else
          Cronwatch.forget!(name, inst)
          api(ok_body([]), 200)
        end

      {"POST", ["jobs", name, action]} ->
        cond do
          Cronwatch.job_summary!(name, inst) == nil ->
            no_such_job()

          action == "silence" ->
            case body_field(req, "for") do
              :too_large ->
                too_large(false, "")

              value ->
                case silence_duration(value || Request.param(said.query, "for")) do
                  {:ok, duration} ->
                    Cronwatch.silence!(name, duration, inst)
                    summary_answer(name, inst)

                  {:error, message} ->
                    api(error_body(message), 400)
                end
            end

          action == "unsilence" ->
            Cronwatch.unsilence!(name, inst)
            summary_answer(name, inst)

          true ->
            api(error_body("Not found"), 404)
        end

      {_, ["check"]} ->
        cond do
          # A page cannot send an Authorization header cross-site, so a GET
          # may only run the check when it carries a bearer (token or cron
          # secret).
          method == "GET" and said.bearer == nil ->
            api(error_body("Use POST, or GET with an Authorization bearer"), 405, [{"allow", "POST"}])

          method in ["GET", "POST"] ->
            result = Cronwatch.check!(inst)
            api(Object.merge(ok_body([]), CheckResult.to_value(result)), 200)

          true ->
            api(error_body("Not found"), 404)
        end

      {"GET", ["runs", id]} ->
        case Cronwatch.get_run!(id, inst) do
          nil -> api(error_body("No such run"), 404)
          run -> api(ok_body([{"run", Run.to_value(run)}]), 200)
        end

      _ ->
        api(error_body("Not found"), 404)
    end
  end
end
