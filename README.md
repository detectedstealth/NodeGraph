# NodeGraph

A general-purpose node graph system in Swift for macOS and iPadOS, intended for many domains (robotics scenarios, video editing, and more). litegraph.js is used as a feature reference only.

![The NodeGraph editor on macOS: a robotics temperature pipeline in three groups, the console, and the assistant panel](docs/images/editor-macos.png)

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
docs/               ARCHITECTURE.md, DECISIONS.md, PLAN.md, FEATURE_AUDIT.md, ASSISTANT.md, TUTORIALS.md
scripts/ci.sh       Build and test everything (--ios adds simulator builds)
NodeGraph.xcworkspace
```

Use it from your own package by depending on the repository and naming the products you need:

```swift
.package(url: "https://github.com/detectedstealth/NodeGraph", from: "0.1.0"),
// in a target:
.product(name: "NodeGraphCore", package: "NodeGraph"),
```

Copyright 2026 Bruce Wade. Licensed under Apache-2.0 (see `LICENSE`).

## Built with AI

This project is developed with an AI coding assistant (Claude Code, working inside Xcode) under a human owner who sets direction and reviews the results. The process is written down so you can judge it: `CLAUDE.md` holds the rules the assistant follows, `docs/DECISIONS.md` records every design decision with its reason, `docs/PLAN.md` tracks the work phase by phase, and every Core change comes with tests. The graph assistant inside the editor (`NodeGraphAssistant`, `NodeGraphAI`) follows the same approach: deterministic code does the analysis, the model only proposes, and you review before anything changes.

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
