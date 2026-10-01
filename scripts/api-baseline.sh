#!/usr/bin/env bash
# Prints the git revision a package's public API is compared against: the
# newest release tag starting with the prefix given (v for the Rust crates,
# packages/go/v or packages/go/<name>/v for the Go modules), unless the
# commit in scripts/api-baseline is newer, that is, not already an ancestor
# of that tag. Needs the full history and the tags (fetch-depth: 0 in CI).
#
#   scripts/api-baseline.sh <tag prefix>
set -euo pipefail

prefix="$1"
root="$(git rev-parse --show-toplevel)"
pinned="$(grep -v '^#' "$root/scripts/api-baseline" | tr -d '[:space:]')"
tag="$(git -C "$root" tag --list "${prefix}*" --sort=-v:refname | grep -E "^${prefix}[0-9]+\.[0-9]+\.[0-9]+$" | head -n 1 || true)"
if [ -n "$tag" ] && git -C "$root" merge-base --is-ancestor "$pinned" "$tag"; then
  echo "$tag"
else
  echo "$pinned"
fi
