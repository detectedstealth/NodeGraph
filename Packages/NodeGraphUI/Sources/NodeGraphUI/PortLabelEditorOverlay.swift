import NodeGraphCore
import SwiftUI

/// The text field that appears beside a port while its label is being edited. Only one exists at
/// a time. Return commits, Escape abandons, and clicking elsewhere on the canvas commits.
struct PortLabelEditorOverlay: View {
    let controller: GraphInteractionController

    var body: some View {
        if let editor = controller.portLabelEditor,
           let port = controller.model.layout(of: editor.port.node)?.port(editor.port) {
            let model = controller.model
            let zoom = model.camera.zoom
            let center = model.camera.screenPoint(for: port.position)
            let fontSize = min(max(model.theme.portFontSize * model.textScale * zoom, 11), 18)
            let width = max(140, 90 * zoom)
            let height = fontSize + 12
            // Over the label's side of the port: right of an input, left of an output.
            let x = port.address.direction == .input ? center.x + 8 + width / 2 : center.x - 8 - width / 2
            PortLabelEntry(controller: controller, initial: editor.draftText, fontSize: fontSize)
                .frame(width: width, height: height)
                .position(x: x, y: center.y)
        }
    }
}

private struct PortLabelEntry: View {
    let controller: GraphInteractionController
    let initial: String
    let fontSize: CGFloat

    @State private var text = ""
    @State private var selection: TextSelection?
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("", text: $text, selection: $selection)
            .textFieldStyle(.plain)
            .onSubmit { controller.closePortLabelEditor(commit: true) }
            #if os(iOS)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            #endif
            .font(.system(size: fontSize))
            .foregroundStyle(Color(controller.model.theme.nodeTitle))
            .tint(Color(controller.model.theme.selection))
            .focused($isFocused)
            .padding(.horizontal, 5)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color(controller.model.theme.nodeBody)))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(controller.model.theme.selection), lineWidth: 1.5))
            .task {
                text = initial
                isFocused = true
                // The field resets its selection as it takes focus, so select once that settles.
                try? await Task.sleep(for: .milliseconds(100))
                selection = TextSelection(range: text.startIndex..<text.endIndex)
            }
            .onChange(of: text) { _, newValue in controller.updatePortLabelDraft(newValue) }
            .onKeyPress(.escape) {
                controller.closePortLabelEditor(commit: false)
                return .handled
            }
    }
}
