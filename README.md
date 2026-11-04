# NodeGraph

A general-purpose node graph system in Swift for macOS and iPadOS, intended for many domains (robotics scenarios, video editing, and more). litegraph.js is used as a feature reference only.

**Status:** early rebuild. The new package structure exists but contains only scaffolding. The earlier prototype lives in `Legacy/` for reference and is being replaced.

## Layout

```
Packages/
  NodeGraphCore/    Pure Swift core: models, graph, execution, serialization (no UI)
  NodeGraphNodes/   Built-in node packs
  NodeGraphUI/      SwiftUI Canvas editor
  NodeGraphSync/    Graph storage and sync (server later)
Legacy/             Old prototype (macOS-only, known defects). Do not extend.
docs/               PLAN.md, ARCHITECTURE.md, DECISIONS.md
scripts/ci.sh       Build and test all packages (--ios adds simulator builds)
NodeGraph.xcworkspace
```

## Build and test

```bash
./scripts/ci.sh          # tests every package on macOS
./scripts/ci.sh --ios    # also builds each package for the iOS simulator
```

Open `NodeGraph.xcworkspace` in Xcode. Roadmap: `docs/PLAN.md`. Design: `docs/ARCHITECTURE.md`. Contributor and agent rules: `CLAUDE.md`.
