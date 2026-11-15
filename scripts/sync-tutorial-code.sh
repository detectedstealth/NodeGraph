#!/usr/bin/env bash
# Writes the generated files the DocC tutorials show and the example packages (see docs/TUTORIALS.md).
#
# Each compiled file in Packages/NodeGraphTutorials/Sources/NodeGraphTutorials/Chapter*/ and
# Tests/NodeGraphTutorialsTests/Chapter*/ holds the finished code of one tutorial. A line
# `//# step N` says that the lines after it first appear in step N; step K of the tutorial shows
# every line whose step is K or less, in file order. Marker lines are not shown, and the tutorial
# package's module name is shown as the example package's (`TemperaturePack`).
#
# Output:
#   <catalog>/Resources/<File>-step-<K>.swift            the step files DocC shows with @Code
#   <catalog>/Resources/TemperaturePack-manifest.swift   examples/TemperaturePack/Package.swift
#   examples/TemperaturePack/{Sources,Tests}/...         the finished pack and its tests
#
#   scripts/sync-tutorial-code.sh          Write the files
#   scripts/sync-tutorial-code.sh --check  Fail if any file would change (used by CI)
set -euo pipefail
cd "$(dirname "$0")/.."

pkg=Packages/NodeGraphTutorials
catalog="$pkg/Sources/NodeGraphTutorials/NodeGraphTutorials.docc/Resources"
example=examples/TemperaturePack
check=false
[[ "${1:-}" == "--check" ]] && check=true

# Generate into a scratch tree, then copy it into place or compare it with what is there.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/steps" "$work/example/Sources/TemperaturePack" "$work/example/Tests/TemperaturePackTests"

emit() { # emit <file> <step>: the file as it reads at that step
    awk -v k="$2" '
        /^\/\/# step [0-9]+$/ { step = $3; next }
        step <= k { print }
    ' "$1" | sed 's/@testable import NodeGraphTutorials/@testable import TemperaturePack/'
}

for src in "$pkg"/Sources/NodeGraphTutorials/Chapter*/*.swift "$pkg"/Tests/NodeGraphTutorialsTests/Chapter*/*.swift; do
    name="$(basename "$src" .swift)"
    last=$(awk '/^\/\/# step [0-9]+$/ { if ($3 > m) m = $3 } END { print m + 0 }' "$src")
    for ((k = 1; k <= last; k++)); do
        emit "$src" "$k" > "$work/steps/$name-step-$k.swift"
    done
    case "$name" in
    TemperaturePack) cp "$work/steps/$name-step-$last.swift" "$work/example/Sources/TemperaturePack/TemperaturePack.swift" ;;
    TemperaturePackTests) cp "$work/steps/$name-step-$last.swift" "$work/example/Tests/TemperaturePackTests/TemperaturePackTests.swift" ;;
    esac
done
cp "$example/Package.swift" "$work/steps/TemperaturePack-manifest.swift"

if $check; then
    stale=false
    for f in "$work"/steps/*.swift; do
        cmp -s "$f" "$catalog/$(basename "$f")" || stale=true
    done
    for f in "$catalog"/*-step-*.swift; do
        [[ -e "$work/steps/$(basename "$f")" ]] || stale=true
    done
    cmp -s "$work/example/Sources/TemperaturePack/TemperaturePack.swift" "$example/Sources/TemperaturePack/TemperaturePack.swift" || stale=true
    cmp -s "$work/example/Tests/TemperaturePackTests/TemperaturePackTests.swift" "$example/Tests/TemperaturePackTests/TemperaturePackTests.swift" || stale=true
    if $stale; then
        echo "Generated tutorial files are out of date. Run scripts/sync-tutorial-code.sh" >&2
        exit 1
    fi
else
    rm -f "$catalog"/*-step-*.swift "$catalog"/TemperaturePack-manifest.swift
    cp "$work"/steps/*.swift "$catalog/"
    mkdir -p "$example/Sources/TemperaturePack" "$example/Tests/TemperaturePackTests"
    cp "$work/example/Sources/TemperaturePack/TemperaturePack.swift" "$example/Sources/TemperaturePack/"
    cp "$work/example/Tests/TemperaturePackTests/TemperaturePackTests.swift" "$example/Tests/TemperaturePackTests/"
fi
