#!/usr/bin/env bash
# Runs every command the command-line tutorials show and checks what they say happens: the output,
# and the exit status. Works on macOS and Linux; needs jq. See docs/TUTORIALS.md.
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"

command -v jq > /dev/null || { echo "check-cli-tutorial: jq is required" >&2; exit 2; }
swift build --product ng-run > /dev/null
export NG_RUN="$(swift build --show-bin-path)/ng-run"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

budget=examples/workflow/budget.nodegraph
failures=0
expect() { # expect <description> <expected status> <command...>
    local what=$1 want=$2
    shift 2
    local got=0
    "$@" > "$work/out.txt" 2>&1 || got=$?
    if [[ $got -ne $want ]]; then
        echo "FAIL: $what: exit $got, expected $want" >&2
        sed 's/^/    /' "$work/out.txt" >&2
        failures=$((failures + 1))
    fi
}
expect_text() { # expect_text <description> <text>: the last command's output contains it
    if ! grep -qF -- "$2" "$work/out.txt"; then
        echo "FAIL: $1: output lacks '$2'" >&2
        sed 's/^/    /' "$work/out.txt" >&2
        failures=$((failures + 1))
    fi
}

# Tutorial 1: check a graph.
expect "validate" 0 "$NG_RUN" validate $budget
expect_text "validate" "No findings."
expect "lint passes on a hint" 0 "$NG_RUN" lint $budget
expect_text "lint" "lint.unusedOutput"
expect "lint --strict fails on a hint" 1 "$NG_RUN" lint --strict $budget
expect "lint --json" 0 "$NG_RUN" lint --json $budget
jq -e '.findings[0].id == "lint.unusedOutput" and .findings[0].nodeType == "math.add"' "$work/out.txt" > /dev/null \
    || { echo "FAIL: lint --json shape" >&2; failures=$((failures + 1)); }
expect "digest" 0 "$NG_RUN" digest $budget --detail outline
expect_text "digest" "n3.result -> n5.a"
sed 's/math\.multiply/math.multipli/' $budget > "$work/broken.nodegraph"
expect "validate a broken document" 1 "$NG_RUN" validate "$work/broken.nodegraph"
expect_text "validate a broken document" "node.unknownType"
expect "an unreadable document" 2 "$NG_RUN" validate "$work/missing.nodegraph"
expect "check.sh" 0 examples/workflow/check.sh $budget
expect "check.sh --strict" 1 examples/workflow/check.sh --strict $budget

# Tutorial 2: run and sweep.
expect "run" 0 "$NG_RUN" run $budget --var hours=10 --output "$work/report.json"
[[ "$(jq '.ticks[0].nodes[] | select(.type == "math.add") | .outputs.result.value' "$work/report.json")" == 225 ]] \
    || { echo "FAIL: total for 10 hours is not 225" >&2; failures=$((failures + 1)); }
expect "run without a subcommand" 0 "$NG_RUN" $budget
expect "a failing node fails the run" 1 "$NG_RUN" run examples/console.nodegraph
expect "a whole number overrides a decimal variable" 0 "$NG_RUN" run examples/console.nodegraph --var margin=2
expect "an undeclared variable is refused" 1 "$NG_RUN" run $budget --var ghost=1
(cd "$work" && expect "sweep" 1 "$root/examples/workflow/sweep.sh" "$root/examples/console.nodegraph" margin 0 1 2)
expect_text "sweep" "margin=0: failed"
expect_text "sweep" "Division by zero"
expect_text "sweep" "margin=2: ok"

# Tutorial 3: keep results from changing.
golden=examples/workflow/golden/budget-10h.json
expect "regression" 0 examples/workflow/regression.sh $budget $golden --ticks 3 --var hours=10
expect "regression notices a change" 1 examples/workflow/regression.sh $budget $golden --ticks 3 --var hours=9

if [[ $failures -ne 0 ]]; then
    echo "$failures command-line tutorial check(s) failed" >&2
    exit 1
fi
echo "command-line tutorials: all commands behave as described"
