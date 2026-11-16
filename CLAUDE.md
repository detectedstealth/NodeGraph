# CLAUDE.md

Guidance for AI agents working in this repo. Read this first, then `docs/PLAN.md` (what to do next) and `docs/ARCHITECTURE.md` (how it fits together).

## Project goal

A general-purpose node graph system in Swift for macOS and iPadOS. It must be feature-complete in the way litegraph.js is (used only as a feature reference, **not** a compatibility target), and generic enough for very different domains: robotics scenario generation, movie/video editing, etc. A server (save/load/update graphs) will be added later.

Non-goals: litegraph.js or ComfyUI JSON compatibility, any web/JS runtime.

## Layout (target; see docs/PLAN.md for migration status)

```
Packages/
  NodeGraphCore/      Pure Swift. Models, graph, registry, execution, serialization, commands. No UI imports.
  NodeGraphNodes/     Built-in node packs (math, logic, string, flow). Depends on Core only.
  NodeGraphUI/        SwiftUI Canvas editor, gestures, inspector, palette. Depends on Core.
  NodeGraphSync/      GraphStore protocol + local implementations. Server comes later.
  NodeGraphTutorials/ Docs-only: DocC tutorials and their tested step code. See docs/TUTORIALS.md.
  NodeGraphAssistant/ Model-independent assistant logic (graph digest, lints, tools). Core only, no AI imports. See docs/ASSISTANT.md.
  NodeGraphRobotics/  Domain node pack: robotics scenario generation. Core and Nodes.
  NodeGraphVideo/     Domain node pack: video editing. Core and Nodes.
  NodeGraphAI/        Model providers (Claude, OpenAI-compatible, on-device), Keychain secrets, eval harness. Core and Assistant.
  NodeGraphCLI/       NodeGraphRunKit (headless run of a document) and the ng-run executable.
App/                  Xcode app target (macOS + iPadOS), thin shell.
docs/                 PLAN.md, ARCHITECTURE.md, DECISIONS.md
scripts/docs.sh       DocC: `preview`, `build` (warnings are errors), `site`.
scripts/ci.sh         Tests all packages, builds docs; `--ios` also builds for iOS simulator.
Package.swift         The one SwiftPM manifest for every module above (sources stay in Packages/<Name>/). Consumers depend on the repo by URL.
LICENSE               Apache-2.0.
NodeGraph.xcworkspace Open this in Xcode.
```

The app project is `App/NodeGraphApp/NodeGraphApp.xcodeproj` (folder-reference based: new files in `App/NodeGraphApp/NodeGraphApp/` join the target automatically).

There are no per-folder `Package.swift` files. Each folder under `Packages/` is a set of targets in the root manifest; add a module by adding its target (and product) there. `NodeGraphCLI` holds the `NodeGraphRunKit` library and the `ng-run` executable; `NodeGraphTutorials` is a target with no product.

Dependency direction is one way: `UI -> Core`, `Nodes -> Core`, `Sync -> Core`. Core never imports SwiftUI, AppKit or UIKit, and must build on Linux.

## Rules

- Swift 6 language mode, strict concurrency. Core types are `Sendable`, `Codable`, `Hashable` where possible.
- No Combine. Use `async/await`, `AsyncStream`, and `@Observable` (Observation framework) instead of `ObservableObject`/`@Published`.
- Do not use AppKit/UIKit types in shared code. Use `#if canImport(AppKit)` only inside `NodeGraphUI` for platform shims.
- Every graph mutation goes through a `Command` (see ARCHITECTURE.md). Never mutate graph state directly from UI code. This keeps undo, redo and the future server change log correct.
- Core has no domain knowledge. Slot types, node types and value types are registered by packs, never hard-coded in Core.
- Prefer an existing well-maintained package over hand-rolling (see "Approved dependencies").
- Keep changes scoped to the task. No unrelated refactors.
- Naming: PascalCase types, camelCase members. 4-space indent. Comment non-obvious logic only.
- Public API gets doc comments (`///`) so DocC works.

## Approved dependencies

Apple: `swift-collections` (OrderedDictionary, Deque, Heap, OrderedSet), `swift-algorithms`, `swift-async-algorithms`, `swift-log`, `swift-argument-parser` (headless runner CLI), `swift-docc-plugin`, Observation, Swift Testing.
Third party (tests only): `swift-snapshot-testing`, `swift-custom-dump`.
Later (server): Hummingbird or Vapor, decided in Phase 6. Ask before adding anything not listed here.

## Build and test

Prefer the Xcode MCP tools (`BuildProject`, `RunAllTests`, `RunSomeTests`, `XcodeRefreshCodeIssuesInFile`) over shell commands. From a shell, at the repo root:

```bash
swift build
swift test --filter NodeGraphCoreTests    # one module; omit --filter for everything
```

Tests use Swift Testing (`import Testing`, `@Test`, `#expect`). UI flows use XCUIAutomation. Every Core change needs a test. Run Core tests before declaring work done.

## Workflow for agents

1. Read `docs/PLAN.md`; pick the next unchecked item in the current phase. Don't skip phases.
2. Check `docs/DECISIONS.md` before changing anything architectural. Add an entry when you make a new decision.
3. Do the work, add tests, build, run tests.
4. Tick the item in `docs/PLAN.md` and note anything discovered. Keep this file current if conventions change.
5. Don't commit unless asked. The repo is initialized on `main` with no commits yet.

## Gotchas

- The legacy prototype has known bugs (see PLAN.md "Known defects"). Don't copy its slot addressing, UUID slot IDs, or `ObservableObject` patterns into new code.
- `GraphValue` is `ExpressibleByNilLiteral`, so in `cond ? nil : value` the `nil` becomes `.null`, not an absent optional. Write `Optional<GraphValue>.none` or give the result a `GraphValue?` type first (this cost a bug in `proposeEdit`).
- `Canvas` redraws everything on any observed change. Keep render state in a small `@Observable` object and cull to the viewport.
