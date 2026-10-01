#!/usr/bin/env bash
# Fails when a published Rust crate's public API has a change its version
# does not allow, by cargo-semver-checks, against the baseline
# scripts/api-baseline.sh picks (the newest tag vX.Y.Z, or the commit in
# scripts/api-baseline while that is newer). Between releases the version
# in Cargo.toml is the last release's, so cargo-semver-checks treats the
# change as a minor release: additions pass, anything breaking fails. A
# release's own major version bump lets its breaking changes through.
#
# Checked with every feature on: cronwatch, cronwatch-sqlx and
# cronwatch-tokio-cron-scheduler. Left out: cronwatch-apalis, which stays
# below 1.0 while apalis 1.0 is a release candidate, and the unpublished
# webserver and example. The bridge module is outside the 1.x promise but
# lives in the core crate, so a break there fails too and is accepted as
# scripts/api-baseline says. cronwatch-sqlx and
# cronwatch-tokio-cron-scheduler follow sqlx and tokio-cron-scheduler, both
# below 1.0; a change their next release forces may land in a minor, as
# site/docs/stability.md allows, accepted the same way.
#
#   scripts/rust-semver.sh        needs git tags and cargo-semver-checks
set -euo pipefail

root="$(git rev-parse --show-toplevel)"
baseline="$("$root/scripts/api-baseline.sh" v)"
echo "Rust crates: against $baseline"
cd "$root/packages/rust"
cargo semver-checks check-release \
  --package cronwatch --package cronwatch-sqlx --package cronwatch-tokio-cron-scheduler \
  --all-features --baseline-rev "$baseline"
