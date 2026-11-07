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
- [x] Move the legacy prototype to `Legacy/` (own Package.swift). Deleted at the end of Phase 3.
- [x] Rewrite README to match reality

## Phase 1: Core model

- [x] IDs, `PortID`, `PortType`, `TypeRegistry` (compatibility and conversion rules). Value conversion functions attach once `GraphValue` exists.
- [x] `GraphValue` and `Property` schema types, with tests for exact numeric round-trip
- [x] `NodeDefinition`, `NodeRegistry`, `Node`, `Link`, `NodeGroup`, `Graph` (ordered storage). Comments deferred: a note node in Phase 2 covers them.
- [x] `ConnectionValidator` (direction, type, cycles, self-link, single input, multi-output), pluggable per domain, plus `GraphValidator` for whole graphs
- [x] `GraphCommand` set, `GraphEditor` (apply, invert, coalesce, batch), change stream
- [x] Undo/redo manager on top of commands (`GraphHistory`). The bridge to the platform `UndoManager` is in Phase 4 (UI).
- [x] Groups: membership by containment, move with contents, resize
- [x] `GraphDocument` native JSON v1: schema version, deterministic output, migration chain, unknown-node placeholders
- [x] Tests for every rule above (Swift Testing); golden-file test for the JSON format. Audit: 140 tests, 99% line coverage of Core.
- [x] Delete `Legacy/` (it was never tracked in git; Core replaced all of it; removed on the owner's say-so after Phase 3)

## Phase 2: Execution engine

- [x] `ExecutionPlan` compiler: topological order, cycle detection, feedback node support
- [x] `NodeContext`, async `execute`, cancellation, error capture, timing, progress (single-node level; the graph-level loop is `GraphRunner`)
- [x] `GraphRunner` actor with modes: once, continuous, step, event-driven, deterministic
- [x] Trigger (event) ports and flow, separate from data
- [x] Node modes: always, never, muted, bypassed, onTrigger
- [x] Dirty tracking and result cache
- [x] `ExecutionEvent` stream for UI state
- [x] Built-in packs in `NodeGraphNodes`: math, logic, string, flow, utility (reroute, note, constant). 45 node types. Port-type conversion at runtime is still open: see decision 61.
- [x] Tests: ordering, cycles, bypass/mute semantics, cancellation, deterministic runs, perf at 10k nodes (`ScaleTests`: build, edit, validate, compile, run, save and load a 10k-node graph, all under a second in a debug build)

## Phase 3: Subgraphs and composition

- [x] Subgraph definitions with exposed ports and promoted properties (model, document storage, editing commands; running instances is the next item)
- [x] Instance nodes execute the inner graph with correct port mapping and scoping
- [x] Convert selection to subgraph; unpack subgraph
- [x] Reusable definition library: `SubgraphLibrary` model, file form, import, update and status in Core. Storing a library externally (file, server) is a `GraphStore` job in Phase 6.
- [x] Reroute points on links (link waypoints; the `util.reroute` node remains for passing a value through)
- [x] Dynamic ports (variadic inputs/outputs) and connection-change hooks on `NodeDefinition` (declarative `keepOneFree` resizing; closure hooks are not built, see decision 91). 45 node types.
- [x] Tests: nested subgraphs (three levels, state per instance path), recursion guard (editor-time `recursiveSubgraph` plus run-time depth limit), port changes preserving links (rename, reorder, retype, add, remove, kind change, dynamic counts)

## Phase 4: Editor UI (SwiftUI Canvas)

- [x] `GraphEditorModel` (`@Observable`), `GraphTheme`, `NodeLayout` (single source for geometry), plus `GraphCamera` and `GraphSelection`. 33 tests in NodeGraphUI.
- [x] Canvas rendering: grid, nodes, ports, links (spline, linear, straight), groups, comments, selection, viewport culling, level of detail (`GraphCanvasView`; demo graph in the app shell; 75 UI tests). Comments are covered by the note node.

- [x] Spatial index for hit testing (`SpatialIndex`, `node(at:)`, `port(at:)`, `group(at:)`, `items(in:)`, `nodes(in:)`; 49 UI tests)
- [x] Bridge `GraphHistory` to the platform `UndoManager` (Core stays UI-free; 59 UI tests, Core 391)
- [x] Interaction state machine: pan, zoom (anchored, non-compounding), move, resize, marquee, connect, reconnect, shift-drag link move, snap to grid (`GraphInteractionController`; 106 UI tests). Gestures are wired for mouse drag and pinch; scroll, menus and keys are the next two items.

- [x] macOS input: scroll/trackpad, right-click menus, keyboard shortcuts, hover (`CanvasCommand` and key map, context menus, scroll and zoom, hover, `MacInputMonitor`; 134 UI tests). Tested through the controller; the AppKit event shim itself needs a hand check.

- [x] iPadOS input: touch, pinch, two-finger pan, long-press menus, Pencil, hardware keyboard, pointer (`TouchInputOverlay`, two-finger pan and pinch, kind-aware targets, `UIContextMenuInteraction`; 143 UI tests). The controller side is tested; the UIKit recognizers need a hand check on a device or simulator.

- [x] In-node widgets: slider, number, combo, toggle, text, multiline, button, color; custom widget hook (`NodeWidget`, `WidgetEditorOverlay`, `NodeWidgetProvider`; 175 UI tests). Slider, number, combo, toggle, text, multiline, button and color work; checked on the iPad simulator.

- [x] Add-node search and palette (double-click/tap, link release, Shift-A, menu, toolbar button): `NodeCatalog`, `AddNodeOverlay`; 196 UI tests, checked on the iPad simulator
- [x] Inspector (selected node: title, color, mode, pin, collapse, position, size, properties, ports; several nodes, a link, a group, or the graph with its problems): `Inspection`, `InspectorActions`, `GraphInspectorView`; 214 UI tests, checked on the iPad simulator
- [x] Breadcrumb for subgraphs (enter by double-click/tap, menu or Return, leave by breadcrumb, menu or Command-[, edit inside with undo): `GraphBreadcrumbView`, model scope, Core scoped connect and group move; 234 UI and 398 Core tests, checked on the iPad simulator
- [x] Copy, cut, paste, duplicate, align, distribute (delete, collapse, pin and color were already done: canvas commands, menus and the inspector): `GraphFragment` in Core, `GraphClipboard`, `Arrangement`, menus, keys, inspector Arrange section; 263 UI and 414 Core tests, checked on the iPad simulator
- [x] Subgraph authoring: Create Subgraph from the selection (name, choose properties to expose, open afterwards) and Unpack Subgraph, from the node menu, Command-G and Shift-Command-G, and the inspector; works inside a subgraph too (nested). `SubgraphAuthoring`, `CreateSubgraphOverlay`; 276 UI tests, checked on the iPad simulator
- [x] Subgraph interface editor, in the inspector: with nothing selected inside a subgraph, rename it, set its category, see how many nodes use it, and rename, reorder and remove its exposed inputs, outputs and properties; select a node inside and use the expose button on its ports and properties to add or remove them (`InterfaceEditing`, `SubgraphInspection`; 291 UI tests). Not done: editing an exposed property's default, and giving one exposed input several targets by hand.
- [x] Mini-map; execution state overlays (running, error, progress): `ExecutionOverlay` (badges, progress bar, error text, border tint; `GraphEditorModel.observeExecution`), `GraphMiniMapView` (click and drag to move the view, run state tints). The demo app has a Run button and the mini-map. 298 UI and 416 Core tests; not yet checked by eye
- [x] Custom node drawing hook for domain packs: `NodeContentDrawing` registered per node type with `GraphEditorModel.registerContentDrawing(for:_:)` reserves an area below the widgets (`NodeLayout.content`) and draws into it at full detail, clipped. 302 UI tests; not yet checked by eye
- [ ] Accessibility: VoiceOver actions for node and link operations, Dynamic Type
- [ ] Benchmarks at 1k, 5k, 10k nodes; decide if Metal is needed (record in DECISIONS.md)
- [ ] XCUIAutomation tests for core editing flows on macOS and iPad

## Phase 5: litegraph feature audit

- [ ] Build checklist from litegraph.js docs and source (node features, canvas features, widgets, menus, dialogs, built-in node families)
- [ ] Mark each as implemented, deferred, or out of scope; record in `docs/FEATURE_AUDIT.md`
- [ ] Fill the gaps that are in scope

## Phase 6: Persistence and server readiness

- [ ] `GraphStore` protocol; in-memory and local file stores
- [ ] Subgraph library in the editor: publish a subgraph to a library, import from one, see update and modified status, update an instance's definition (`SubgraphLibrary` is done in Core; this is the UI and the stores for it)
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
