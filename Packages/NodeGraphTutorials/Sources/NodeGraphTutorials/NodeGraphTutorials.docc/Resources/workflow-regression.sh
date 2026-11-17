#!/usr/bin/env bash
# Runs a document and compares the report with a saved one, so a change in behaviour shows up as a
# diff. Time is simulated, so the same document and options always give the same report.
# usage: regression.sh [--update] file.nodegraph golden.json [run options...]
set -euo pipefail
NG_RUN=${NG_RUN:-"swift run --quiet ng-run"}

update=false
if [[ "${1:-}" == "--update" ]]; then
    update=true
    shift
fi
file=$1 golden=$2
shift 2

report="$(mktemp)"
trap 'rm -f "$report"' EXIT
# A run with a failing node exits 1 but still writes its report, and that report is what is compared.
$NG_RUN run "$file" "$@" --output "$report" 2> /dev/null || true

if $update; then
    cp "$report" "$golden"
    echo "saved $golden"
elif diff -u "$golden" "$report"; then
    echo "same as $golden"
else
    echo "the report changed: $golden" >&2
    exit 1
fi
