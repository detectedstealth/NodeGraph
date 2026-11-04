# Decisions

Record architectural decisions here. Newest last. Format: date, decision, why.

## 2026-11-04

1. **litegraph.js is a feature reference only.** No JSON or node-name compatibility, no ComfyUI compatibility. We use a clean native format. Why: the goal is a complete Swift node graph for many domains, not a port.
2. **Rendering starts with SwiftUI `Canvas`.** Metal only if benchmarks demand it. Why: far simpler, and works on macOS and iPadOS.
3. **Separate SwiftPM packages** (Core, Nodes, UI, Sync, and domain packs). Why: Core must be reusable by a server and by apps with different domains.
4. **`@Observable` and async/await, no Combine.** Why: fewer redraws, Swift 6 concurrency, project style rules.
5. **Command-based mutation, no whole-graph snapshots.** Why: undo, redo, and server change log share one mechanism.
6. **Open, registry-based port types; ports addressed by stable id, not array index.** Why: domain agnosticism and robust links when ports change.
7. **UUID-backed IDs.** Why: safe for offline creation and server merging.

## 2026-11-04 (Phase 1)

8. **Deployment targets are macOS 27 and iOS 27 (iPadOS 27), Swift 6.4 tools.** Why: new app with no legacy users; lets us use current APIs (Mutex, new SwiftUI, Document APIs) without availability checks. Revisit if we ever need to ship to older OS versions.
9. **`TypeRegistry` is a `Sendable` value type, mutated with `register` during setup**, so packs take it `inout` (`register(in: NodeRegistry, types: inout TypeRegistry)`). Why: provably `Sendable` with no locks (a locked class would also work now that `Synchronization.Mutex` is available, but a value type is simpler), and cheap to copy per document.
10. **`PortType.any` is the only type Core defines**; it is a structural wildcard, not domain knowledge. Compatibility is `identical` / `accepted` (type-level `acceptsFrom`) / `converted` (registered pair) / `incompatible`, all directional.
11. **`GraphValue` encodes as a tagged object (`{"type":"int","value":1}`); int and double never convert implicitly.** Why: the legacy `AnyCodable` turned `1` into `true`. Tags keep every case exact, including `Int64` beyond 2^53, `-0.0`, and non-finite doubles (written as `"nan"`, `"inf"`, `"-inf"` strings). Objects use an unordered `[String: GraphValue]`; deterministic files rely on `.sortedKeys` in the document encoder.
12. **`StringIdentifier` protocol** backs `PortID`, `PortType` and `PropertyID` (bare-string Codable, Comparable). Why: removes copy-pasted boilerplate.
13. **`Graph` mutators are internal; only `GraphEditor` (Core) mutates.** Why: enforces "every mutation is a command" at compile time for UI, Nodes and Sync, which are separate packages. Graph primitives don't check connection rules; `ConnectionValidator` does. Tests use `@testable`.
14. **`Graph` encodes nodes, links and groups as ordered arrays**, not dictionaries (`OrderedDictionary` would encode as a flat key/value array). Duplicate ids fail to decode.
15. **The group type is `NodeGroup`**, to avoid clashing with `SwiftUI.Group` in the UI package. Group membership is derived from bounds, not stored.
16. **Core has its own `GraphPoint`/`GraphSize`/`GraphRect`** so it never imports CoreGraphics (Linux).
17. **Link lookups scan all links for now.** Add adjacency indexes in `Graph` if the 10k-node benchmarks (Phase 2/4) need them; the query API (`links(from:)`, `links(into:)`, `links(attachedTo:)`) won't change.
18. **Validation is rule-based and pluggable per domain.** `ConnectionRule` (one proposed link) and `GraphRule` (whole graph) are protocols; `ConnectionValidator` and `GraphValidator` run ordered rule lists. Core ships structural rules (`ConnectionRules.standard`); a pack adds rules or drops ones that don't apply (a state-machine domain removes `noCycle`). Why: robotics and video editing allow different connections, and rules must be swappable without touching Core.
19. **Validation output is structured, not strings.** `GraphDiagnostic` has severity, an open `DiagnosticCode`, message, and node/port/link references; rules carry an `id` and one-sentence `summary`. Why: an editor, an importer, and an LLM generation loop all need to act on the same findings and describe the active rules. Warnings don't block a connection.
20. **Rules run together and must tolerate missing nodes and ports**; `EndpointsExist` reports those. Why: lets one pass report every problem, which is what a generator needs to self-correct in one round.
21. **Replacing a link is an outcome, not an error.** `ConnectionCheck.replacedLinks` lists links displaced by single-link ports; `GraphValidator` instead flags such a port as `connection.tooManyLinks` in an existing graph.

### Future: LLM-generated graphs (not yet scheduled)

Direction from the project owner: LLMs should generate graphs or the artifacts a graph needs, under domain-specific rules. Groundwork so far: Codable definitions, structured diagnostics, rule summaries. Expected follow-ups, to be scheduled when we reach Phase 5/6:
- A schema export (node types, ports, types, properties, active rule summaries) an LLM prompt can consume. Likely needs a `summary` text on `NodeDefinition`, `PortDefinition` and `PropertyDefinition`.
- A friendlier authoring format than the tagged `GraphValue` JSON and raw UUIDs: short local aliases for node ids, resolved to UUIDs on import.
- Generation as a command batch applied through `GraphEditor`, validated before commit, with diagnostics fed back for repair.
22. **`GraphEditor` is a non-`Sendable` final class**, owned by one actor (UI model on the main actor, runner on its own). Why: gestures and undo need synchronous apply; an actor would force `await` everywhere. Change streams (`changes()`) are `Sendable`-safe and independent per call, backed by a `Mutex`-protected broadcaster.
23. **Commands are labelled, `Codable` data with absolute values.** Positions are set absolutely (not by delta) so undo is exact in floating point. Add commands carry an optional `index`, so undoing a removal restores storage order and the file stays diff-stable. `removeNode` cascades to attached links. Batches apply atomically on a copy of the graph.
24. **Two validation levels (`EditValidation`).** `.full` (default) checks node types, property values and connection rules; `.structural` only checks that referenced nodes/links/groups exist, for undo, redo and server replay of already-validated changes. `addLink` refuses to silently displace a link; `connect(_:)` builds the remove-then-add batch.
25. **Coalescing is explicit.** `GraphCommand.coalesced(with:)` merges commands on the same target (same node set for positions, same node+field, same node+property, same group); `GraphChange.coalesced(with:)` keeps the earliest inverse. The undo manager decides when to call it.
26. **`Node.properties` encodes as a JSON object keyed by property id.** A `[PropertyID: ...]` dictionary otherwise encodes as a flat key/value array in unspecified order, which broke deterministic output.
