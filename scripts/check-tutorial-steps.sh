#!/usr/bin/env bash
# Type-checks every generated tutorial step file on its own, so a reader who follows the tutorial
# never meets a step that does not compile (see docs/TUTORIALS.md). Test step files and the
# manifest are skipped: they need the example package.
#
# Each step file is checked together with the finished files of the tutorials before it, which
# the tutorial text tells the reader to keep (`makeEditor()` and `makeAdditionGraph()`).
set -euo pipefail
cd "$(dirname "$0")/.."

pkg=Packages/NodeGraphTutorials
bin="$(swift build --show-bin-path)"
swift build > /dev/null
catalog="$pkg/Sources/NodeGraphTutorials/NodeGraphTutorials.docc/Resources"
fail=0
for step in "$catalog"/*-step-*.swift; do
    name="$(basename "$step")"
    [[ "$name" == *Tests-step-* ]] && continue
    context=("$pkg/Sources/NodeGraphTutorials/Chapter1/CreateAGraph.swift")
    # Chapter 1 files are standalone from each other except for CreateAGraph's helpers.
    [[ "$name" == CreateAGraph-* ]] && context=()
    # Using the pack: the reader has the finished pack package.
    [[ "$name" == UsingThePack-* ]] && context+=(examples/TemperaturePack/Sources/TemperaturePack/TemperaturePack.swift)
    if ! swiftc -typecheck -parse-as-library -swift-version 6 -I "$bin" ${context[@]+"${context[@]}"} "$step" 2> /tmp/step-check.err; then
        echo "does not compile: $name" >&2
        grep "error:" /tmp/step-check.err | head -3 >&2
        fail=1
    fi
done
exit $fail
