#!/usr/bin/env bash
# The five packages `dotnet pack` wrote into the directory given, checked
# before anything is published: there are exactly five, each named for the
# version in Directory.Build.props, each with its assembly, XML documentation,
# README, license and icon and nothing from the tests, the examples or
# webserver, and the core's .nuspec holds no dependency. ci.yml runs this on
# every push and nuget.yml on the packages it is about to push.
#
#   dotnet pack -c Release -o artifacts/packages
#   bash scripts/check-packages.sh artifacts/packages
set -euo pipefail

dir="${1:?usage: check-packages.sh <the directory dotnet pack wrote into>}"
root="$(cd "$(dirname "$0")/.." && pwd)"
version="$(sed -n 's/^ *<Version>\(.*\)<\/Version>$/\1/p' "$root/Directory.Build.props")"
if [ -z "$version" ]; then echo "no <Version> in Directory.Build.props"; exit 1; fi

for p in Cronwatch Cronwatch.Hosting Cronwatch.AspNetCore Cronwatch.Hangfire Cronwatch.Quartz; do
  nupkg="$dir/$p.$version.nupkg"
  if [ ! -f "$nupkg" ]; then echo "missing $nupkg"; exit 1; fi
  unzip -l "$nupkg"
  files="$(unzip -Z1 "$nupkg")"
  for f in "lib/net10.0/$p.dll" "lib/net10.0/$p.xml" README.md LICENSE icon.png "$p.nuspec"; do
    grep -qxF "$f" <<<"$files" || { echo "$p is missing $f"; exit 1; }
  done
  if grep -Eq '(^|/)(test|conformance|examples|webserver)/' <<<"$files"; then
    echo "$p carries test files"
    exit 1
  fi
  nuspec="$(unzip -p "$nupkg" "$p.nuspec")"
  grep -qF "<version>$version</version>" <<<"$nuspec" || { echo "$p's .nuspec is not version $version"; exit 1; }
  # The core depends on no other package.
  if [ "$p" = Cronwatch ]; then
    echo "$nuspec"
    if grep -q '<dependency ' <<<"$nuspec"; then echo "the core has a dependency"; exit 1; fi
  fi
done

# Nothing else is there to be pushed with them: no sixth package and no
# symbol package (the symbols are embedded in the assemblies).
count="$(find "$dir" -maxdepth 1 -type f \( -name '*.nupkg' -o -name '*.snupkg' \) | wc -l | tr -d ' ')"
if [ "$count" != 5 ]; then
  echo "expected the five packages, found $count:"
  ls "$dir"
  exit 1
fi
echo "the five packages of $version are as they should be"
