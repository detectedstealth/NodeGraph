#!/usr/bin/env bash
# Checks each document: it must be valid and have no lint problems. Stops at the first failure.
# usage: check.sh [--strict] file.nodegraph...
set -euo pipefail
NG_RUN=${NG_RUN:-"swift run --quiet ng-run"}

strict=()
if [[ "${1:-}" == "--strict" ]]; then
    strict=(--strict)
    shift
fi

for file in "$@"; do
    echo "== $file"
    $NG_RUN validate "$file"
    $NG_RUN lint ${strict[@]+"${strict[@]}"} "$file"
done
