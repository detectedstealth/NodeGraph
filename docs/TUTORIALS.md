# Tutorials plan

DocC tutorials in the style of Apple's [Develop in Swift](https://developer.apple.com/tutorials/develop-in-swift/) series, teaching how to use the NodeGraph packages and how to write node packs. Started 2026-11-15.

## Decisions made with the owner

- **Hosting:** local preview first; GitHub Pages is the first public target; Swift Package Index later, if there is demand.
- **Scope:** Robotics and Video are covered, partly to prove they work end to end. Gaps found while writing a tutorial are fixed in the package (or logged here), not papered over in the tutorial.
- **Separate docs-only package** (`Packages/NodeGraphTutorials`): more packs will come, and tutorials will be extended to cover them. It can depend on any package; no package depends on it.

## How it fits together

| Piece | Where |
|---|---|
| Tutorial table of contents and tutorial pages | `Packages/NodeGraphTutorials/Sources/NodeGraphTutorials/NodeGraphTutorials.docc/` |
| Compiled step code | `Packages/NodeGraphTutorials/Sources/NodeGraphTutorials/` (`ChapterN/`) |
| Tests for every step | `Packages/NodeGraphTutorials/Tests/NodeGraphTutorialsTests/` |
| Per-package API reference and concept articles | `<Package>.docc/` inside each package that has one |
| Build and preview | `scripts/docs.sh` (`preview`, `build`, `site`); `build` runs in `scripts/ci.sh` |

Rules:

- Tutorial code is real code. Each step's file is compiled and covered by a test; a step that stops working fails CI. `@Code` needs one standalone file per step, so `scripts/sync-tutorial-code.sh` (to write in Phase 2) copies the compiled sources into `Resources/`, and CI checks that it produces no diff.
- DocC warnings are errors (`--warnings-as-errors`). Zero warnings is a quality gate.
- Package catalogs link only within their own package. Cross-package links live in the tutorials package, which depends on all of them.
- Screenshots (UI chapter) are committed as light and dark pairs. They are the only manual assets.
- A tutorial that needs something the packages lack gets that fixed first and the fix recorded in PLAN.md and DECISIONS.md.

## Curriculum

1. **Build a graph** (Core only): create a graph with `GraphEditor`; run it with `GraphRunner` and read `GraphValue`s; undo and redo and why every change is a `Command`; save and load with `GraphDocument` and `GraphStore`.
2. **Show it** (SwiftUI): embed the canvas editor; add the palette and inspector; run and show the console and diagnostics; groups and subgraphs.
3. **Write a node pack:** port types and connection rules; a `NodeDefinition`; the executor and its Swift Testing test; a `NodePack` and registering it; appearance and help text; shipping it as its own Swift package.
4. **Domain walkthroughs:** Robotics (a PID loop with `FixedStepScenario`); Video (a timeline with a crossfade, `frame(at:)`).
5. **Assistant and automation:** run headless with `ng-run`; the assistant digest and lints.

## Tasks

### Phase 1: Foundation

- [x] New package `NodeGraphTutorials` (Core and Nodes dependencies for now; add UI, Robotics, Video, Assistant when their chapters start), added to `NodeGraph.xcworkspace` and to the iOS step of `scripts/ci.sh`
- [x] `swift-docc-plugin` added to NodeGraphCore and NodeGraphTutorials (approved list)
- [x] Landing catalogs: `NodeGraphCore.docc` (overview and topic groups) and `NodeGraphTutorials.docc` (landing page)
- [x] `scripts/docs.sh` (`preview`, `build`, `site`) and a docs step in `scripts/ci.sh`
- [x] Fix the 26 DocC warnings in existing NodeGraphCore comments (missing parameter docs, symbol links that did not resolve), so `--warnings-as-errors` passes
- [ ] Add `.docc` catalogs and the plugin to the other packages as their tutorials need them (Nodes, UI, Assistant, Robotics, Video), adding each to `PACKAGES` in `docs.sh`
- [ ] Public API documentation gaps. Measured 2026-11-15 (public declarations with no `///` directly above; rough, counts only declarations that say `public`): Core 308 of 694, UI 283 of 643, Assistant 149 of 267, AI 92 of 155, Sync 36 of 60, Video 23 of 46, CLI 11 of 22, Nodes 9 of 21, Robotics 7 of 15. Approach: document just in time, covering what each chapter uses, and finish a package before its catalog is added to `docs.sh`. Re-measure when a package is done
- [ ] Verify the tutorials package builds for iOS (`scripts/ci.sh --ios`)

### Phase 2: Chapter 1, Build a graph (and the snippet harness)

- [ ] `@Tutorials` table of contents (`.tutorial` file) with the chapter list
- [ ] Step-code layout, per-step tests, and `scripts/sync-tutorial-code.sh` with a CI no-diff check
- [ ] Tutorial: create a graph
- [ ] Tutorial: run it
- [ ] Tutorial: undo and redo
- [ ] Tutorial: save and load

### Phase 3: Chapter 3, Write a node pack

- [ ] Tutorials: port type, node definition, executor and test, `NodePack`, appearance and help, shipping as a package
- [ ] A sample external pack package built by the tutorial (`Examples/` or a repo of its own), proving a pack can live outside this repo

### Phase 4: Chapter 2, Show it (SwiftUI)

- [ ] Tutorials: embed the editor, palette and inspector, console, groups and subgraphs
- [ ] Screenshot capture routine and committed light and dark assets

### Phase 5: Chapters 4 and 5

- [ ] Robotics walkthrough; list any gaps it finds
- [ ] Video walkthrough; list any gaps it finds
- [ ] Assistant and `ng-run` tutorials

### Phase 6: Publishing

- [ ] GitHub Pages: `scripts/docs.sh site` output, a workflow that publishes it, and a link from the README
- [ ] Revisit Swift Package Index (`.spi.yml`) if there is demand

## Findings

- 2026-11-15: the tutorials package depends on Core and Nodes only, to keep resolve time down; UI, Robotics and Video are added when their chapters start. The Xcode workspace asks to trust the package changes the first time a package is added.
