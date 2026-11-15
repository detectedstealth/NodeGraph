#!/usr/bin/env bash
# Redraws the tutorial pictures that the editor itself renders (light and dark). Run it after a
# change to how the editor draws, then commit the PNGs. See docs/TUTORIALS.md.
set -euo pipefail
cd "$(dirname "$0")/.."
NODEGRAPH_WRITE_TUTORIAL_IMAGES=1 swift test --package-path Packages/NodeGraphTutorials --filter captureTheTutorialImages
