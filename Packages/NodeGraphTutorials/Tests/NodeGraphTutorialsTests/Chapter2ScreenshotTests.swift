import Foundation
import NodeGraphCore
import NodeGraphUI
import Testing
@testable import NodeGraphTutorials

// Pictures for the chapter 2 tutorials, drawn by the editor's own image export, so they cannot
// drift from what the editor draws. Normally this only checks that a picture can be made. To
// rewrite the committed files, run scripts/capture-tutorial-images.sh.

private let imageFolder = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Sources/NodeGraphTutorials/NodeGraphTutorials.docc/Resources")

private let writesImages = ProcessInfo.processInfo.environment["NODEGRAPH_WRITE_TUTORIAL_IMAGES"] == "1"

/// Draws `name` in the light theme, and in the dark theme as `name~dark`, which DocC picks in dark mode.
@MainActor
private func capture(_ name: String, _ prepare: (GraphEditorModel) async throws -> Void) async throws {
    for (suffix, theme) in [("", GraphTheme.light), ("~dark", GraphTheme.dark)] {
        let model = try makeAdditionModel(theme: theme)
        try await prepare(model)
        let data = try #require(picture(of: model))
        if writesImages {
            try data.write(to: imageFolder.appending(path: "\(name)\(suffix).png"))
        }
    }
}

@MainActor
@Test func captureTheTutorialImages() async throws {
    try await capture("show-graph") { _ in }
    try await capture("run-result") { model in await run(model, console: ConsoleModel()) }
    try await capture("grouped-numbers") { model in _ = groupTheNumbers(in: model) }
    try await capture("subgraph-instance") { model in _ = makeSubgraphOfTheAddition(in: model) }
}
