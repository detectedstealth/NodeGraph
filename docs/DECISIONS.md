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
