# NodeGraph

A general-purpose node graph system in Swift for macOS and iPadOS, intended for many domains (robotics scenarios, video editing, and more). litegraph.js is used as a feature reference only.

**Status:** Phases 0 to 3 are done. `NodeGraphCore` (models, validation, commands, undo, serialization, execution, subgraphs, libraries, dynamic ports) and `NodeGraphNodes` (45 math, logic, string, flow and utility nodes) are complete and tested. The SwiftUI editor (`NodeGraphUI`, Phase 4) and graph storage (`NodeGraphSync`, Phase 6) are next. See `docs/PLAN.md`.

## Layout

```
Packages/
  NodeGraphCore/    Pure Swift core: models, graph, execution, serialization (no UI)
  NodeGraphNodes/   Built-in node packs
  NodeGraphUI/      SwiftUI Canvas editor
  NodeGraphSync/    Graph storage and sync (server later)
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
