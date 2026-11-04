# Plan

Status legend: `[ ]` todo, `[x]` done. Work phases in order. Update this file as items complete.

Reference: litegraph.js is the feature benchmark. Compatibility is not a goal. See DECISIONS.md.

## Known defects in the legacy prototype (`Sources/NodeGraph/`)

Not to be fixed in place. Phases 0 and 1 replace the code. Kept here so the new design covers each.

1. AppKit-only colors (`nsColor`) in the renderer; `Package.swift` is macOS-only. Blocks iPadOS.
2. Core and UI in one executable target; not reusable.
3. `CanvasViewModel.slotPosition` ignores the header; the renderer includes it. Hit testing and drawing disagree.
4. Canvas gestures never start a link draft.
5. Link draft ignores slot direction and type, always uses `.any`.
6. `connect` allows multiple links per input, self-links, and cycles.
7. `lastNodeID`/`lastLinkID` counters unused with `UUID` IDs.
8. Slot UUIDs copied from declarations, so not unique per node; `Slot ==` compares UUIDs.
9. Subgraph instantiate creates an empty shell with no inner graph.
10. No execution engine; `executionOrder` only sorts (non-deterministically, O(n²)). Mode/state fields unused.
11. `GraphHistory` unused; whole-graph snapshots.
12. Gesture conflicts (drag vs tap vs pan); no scroll, keyboard, context menu or Pencil.
13. `MagnifyGesture` applied cumulatively, so zoom compounds.
14. Whole-canvas invalidation; no culling or spatial index.
15. Declaration and instance data mixed in `Node`; runtime `state` serialized.
16. `AnyCodable` can turn `1` into `true`.
17. README claims features that don't exist.

## Dependencies to adopt

| Package | Use |
|---|---|
| swift-collections | `OrderedDictionary` for deterministic graph storage, `Heap` for scheduling, `Deque` for queues |
| swift-algorithms | Chunking, windowing in layout code |
| swift-async-algorithms | Debounce/merge for change streams and execution events |
| swift-log | Logging in runner and sync |
| swift-argument-parser | Headless `ng-run` CLI (Phase 6) |
| swift-docc-plugin | Docs |
| swift-snapshot-testing, swift-custom-dump | Tests only: serialization and layout snapshots, readable diffs |

## Phase 0: Foundation and repo hygiene

- [x] `git init` (branch `main`, no commits yet), `.gitignore`
- [x] `CLAUDE.md`, `docs/PLAN.md`, `docs/ARCHITECTURE.md`, `docs/DECISIONS.md`
- [x] Create `Packages/NodeGraphCore`, `NodeGraphNodes`, `NodeGraphUI`, `NodeGraphSync` (macOS 27, iOS 27, Swift 6.4 tools) and `NodeGraph.xcworkspace`. Core depends on swift-collections and swift-log.
- [x] Xcode app target at `App/NodeGraphApp` (multiplatform, Swift 6, macOS 27 / iOS 27, links all four packages). Builds on macOS and iOS. Empty editor view still to come in Phase 4.
- [x] `scripts/ci.sh` tests every package; `--ios` builds each for the iOS simulator. Verified passing. App target not included until it exists.
- [x] Move the legacy prototype to `Legacy/` (own Package.swift). Delete after Phase 1.
- [x] Rewrite README to match reality

## Phase 1: Core model

- [x] IDs, `PortID`, `PortType`, `TypeRegistry` (compatibility and conversion rules). Value conversion functions attach once `GraphValue` exists.
- [x] `GraphValue` and `Property` schema types, with tests for exact numeric round-trip
- [ ] `NodeDefinition`, `NodeRegistry`, `Node`, `Link`, `Group`, `Graph` (ordered storage)
- [ ] `ConnectionValidator` (direction, type, cycles, self-link, single input, multi-output)
- [ ] `GraphCommand` set, `GraphEditor` (apply, invert, coalesce, batch), change stream
- [ ] Undo/redo manager on top of commands; integrates with SwiftUI `UndoManager`
- [ ] Groups: membership by containment, move with contents, resize
- [ ] `GraphDocument` native JSON v1: schema version, deterministic output, migration chain, unknown-node placeholders
- [ ] Tests for every rule above (Swift Testing); snapshot tests for the JSON format
- [ ] Delete legacy `Core` models once ported

## Phase 2: Execution engine

- [ ] `ExecutionPlan` compiler: topological order, cycle detection, feedback node support
- [ ] `NodeContext`, async `execute`, cancellation, error capture, timing, progress
- [ ] `GraphRunner` actor with modes: once, continuous, step, event-driven, deterministic
- [ ] Trigger (event) ports and flow, separate from data
- [ ] Node modes: always, never, muted, bypassed, onTrigger
- [ ] Dirty tracking and result cache
- [ ] `ExecutionEvent` stream for UI state
- [ ] Built-in packs in `NodeGraphNodes`: math, logic, string, flow, utility (reroute, note, constant)
- [ ] Tests: ordering, cycles, bypass/mute semantics, cancellation, deterministic runs, perf at 10k nodes

## Phase 3: Subgraphs and composition

- [ ] Subgraph definitions with exposed ports and promoted properties
- [ ] Instance nodes execute the inner graph with correct port mapping and scoping
- [ ] Convert selection to subgraph; unpack subgraph
- [ ] Reusable definition library (in document, then external via Sync)
- [ ] Reroute points on links
- [ ] Dynamic ports (variadic inputs/outputs) and connection-change hooks on `NodeDefinition`
- [ ] Tests: nested subgraphs, recursion guard, port changes preserving links

## Phase 4: Editor UI (SwiftUI Canvas)

- [ ] `GraphEditorModel` (`@Observable`), `GraphTheme`, `NodeLayout` (single source for geometry)
- [ ] Canvas rendering: grid, nodes, ports, links (spline, linear, straight), groups, comments, selection, viewport culling, level of detail
- [ ] Spatial index for hit testing
- [ ] Interaction state machine: pan, zoom (anchored, non-compounding), move, resize, marquee, connect, reconnect, shift-drag link move, snap to grid
- [ ] macOS input: scroll/trackpad, right-click menus, keyboard shortcuts, hover
- [ ] iPadOS input: touch, pinch, two-finger pan, long-press menus, Pencil, hardware keyboard, pointer
- [ ] In-node widgets: slider, number, combo, toggle, text, multiline, button, color; custom widget hook
- [ ] Add-node search (double-click/tap, link release), palette, inspector, breadcrumb for subgraphs
- [ ] Copy, paste, duplicate, delete, align, distribute, collapse, pin, color
- [ ] Mini-map; execution state overlays (running, error, progress)
- [ ] Custom node drawing hook for domain packs
- [ ] Accessibility: VoiceOver actions for node and link operations, Dynamic Type
- [ ] Benchmarks at 1k, 5k, 10k nodes; decide if Metal is needed (record in DECISIONS.md)
- [ ] XCUIAutomation tests for core editing flows on macOS and iPad

## Phase 5: litegraph feature audit

- [ ] Build checklist from litegraph.js docs and source (node features, canvas features, widgets, menus, dialogs, built-in node families)
- [ ] Mark each as implemented, deferred, or out of scope; record in `docs/FEATURE_AUDIT.md`
- [ ] Fill the gaps that are in scope

## Phase 6: Persistence and server readiness

- [ ] `GraphStore` protocol; in-memory and local file stores
- [ ] Document-based app integration (custom UTType, autosave, versions) using the SwiftUI Document APIs
- [ ] Revisioned save with conflict detection; command log export
- [ ] `ng-run` headless CLI (swift-argument-parser) for running graphs
- [ ] Server decision (Hummingbird vs Vapor) and API sketch; record in DECISIONS.md

## Phase 7: Domain proofs of concept

- [ ] `NodeGraphRobotics`: sensor, PID/filter, state machine, actuator nodes, deterministic fixed-step runner
- [ ] `NodeGraphVideo`: clip, trim, transition, effect, render nodes; time-based evaluation (frame at t); asset handles
- [ ] Fix any Core abstraction gaps they expose

## Quality gates (every phase)

- Swift 6 strict concurrency clean; zero warnings.
- Core tests pass on macOS and Linux; UI builds for macOS and iPad simulator.
- No UI imports in Core. No Combine.
- PLAN.md and DECISIONS.md updated before finishing.
