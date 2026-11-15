#!/usr/bin/env bash
# Builds and tests every package. Pass --ios to also build the UI package for an iOS simulator.
set -euo pipefail
cd "$(dirname "$0")/.."

for pkg in Packages/*/; do
    echo "==> swift test $pkg"
    swift test --package-path "$pkg"
done

echo "==> swift test examples/TemperaturePack"
swift test --package-path examples/TemperaturePack

echo "==> docs"
scripts/sync-tutorial-code.sh --check
scripts/check-tutorial-steps.sh
scripts/docs.sh build

if [[ "${1:-}" == "--ios" ]]; then
    for scheme in NodeGraphCore NodeGraphNodes NodeGraphUI NodeGraphSync NodeGraphRobotics NodeGraphVideo NodeGraphAssistant NodeGraphAI NodeGraphTutorials; do
        echo "==> xcodebuild iOS $scheme"
        (cd "Packages/$scheme" && xcodebuild -scheme "$scheme" \
            -destination 'generic/platform=iOS Simulator' build -quiet)
    done
fi
