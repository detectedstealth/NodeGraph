#!/usr/bin/env bash
# Runs a document once for each value of a variable and says which values make a node fail.
# Each run's report is kept as report-<variable>-<value>.json. Exits 1 if any value failed.
# usage: sweep.sh file.nodegraph variable value...
set -uo pipefail
NG_RUN=${NG_RUN:-"swift run --quiet ng-run"}
file=$1 variable=$2
shift 2

status=0
for value in "$@"; do
    report="report-$variable-$value.json"
    if $NG_RUN run "$file" --var "$variable=$value" --output "$report" 2> /dev/null; then
        echo "$variable=$value: ok"
    else
        echo "$variable=$value: failed"
        status=1
        # The report says which nodes failed and why.
        jq -r '[.ticks[].nodes[] | select(.status == "failure") | .error] | unique[] | "    " + .' "$report"
    fi
done
exit $status
