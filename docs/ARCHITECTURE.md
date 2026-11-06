# Architecture

Target design. Items marked (later) are designed for but not built yet.

## Package graph

```
NodeGraphUI ──┐
NodeGraphNodes ├──> NodeGraphCore ──> swift-collections, swift-log
NodeGraphSync ─┘
App (macOS + iPadOS) ──> UI, Nodes, Sync
```

## Core concepts

| Concept | Description |
|---|---|
| `GraphDocument` | Serializable root: schema version, root `Graph`, subgraph definitions (omitted from the file when there are none), metadata. |
| `Graph` | Nodes, links, groups (`NodeGroup`). Value type, `Codable`, `Sendable`. |
| `NodeID`, `LinkID`, `GroupID` | Opaque `UUID`-backed IDs. Stable across save/load and safe for a distributed server. |
| `NodeDefinition` | Class-level description registered by a pack: type id (`"math.add"`), ports, properties schema, default size, category, execute function. |
| `Node` | Instance: id, definition id, position, size, mode, property values, per-instance port overrides. No runtime state. |
| `Port` | Addressed by a stable `PortID` (name unique within the node and direction), not by array index. |
| `PortType` | Open, string-backed struct (`"number"`, `"image"`, `"robot.pose"`). Packs register types with color, display name, and compatibility/conversion rules via `TypeRegistry`. |
| `GraphValue` | Runtime value enum: bool, int, double, string, vector, matrix, color, array, object, data, and `.handle(HandleID)` for large or opaque payloads (frames, point clouds). |
| `Link` | Output port to input port. An input accepts one link; an output accepts many. May carry `waypoints`, points the drawn link passes through (display only). |
| `Property` | Typed, schema-described node setting. Drives inspector and in-node widgets. |
| `SubgraphDefinition` | A `Graph` plus a `SubgraphInterface`: exposed inputs and outputs (each bound to inner ports by node id and port id) and promoted properties (each bound to inner node properties). Stored in `GraphDocument.subgraphs`. An instance is an ordinary `Node` whose type is `subgraph.<uuid>`; its `NodeDefinition` is generated from the interface. |

Distinct data flow and trigger flow: ports have a `kind` (`.data` or `.trigger`). Triggers carry events; data ports carry values.

## Registry

`NodeRegistry` maps type id to `NodeDefinition`. Packs conform to `NodePack` and expose `static func register(nodes: inout NodeRegistry, types: inout TypeRegistry)`. The registry is injected, never global, so tests and multiple documents stay isolated.

## Commands (single mutation path)

All edits are `GraphCommand` values (add/remove node, move, connect, disconnect, set property, group edit, batch). Each is invertible and `Codable`. `GraphEditor` applies commands to a `Graph`, produces the inverse for undo, and emits `GraphChange` events through an `AsyncStream`. Adjacent drags and slider changes coalesce.

Benefits: undo/redo with no snapshots, a ready-made change log for server sync and collaboration (later), and testable editing rules.

Connection rules live in one `ConnectionValidator`: rejects self-links and cycles, enforces direction and type compatibility, replaces an existing input link, and honors per-port multi-link flags.

## Execution

- `GraphRunner` is an actor. It evaluates a `Graph` against a `NodeRegistry` using a compiled `ExecutionPlan` (topological order, with SCC detection for cycles; cycles are an error unless a node is marked as a feedback/delay node).
- A node's executor (`NodeExecutor`, `async throws`) is registered beside its `NodeDefinition` in `NodeRegistry`, not stored in the definition, so definitions stay plain `Codable` data. It receives a `NodeContext` (inputs, properties, time, services, logger, progress, cancellation) and returns `NodeOutputs`.
- Modes: `once`, `continuous(interval)`, `step`, `eventDriven`, `deterministic(fixedDelta)` for robotics and tests.
- Caching: a node that declares `isPure` is skipped when its resolved inputs, fired triggers and properties are exactly what produced its cached outputs. Changes propagate downstream because a re-run node whose output changed changes its consumers' inputs; one whose output is unchanged stops the chain.
- Node modes: `always`, `never`, `muted`, `bypassed`, `onTrigger`.
- Runtime state (`running`, `error`, duration, progress) is published by the runner as `ExecutionEvent`s and is never serialized.
- A headless CLI (`ng-run`, using swift-argument-parser) runs a graph file for automation and server use (later).

## Serialization

Native JSON, `schemaVersion` integer at the root, with migrators registered per version (`Migration` chain). Deterministic key order for diff-friendly files. Unknown node types load as placeholders that preserve their data. Large `GraphValue` payloads are never embedded; they are external assets referenced by id.

## UI (NodeGraphUI)

- `GraphEditorModel` (`@Observable`, `@MainActor`) wraps `GraphEditor`, camera, selection, interaction state. Views never touch `Graph` directly.
- `GraphCanvasView` renders with SwiftUI `Canvas`: grid, links, nodes, groups, with viewport culling and a spatial index (grid or R-tree) for hit testing. Link and node drawing use a single `NodeLayout` source of truth so hit testing and drawing can't disagree.
- Input is an interaction state machine fed by a platform layer: scroll-wheel/trackpad/keyboard/right-click on macOS; touch, pinch, two-finger pan, long-press, Pencil, hardware keyboard and pointer on iPadOS.
- Node bodies can host SwiftUI views overlaid at high zoom for rich widgets (text fields, pickers). At low zoom they render as cheap Canvas shapes (level of detail).
- Custom node drawing is a protocol hook on `NodeDefinition` provided by packs for domain visuals (timeline thumbnails, scopes).
- Theme is a data type (`GraphTheme`), cross-platform; no AppKit/UIKit colors.
- Metal is deferred. Revisit only if benchmarks at 5k nodes miss frame budget (see PLAN.md Phase 4).

## Subgraph libraries

A `SubgraphLibrary` is a versioned file of reusable `SubgraphDefinition`s. Documents never refer to one at run time: importing **copies** a definition (and the definitions it contains instances of, dependencies first) into the document and records a `SubgraphOrigin` (library id, revision, content digest). The origin lets the editor report `libraryStatus` (up to date, update available, locally modified, or both) and build an `updateCommand`. Publishing goes the other way, through `SubgraphLibrary.publish`, which numbers revisions and refuses incomplete or recursive sets.

## Sync and server (later)

`GraphStore` protocol: `list`, `load`, `save(revision:)`, `delete`, `changes(since:)`. First implementations: in-memory and local file. A server implementation consumes the same `GraphCommand` log with revision numbers and conflict detection. Core types already satisfy the wire requirements (`Codable`, `Sendable`).

## Domain packs

Separate SwiftPM packages depending only on Core (e.g. `NodeGraphRobotics`, `NodeGraphVideo`). They register types, node definitions, and optional custom drawing. Two reference packs in Phase 7 validate generality.
