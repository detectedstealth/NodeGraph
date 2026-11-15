#!/usr/bin/env bash
# Writes the per-step code files the DocC tutorials show (see docs/TUTORIALS.md).
#
# Each compiled file in Packages/NodeGraphTutorials/Sources/NodeGraphTutorials/Chapter*/ holds the
# finished code of one tutorial. A line `//# step N` says that the lines after it first appear in
# step N; step K of the tutorial shows every line whose step is K or less, in file order. Marker
# lines are not shown. Output: <catalog>/Resources/<File>-step-<K>.swift.
#
#   scripts/sync-tutorial-code.sh          Write the files
#   scripts/sync-tutorial-code.sh --check  Fail if any file would change (used by CI)
set -euo pipefail
cd "$(dirname "$0")/.."

pkg=Packages/NodeGraphTutorials/Sources/NodeGraphTutorials
out="$pkg/NodeGraphTutorials.docc/Resources"
check=false
[[ "${1:-}" == "--check" ]] && check=true

target="$out"
if $check; then target="$(mktemp -d)"; fi
mkdir -p "$target"
if ! $check; then rm -f "$out"/*-step-*.swift; fi

for src in "$pkg"/Chapter*/*.swift; do
    name="$(basename "$src" .swift)"
    last=$(awk '/^\/\/# step [0-9]+$/ { if ($3 > m) m = $3 } END { print m + 0 }' "$src")
    for ((k = 1; k <= last; k++)); do
        awk -v k="$k" '
            /^\/\/# step [0-9]+$/ { step = $3; next }
            step <= k { print }
        ' "$src" > "$target/$name-step-$k.swift"
    done
done

if $check; then
    # Only generated files (*-step-*.swift) are compared; other Resources files are hand-made.
    stale=false
    for f in "$target"/*-step-*.swift; do
        cmp -s "$f" "$out/$(basename "$f")" || stale=true
    done
    for f in "$out"/*-step-*.swift; do
        [[ -e "$target/$(basename "$f")" ]] || stale=true
    done
    rm -rf "$target"
    if $stale; then
        echo "Tutorial step files are out of date. Run scripts/sync-tutorial-code.sh" >&2
        exit 1
    fi
fi
