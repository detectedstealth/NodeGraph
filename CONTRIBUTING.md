# Contributing to NodeGraph

Thanks for taking an interest. NodeGraph is pre-1.0, so the API can still change, and an issue to discuss a bigger change before you write it saves everyone time.

## Pull requests

`main` is protected: every change goes through a pull request, and both CI jobs (Linux and macOS) must pass before it can merge. Fork the repository, make a branch, and open a PR against `main`. Keep a PR to one change; unrelated refactors are easier to review as their own PR.

The PR template lists what a reviewer looks for. In short:

- Tests for new or changed behavior, especially in Core. Tests use Swift Testing (`import Testing`, `@Test`, `#expect`).
- `///` doc comments on public API, so the DocC reference stays complete.
- A short entry in `docs/DECISIONS.md` for any architectural decision.

## Building and testing

You need Swift 6.3 or later. The editor needs macOS 26 or iOS 26.

```bash
swift build
swift test --filter NodeGraphCoreTests    # one module; omit --filter for everything
```

On Linux the Apple-only modules (`NodeGraphUI`, `NodeGraphAI`, `NodeGraphTutorials`) are left out of the package, so the same commands work there. A few tests measure time; on a slow or busy machine, run `NODEGRAPH_TIMING_SCALE=4 swift test --no-parallel`.

On macOS, open `App/NodeGraph.xcworkspace` in Xcode, or run `./scripts/ci.sh` to test everything and build the docs (`--ios` also builds each module for the iOS simulator). `./scripts/docs.sh preview` serves the tutorials locally.

## Rules of the codebase

These are the ones that most often come up in review. `CLAUDE.md` has the full list.

- **Layout:** each folder under `Packages/` is a set of targets in the root `Package.swift`. Dependencies point one way: `UI`, `Nodes` and `Sync` depend on Core; Core depends on no other module.
- **Core has no domain knowledge and no UI.** It must not import SwiftUI, AppKit or UIKit, and it must build on Linux. Node types, port types and value types are registered by packs, never hard-coded in Core.
- **Every graph change is a command.** Never change graph state directly from UI code. This keeps undo, redo and a future change log correct.
- **Swift 6 language mode, strict concurrency.** No Combine; use `async`/`await`, `AsyncStream` and `@Observable`.
- **Naming and style:** PascalCase types, camelCase members, 4-space indent, comments only where the code is not obvious.
- **Dependencies:** please ask before adding one. The approved list is in `CLAUDE.md`.

## Writing a node pack

A pack depends on `NodeGraphCore` alone. `examples/TemperaturePack` is a finished example, and the tutorials walk through it step by step.

## AI-assisted contributions

Much of this project is written with an AI assistant, and contributions made that way are welcome. Say so in the PR. You are responsible for what you submit: read it, run it, and make sure the tests pass.

## License

By contributing you agree that your contribution is licensed under the Apache License 2.0, the same as the project (see `LICENSE`).
