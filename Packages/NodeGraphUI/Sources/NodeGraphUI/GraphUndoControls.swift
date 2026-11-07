import SwiftUI

/// Undo and redo buttons, for people with no keyboard to press Command-Z on. They go through
/// the model, so they and the Edit menu, the iPad gestures and the keyboard all share one
/// history and always agree.
public struct GraphUndoControls: View {
    private let model: GraphEditorModel

    public init(model: GraphEditorModel) {
        self.model = model
    }

    public var body: some View {
        // Reading the revision makes the buttons update after every edit, undo and redo.
        let _ = model.revision
        HStack {
            Button("Undo", systemImage: "arrow.uturn.backward") { try? model.undo() }
                .disabled(!model.canUndo)
                .help(model.undoName.map { "Undo \($0)" } ?? "Undo")
            Button("Redo", systemImage: "arrow.uturn.forward") { try? model.redo() }
                .disabled(!model.canRedo)
                .help(model.redoName.map { "Redo \($0)" } ?? "Redo")
        }
    }
}
