#!/usr/bin/env bash
# Fails when a Go module's public API has an incompatible change since its
# last release. For the core module (cronwatch.dev/go) and each scheduler
# module (robfigcron, gocron, river, asynq), the baseline
# scripts/api-baseline.sh picks (the newest tag packages/go[/<name>]/vX.Y.Z,
# or the commit in scripts/api-baseline while that is newer) is taken from
# git into a scratch directory, apidiff (golang.org/x/exp/cmd/apidiff)
# writes the export data of each of its packages, and the same packages in
# the working tree are compared against it. Internal packages are left out;
# so is the bridge package (cronwatch.dev/go/bridge), which is for
# integration authors and outside the 1.x promise. A package new since the
# baseline has nothing to compare against; a package that is gone fails.
#
#   scripts/go-apidiff.sh            needs git tags, go and apidiff on PATH
#
# An incompatible change waits for a major release (site/docs/stability.md).
# The one written exception: river and asynq follow River and Asynq, both
# below 1.0, and a change their next release forces may land in a minor of
# that module, called out in CHANGELOG.md; scripts/api-baseline says how
# such a change is accepted.
set -euo pipefail

root="$(git rev-parse --show-toplevel)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
status=0

for name in "" robfigcron gocron river asynq; do
  dir="packages/go${name:+/$name}"
  module="cronwatch.dev/go${name:+/$name}"
  baseline="$("$root/scripts/api-baseline.sh" "$dir/v")"
  base="$scratch/${name:-core}"
  mkdir -p "$base"
  git -C "$root" archive "$baseline" packages/go | tar -x -C "$base"
  echo "$module: against $baseline"
  packages="$(cd "$base/$dir" && go list ./... | grep -v -e '/internal' -e '/examples' -e '^cronwatch.dev/go/bridge$' || true)"
  for pkg in $packages; do
    export_file="$scratch/$(echo "$pkg" | tr '/.' '__').export"
    (cd "$base/$dir" && apidiff -w "$export_file" "$pkg")
    if ! (cd "$root/$dir" && go list "$pkg" > /dev/null 2>&1); then
      echo "  $pkg: removed"
      status=1
      continue
    fi
    report="$(cd "$root/$dir" && apidiff -incompatible "$export_file" "$pkg")"
    if [ -n "$report" ]; then
      echo "  $pkg: incompatible changes"
      printf '    %s\n' "${report//$'\n'/$'\n'    }"
      status=1
    fi
  done
done

exit "$status"
