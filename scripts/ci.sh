#!/usr/bin/env bash
# Builds and tests the package and the example pack. Pass --ios to also build the UI package for an iOS simulator.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> swift test"
swift test

echo "==> swift test examples/TemperaturePack"
swift test --package-path examples/TemperaturePack

echo "==> docs"
scripts/sync-tutorial-code.sh --check
scripts/check-tutorial-steps.sh
scripts/docs.sh build

if [[ "${1:-}" == "--ios" ]]; then
    for scheme in NodeGraphCore NodeGraphNodes NodeGraphUI NodeGraphSync NodeGraphRobotics NodeGraphVideo NodeGraphAssistant NodeGraphAI NodeGraphRunKit; do
        echo "==> xcodebuild iOS $scheme"
        xcodebuild -scheme "$scheme" -destination 'generic/platform=iOS Simulator' build -quiet
    done
fi
