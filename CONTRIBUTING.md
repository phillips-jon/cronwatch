# Contributing to CronWatch

Thanks for helping. Bugs, ideas, and questions go in [the issue tracker](https://github.com/cronwatchdev/cronwatch/issues). This page is for working on CronWatch itself: running the tests for each language, releasing, and deploying the site. To use CronWatch, start with the [README](README.md) or [cronwatch.dev](https://cronwatch.dev/docs/).

Every port follows the TypeScript SDK. A behaviour change lands in TypeScript first, then `npm run conformance` regenerates the cases in `conformance/` that every port's tests replay, and each port is fixed until its tests pass.

## Development

Develop on Node 24 (`.nvmrc`); CI also runs Node 22, the oldest supported (better-sqlite3 13 needs it). Postgres tests run when `CRONWATCH_TEST_PG` points at a database.

```bash
npm ci
npm run check          # dash check, typecheck, tests
npm run build          # every package and the site
npm run dev:site       # the site on http://localhost:4321, rebuilding on change
npm run dev:dashboard  # a dashboard of dummy jobs
npm run check:packages # pack both packages and use them from a scratch project (after build)
npm run conformance    # regenerate conformance/ from the SDK, for the Ruby gem and the Python, PHP, Go, Rust, Elixir, Java and .NET packages
```

The gem (Ruby 3.2 or newer), after `npm run build` so its Node compatibility tests can run:

```bash
cd packages/ruby
bundle install
bundle exec rake test
```

[Its README](packages/ruby/README.md#testing) has the rest: Postgres, each Rails series, the dashboard fixture and the MCP cross test.

The Python package (Python 3.11 or newer), with [uv](https://docs.astral.sh/uv/), after `npm run build` so its Node compatibility and croner parity tests can run:

```bash
npm run check:python                                 # uv run pytest in packages/python
cd packages/python && uv run --python 3.11 pytest    # a particular Python
```

It replays `conformance/` too, and is fixed the same way when the fixtures change. It is not part of `npm run check`, which does not need uv; CI runs it on Python 3.11 and 3.14.

The PHP package (PHP 8.2 or newer), with [Composer](https://getcomposer.org), after `npm run build` for the same reason:

```bash
npm run check:php                              # composer install and phpunit in packages/php
```

It replays `conformance/` as well. Its MySQL and MariaDB tests run when `CRONWATCH_TEST_MYSQL` and `CRONWATCH_TEST_MARIADB` are `mysql://` URLs ([its README](packages/php/README.md#testing) shows two throwaway servers); CI runs it on PHP 8.2 and 8.5, against both.

The Go module (Go 1.25 or newer), after `npm run build` for the same reason:

```bash
cd packages/go && go test -race ./...             # the core: standard library only
cd packages/go/sqltest && go test -race ./...     # the SQL store, in a module of its own that holds the drivers
cd packages/go/robfigcron && go test -race ./...  # and gocron, river, asynq and examples, each a module of its own
```

It replays `conformance/` too. The SQL store's Postgres, MySQL and MariaDB tests run when `CRONWATCH_TEST_PG`, `CRONWATCH_TEST_MYSQL` and `CRONWATCH_TEST_MARIADB` are set, River's when `CRONWATCH_TEST_PG` is, and Asynq's end-to-end test when `CRONWATCH_TEST_REDIS` names a Redis (`redis://127.0.0.1:6379/0`); each skips without them ([its README](packages/go/README.md#testing) has the formats). The scheduler modules require their schedulers at the oldest release they support. CI runs every module on Go 1.25 and 1.26 with the race detector, against all three databases and a Redis, and the scheduler modules again at their schedulers' newest releases.

The Rust workspace (Rust 1.85 or newer, 1.94 for `cronwatch-sqlx`), after `npm run build` for the same reason:

```bash
cd packages/rust && cargo test --workspace --all-features
```

It replays `conformance/` and the dashboard fixture too. The Postgres, MySQL, MariaDB and pg_cron tests run when `CRONWATCH_TEST_PG`, `CRONWATCH_TEST_MYSQL`, `CRONWATCH_TEST_MARIADB` and `CRONWATCH_TEST_PGCRON` are set ([its README](packages/rust/README.md#testing) has the rest), and `CRONWATCH_TEST_RUST=1 npm test --workspace packages/mcp` drives the MCP server against its dashboard. CI runs the core and `cronwatch-tokio-cron-scheduler` on Rust 1.85, `cronwatch-sqlx` and `cronwatch-apalis` on 1.94, and the whole workspace on stable, on Linux, macOS and Windows.

The Elixir package (Elixir 1.18 or newer on Erlang/OTP 27 or newer), after `npm run build` for the same reason:

```bash
cd packages/elixir && mix deps.get && mix test
```

It replays `conformance/` and the dashboard fixture too. The Postgres, MySQL, MariaDB and pg_cron tests run when `CRONWATCH_TEST_PG`, `CRONWATCH_TEST_MYSQL`, `CRONWATCH_TEST_MARIADB` and `CRONWATCH_TEST_PGCRON` are set ([its README](packages/elixir/README.md#testing-this-package) has the rest), and `CRONWATCH_TEST_ELIXIR=1 npm test --workspace packages/mcp` drives the MCP server against its dashboard.

The Java build (Java 21 or newer, with the Maven wrapper it commits), after `npm run build` for the same reason:

```bash
cd packages/java && ./mvnw -B verify
```

It replays `conformance/` too, compiling with Error Prone and `-Xlint:all` with warnings as errors; `./mvnw spotless:apply` formats the code ([its README](packages/java/README.md#testing-this-package) has the rest). CI runs it on JDK 21, 25 and the newest JDK, on Linux, macOS and Windows, and `CRONWATCH_TEST_JAVA=1 npm test --workspace packages/mcp` drives the MCP server against its dashboard.

The .NET solution (.NET 10 or newer, the SDK pinned by `global.json`), after `npm run build` for the same reason:

```bash
cd packages/dotnet && dotnet test
CRONWATCH_CULTURE=tr-TR dotnet test    # the suite again under the tr-TR culture, as CI runs it
```

It replays `conformance/` and the dashboard fixture too, with warnings as errors; `dotnet format` formats the code ([its README](packages/dotnet/README.md#testing-this-package) has the rest). CI runs it on .NET 10, on Linux, macOS and Windows, and `CRONWATCH_TEST_DOTNET=1 npm test --workspace packages/mcp` drives the MCP server against its dashboard.

`npm run check:dashes` fails on an em or en dash in any tracked text file; CI also checks the commit messages.

Each package's public API is checked, so a change to it is seen and recorded in [CHANGELOG.md](CHANGELOG.md). TypeScript, Python and Elixir commit a report of theirs (`api.txt` in `packages/sdk`, `packages/mcp`, `packages/python` and `packages/elixir`), which a check compares with the code: `npm run check:api` for TypeScript (part of `npm run check`; `node scripts/api-report.mjs` rewrites the reports), and a test in each of the other two (`CRONWATCH_WRITE_API=1` rewrites theirs). .NET holds its surface in `PublicAPI.Unshipped.txt`. CI's `api` job compares the Go modules (`scripts/go-apidiff.sh`, with apidiff) and the Rust crates (`scripts/rust-semver.sh`, with cargo-semver-checks) against the last release, or against the commit in `scripts/api-baseline` while that is newer, and fails on an incompatible change; `scripts/api-baseline` says how a break is accepted on purpose.

## Releasing

Every package shares one version: the SDK, the MCP server, the gem, the Python and PHP packages (the WordPress plugin with them, and the Drupal module and the Craft plugin requiring the library at it), the Go module and its scheduler modules, the Rust crates, the Elixir package, the Java build, the .NET solution, and the skill. From a clean `main`:

```bash
npm run release -- X.Y.Z --dry-run   # show every change and command, write nothing
npm run release -- X.Y.Z             # bump, regenerate, check, commit "Release X.Y.Z", tag vX.Y.Z
```

It bumps every file listed in `VERSIONED` at the top of `scripts/release.mjs` (and turns the `## Unreleased` section of `CHANGELOG.md` into the release's, dated, refusing to run without one; and the WordPress readme's `= Unreleased =` changelog section and the Drupal and Craft `CHANGELOG.md` sections the same way, or adds a placeholder to rewrite), lists any other tracked file that still names the old version, refreshes `package-lock.json`, regenerates `conformance/` and the dashboard fixture, and runs `npm run check`, the build and `npm run check:packages`; then, when it finds what they need, the gem's tests and build, with a check of what the gem carries (Ruby 3.2 or newer; `--skip-ruby` skips them), the Python package's tests (uv; `--skip-python`) and the PHP package's (PHP 8.2 or newer and Composer; `--skip-php`). The Go, Rust, Elixir, Java and .NET tests are CI's. RubyGems spells a prerelease `X.Y.Z-beta.1` as `X.Y.Z.pre.beta.1` and refuses `+build` metadata, so the script does too.

It does not push or publish. It prints what to run next, in order:

- `git push origin main vX.Y.Z`. The tag starts the workflows that publish from it, and each first waits for CI's run on the tagged commit's push to `main` to pass (`ci-passed.yml`), publishing nothing if it fails, so push `main` with the tag: `pypi.yml` (PyPI, once `PYPI_ENABLED` is `true`), `php-split.yml` (the PHP package's own repository, which Packagist reads, once `PHP_SPLIT_ENABLED` is `true`), `php-plugins-split.yml` (the Drupal module's and the Craft plugin's repositories, once `DRUPAL_SPLIT_ENABLED` and `CRAFT_SPLIT_ENABLED` are; then make the drupal.org release from the tag), `crates.yml` (crates.io, once `CRATES_ENABLED` is `true`; the printed `cargo publish --workspace` line does it by hand), `hex.yml` (Hex and HexDocs, once `HEX_ENABLED` is `true`; the printed `mix hex.publish` line does it by hand), `nuget.yml` (nuget.org, once `NUGET_ENABLED` is `true`: it packs the five packages and pushes them when its reviewer approves; the printed `dotnet nuget push` line does it by hand), `java.yml` (Maven Central, once `MAVEN_ENABLED` is `true`, which it is not for the first release) and `wordpress-zip.yml`, which needs no switch: it builds the WordPress plugin's zip and attaches it to the tag's GitHub release, making the release with short notes if there is none yet (edit them after), as `cronwatch-X.Y.Z.zip` and as `cronwatch.zip`, the file `releases/latest/download/cronwatch.zip` serves and the docs link to.
- `npm publish` for the SDK and the MCP server, and `gem build` and `gem push` for the gem, once CI has passed on the release commit.
- `./mvnw -B -P release deploy` in `packages/java`, by hand for the first release and whenever `java.yml` is off, then a check of the validated deployment in the Central Publisher Portal before it is published.
- A tag and its push for the Go module (`packages/go/vX.Y.Z`) and for each scheduler module (`packages/go/robfigcron/vX.Y.Z` and the rest), then a `go list -m` that makes the Go proxy fetch them.
- `npm deprecate` lines for each `--deprecate <old>`.

A new package under `packages/` needs a row in both of the script's tables (`VERSIONED`, the file holding its version, and `PUBLISH`, how it ships), or the script refuses to run.

## Deploying the site

Once CI passes on a push to `main`, `.github/workflows/deploy.yml` runs the deploy script on the server, which builds a release on the server beside the live one and switches a symlink only when the build checks out. `deploy/README.md` has the server layout, the one-time setup and the rollback command.
