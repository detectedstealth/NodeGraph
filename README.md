# NodeGraph

A general-purpose node graph system in Swift for macOS and iPadOS, intended for many domains (robotics scenarios, video editing, and more). litegraph.js is used as a feature reference only.

**Status:** pre-1.0. The core, the built-in nodes, the SwiftUI editor, local graph storage, the robotics and video packs, a headless runner and the graph assistant all exist and are tested. The server is not started. See `docs/PLAN.md`.

## Layout

```
Package.swift       One SwiftPM package; every module below is a library product
Packages/
  NodeGraphCore/    Pure Swift core: models, graph, execution, serialization (no UI)
  NodeGraphNodes/   Built-in node packs (math, logic, string, flow, data, utility)
  NodeGraphUI/      SwiftUI Canvas editor
  NodeGraphSync/    Graph storage and sync (server later)
  NodeGraphRobotics/ Node pack for robotics scenario generation
  NodeGraphVideo/   Node pack for video editing
  NodeGraphAssistant/ Model-independent assistant logic (graph digest, lints, tools)
  NodeGraphAI/      Model providers (Claude, OpenAI-compatible, on-device) for the assistant
  NodeGraphCLI/     NodeGraphRunKit library and the ng-run headless runner
  NodeGraphTutorials/ DocC tutorials and their tested step code (no product)
examples/           Example graphs and TemperaturePack, a finished node pack
App/                The macOS and iPadOS app
docs/               PLAN.md, ARCHITECTURE.md, DECISIONS.md
scripts/ci.sh       Build and test everything (--ios adds simulator builds)
NodeGraph.xcworkspace
```

Use it from your own package by depending on the repository and naming the products you need:

```swift
.package(url: "https://github.com/<owner>/NodeGraph", from: "0.1.0"),
// in a target:
.product(name: "NodeGraphCore", package: "NodeGraph"),
```

Licensed under Apache-2.0 (see `LICENSE`).

## Learn

DocC tutorials teach the packages from an empty graph to your own node pack: building, running, saving and showing a graph, writing a node pack, the robotics and video packs, and headless runs. Preview them locally:

```bash
./scripts/docs.sh preview          # opens the tutorials
./scripts/docs.sh site             # static site for GitHub Pages in .docs-site/
```

Plan and status: `docs/TUTORIALS.md`. A finished example pack is in `examples/TemperaturePack`.

## Build and test

```bash
./scripts/ci.sh          # tests every package on macOS
./scripts/ci.sh --ios    # also builds each package for the iOS simulator
```

Open `NodeGraph.xcworkspace` in Xcode. Roadmap: `docs/PLAN.md`. Design: `docs/ARCHITECTURE.md`. Contributor and agent rules: `CLAUDE.md`.
