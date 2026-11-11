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
  NodeGraphAssistant/ Model-independent assistant logic (graph digest, lints, tools). Core only, no AI imports. See docs/ASSISTANT.md.
App/                  Xcode app target (macOS + iPadOS), thin shell.
docs/                 PLAN.md, ARCHITECTURE.md, DECISIONS.md
scripts/ci.sh         Tests all packages; `--ios` also builds for iOS simulator.
NodeGraph.xcworkspace Open this in Xcode.
```

The app project is `App/NodeGraphApp/NodeGraphApp.xcodeproj` (folder-reference based: new files in `App/NodeGraphApp/NodeGraphApp/` join the target automatically).

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

Prefer the Xcode MCP tools (`BuildProject`, `RunAllTests`, `RunSomeTests`, `XcodeRefreshCodeIssuesInFile`) over shell commands. From a shell, per package:

```bash
swift build --package-path Packages/NodeGraphCore
swift test  --package-path Packages/NodeGraphCore
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
- `Canvas` redraws everything on any observed change. Keep render state in a small `@Observable` object and cull to the viewport.
