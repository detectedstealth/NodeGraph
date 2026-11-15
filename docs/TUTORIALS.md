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
| Pictures | `.../NodeGraphTutorials.docc/Resources/*.png` (generated), `*.svg` (hand-made) |
| Compiled step code | `Packages/NodeGraphTutorials/Sources/NodeGraphTutorials/` (`ChapterN/`) |
| Tests for every step | `Packages/NodeGraphTutorials/Tests/NodeGraphTutorialsTests/` |
| Per-package API reference and concept articles | `<Package>.docc/` inside each package that has one |
| Example packs the tutorials build | `examples/<Pack>/` (generated source and tests; the manifest is hand-written) |
| Build and preview | `scripts/docs.sh` (`preview`, `build`, `site`); `build` runs in `scripts/ci.sh` |

Rules:

- Tutorial code is real code. Each tutorial has one compiled file with its finished code in `Sources/NodeGraphTutorials/ChapterN/`, covered by tests in `Tests/`. A line `//# step N` marks where lines first appear; `scripts/sync-tutorial-code.sh` writes `Resources/<File>-step-<K>.swift` (every line of step K or earlier) for `@Code`, and `--check` in CI fails if the files are stale. Edit the compiled file, never the generated step files.
- Tutorial text names symbols in code voice (`GraphEditor`), not DocC symbol links: links across packages do not resolve (see Findings). Each package's own catalog links its own symbols.
- A chapter in the table of contents needs an image; use a simple SVG in `Resources/`.
- DocC warnings are errors (`--warnings-as-errors`). Zero warnings is a quality gate.
- Package catalogs link only within their own package. Cross-package links live in the tutorials package, which depends on all of them.
- Every step file is also type-checked alone by `scripts/check-tutorial-steps.sh` (in CI), so a reader following the steps never meets one that does not compile.
- Pictures of the editor come from its own PNG export, committed as light and `~dark` pairs; `scripts/capture-tutorial-images.sh` redraws them. The chapter images in the table of contents are hand-made SVGs.
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

- [x] `@Tutorials` table of contents (`NodeGraph.tutorial`) with the chapter list
- [x] Step-code layout, per-step tests, and `scripts/sync-tutorial-code.sh` with a CI no-diff check (8 tests)
- [x] Tutorial: create a graph
- [x] Tutorial: run it
- [x] Tutorial: undo and redo
- [x] Tutorial: save and load (adds a NodeGraphSync dependency to the tutorials package)

### Phase 3: Chapter 3, Write a node pack

- [x] Tutorials: define a port type, write the nodes (source, choice, stateful), make it usable (help, shapes, default producer), ship it as a package. A temperature pack: `temperature.sensor`, `.convert`, `.peak`; 6 tests in the tutorials package plus the pack's own 4
- [x] A sample external pack package built by the tutorial: `examples/TemperaturePack` depends on NodeGraphCore only, and its source and tests are generated from the tutorial files by `scripts/sync-tutorial-code.sh` (checked in CI), so the tutorial cannot drift from a package that builds and passes on its own. Its tests run in `scripts/ci.sh`

### Phase 4: Chapter 2, Show it (SwiftUI)

- [x] Tutorials: show a graph, add editing controls (inspector, undo, add node, mini-map), run it and watch (console, run badges), groups and subgraphs. 5 tests (no window needed: they drive `GraphEditorModel`)
- [x] Screenshot capture routine and committed light and dark assets: the pictures are drawn by the editor's own PNG export (`GraphEditorModel.pngData()`), so there are no manual screenshots and they cannot drift; `scripts/capture-tutorial-images.sh` rewrites them (light, and `~dark` for DocC's dark mode)

### Phase 5: Chapters 4 and 5

- [x] Robotics walkthrough (simulate a PID control loop, measure overshoot, reproducible in simulated time): no gaps in the pack. 3 tests
- [x] Video walkthrough (two sequences, a crossfade, any frame in any order): no gaps; frames are descriptions, not pixels, which the text says. 1 test
- [x] Assistant and `ng-run` tutorials (run headless from a shell and from code; digest, standard lints, and a pack lint for the temperature pack). 4 tests
- [x] Gaps found and fixed: `ng-run` registered only the built-in nodes, so a document with robotics or video nodes failed with `notExecutable` (found by running it on `examples/console.nodegraph`); it now registers `RoboticsPack` and `VideoPack` too (test added). `NodeGraphRunKit` was not a product, so nothing but the tool could use it; it is now a library product of NodeGraphCLI

### Phase 6: Publishing

- [ ] GitHub Pages: `scripts/docs.sh site` output, a workflow that publishes it, and a link from the README
- [ ] Revisit Swift Package Index (`.spi.yml`) if there is demand

## Findings

- 2026-11-15: the tutorials package depends on Core and Nodes only, to keep resolve time down; UI, Robotics and Video are added when their chapters start. The Xcode workspace asks to trust the package changes the first time a package is added.
- 2026-11-15: DocC symbol links do not resolve across packages. Tried `--enable-experimental-combined-documentation` (only combines targets of the root package) and `--dependency` with an archive built with `--enable-experimental-external-link-support` (docc 6.4.2 still says "No external resolver registered"). Tutorials use code voice instead. Revisit when docc's external linking matures; the hosted site can link each package's pages by URL.
- 2026-11-15: no Core or Nodes gaps found by Chapter 1; everything compiled and passed first time. One thing a reader hits: there is no way to set an input's value on a node without a `util.number` node linked in, which is by design.
- 2026-11-15: Chapter 3 found no Core gaps. Things a pack author should know, now in the tutorial text: a node with state must not be `isPure`; `registerConversion` only allows the connection (values are the same `GraphValue`, so a Celsius number just works); the editor's "add default node" is a canvas command (`CanvasCommand.addDefaultNode`), not a drag. A pack can depend on NodeGraphCore alone.
- 2026-11-15: a case-insensitive file system merged `Examples/` into the existing `examples/` folder, so example packs live in `examples/` (lower case) to stay correct on Linux.
- 2026-11-15: Chapter 2 found no UI gaps: the whole editor screen (canvas, inspector, undo controls, add node, mini-map, console, run) is about 60 lines of public API. Two things for the tutorial text: run badges come from the runner's events and values from its results, so a screen must feed both to the model; the console is meant to sit below the canvas (`safeAreaInset`), not over it. `GraphEditorModel.pngData()` renders in a test with no window, which made the images and the tests easy.
- 2026-11-15: a DocC `@Step` may hold one paragraph and an optional caption, and a chapter in the table of contents needs an image. Put longer explanation in the section's `@ContentAndMedia`.
- Still open for packs that are not linked into the app: the demo app does not link Robotics or Video, so their nodes cannot be tried in the editor (Phase 7 note in PLAN.md). Not done here.

