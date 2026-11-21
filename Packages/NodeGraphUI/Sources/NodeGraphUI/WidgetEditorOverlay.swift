#if !os(tvOS) && !os(watchOS)
import NodeGraphCore
import SwiftUI

/// The SwiftUI editor that appears over a widget while it is being edited: a text field for
/// text and numbers, a text editor for multiline text, a list for choices and swatches for
/// colors. Only one exists at a time, so thousands of nodes cost nothing; every other widget is
/// drawn in the canvas.
struct WidgetEditorOverlay: View {
    let controller: GraphInteractionController

    var body: some View {
        if let editor = controller.editor, let frame = controller.editorFrame {
            let camera = controller.model.camera
            let zoom = camera.zoom
            let origin = camera.screenPoint(for: frame.origin)
            let row = CGRect(x: origin.x, y: origin.y, width: frame.size.width * zoom, height: frame.size.height * zoom)
            // The control is the right part of the row, as drawn; a multiline editor takes the row.
            let split = row.minX + row.width * 0.42
            let control = editor.spec.kind == .multilineText
                ? row : CGRect(x: split, y: row.minY, width: row.maxX - split, height: row.height)
            let fontSize = min(max(controller.model.theme.portFontSize * controller.model.textScale * zoom, 11), 18)

            Group {
                switch editor.spec.kind {
                case .number, .text:
                    TextEntry(controller: controller, initial: editor.draftText, multiline: false, isNumber: isNumber(editor.spec.kind), fontSize: fontSize)
                        .frame(width: control.width, height: control.height)
                        .position(x: control.midX, y: control.midY)
                case .multilineText:
                    TextEntry(controller: controller, initial: editor.draftText, multiline: true, isNumber: false, fontSize: fontSize)
                        .frame(width: control.width, height: control.height)
                        .position(x: control.midX, y: control.midY)
                case .combo(let choices):
                    ChoiceList(controller: controller, choices: choices, fontSize: fontSize)
                        .frame(width: max(control.width, 120))
                        .position(x: control.minX + max(control.width, 120) / 2, y: control.maxY + 4 + CGFloat(min(choices.count, 8)) * (fontSize + 14) / 2)
                case .color:
                    ColorEditor(controller: controller, initial: currentColor(editor))
                        .position(x: control.minX + 110, y: control.maxY + 4 + 60)
                default:
                    EmptyView()
                }
            }
        }
    }

    private func isNumber(_ kind: WidgetKind) -> Bool {
        if case .number = kind { true } else { false }
    }

    private func currentColor(_ editor: GraphInteractionController.WidgetEditor) -> RGBAColor {
        guard let node = controller.model.graph.nodes[editor.node],
              let definition = controller.model.definition(of: node),
              let property = editor.spec.property,
              case .color(let color)? = node.value(of: property, in: definition) else {
            return RGBAColor(red: 1, green: 1, blue: 1)
        }
        return color
    }
}

/// A one-line or multi-line text field that reports what is typed. Return commits, Escape
/// abandons.
private struct TextEntry: View {
    let controller: GraphInteractionController
    let initial: String
    let multiline: Bool
    let isNumber: Bool
    let fontSize: CGFloat

    @State private var text = ""
    @State private var selection: TextSelection?
    @FocusState private var isFocused: Bool

    var body: some View {
        Group {
            if multiline {
                TextEditor(text: $text)
                    .scrollContentBackground(.hidden)
            } else {
                TextField("", text: $text, selection: $selection)
                    .textFieldStyle(.plain)
                    .onSubmit { controller.closeEditor(commit: true) }
                    #if os(iOS)
                    .keyboardType(isNumber ? .numbersAndPunctuation : .default)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    #endif
            }
        }
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
            // Select what is there, so typing replaces it. The field resets its selection as it
            // takes focus, so this waits for that to settle.
            try? await Task.sleep(for: .milliseconds(100))
            selection = TextSelection(range: text.startIndex..<text.endIndex)
        }
        .onChange(of: text) { _, newValue in controller.updateDraft(newValue) }
        .onKeyPress(.escape) {
            controller.closeEditor(commit: false)
            return .handled
        }
    }
}

/// The choices of a combo, as a list under the widget.
private struct ChoiceList: View {
    let controller: GraphInteractionController
    let choices: [PropertyChoice]
    let fontSize: CGFloat

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(choices, id: \.value) { choice in
                    Button {
                        controller.commitEditor(.string(choice.value))
                    } label: {
                        Text(choice.label)
                            .font(.system(size: fontSize))
                            .foregroundStyle(Color(controller.model.theme.nodeTitle))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .frame(height: fontSize + 14)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(height: CGFloat(min(choices.count, 8)) * (fontSize + 14))
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(controller.model.theme.nodeHeader)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(controller.model.theme.nodeBorder), lineWidth: 1))
    }
}

/// Preset swatches plus the system color picker.
private struct ColorEditor: View {
    let controller: GraphInteractionController
    let initial: RGBAColor

    @State private var color = Color.white
    @Environment(\.self) private var environment

    var body: some View {
        VStack(spacing: 10) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 8), count: 6), spacing: 8) {
                ForEach(Array(ColorPresets.all.enumerated()), id: \.offset) { _, preset in
                    Button {
                        controller.commitEditor(.color(preset))
                    } label: {
                        Circle().fill(Color(preset)).frame(width: 28, height: 28)
                            .overlay(Circle().stroke(Color.white.opacity(0.35), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            ColorPicker("Custom", selection: $color, supportsOpacity: true)
                .font(.callout)
                .foregroundStyle(Color(controller.model.theme.nodeTitle))
        }
        .padding(12)
        .frame(width: 244)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(controller.model.theme.nodeHeader)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(controller.model.theme.nodeBorder), lineWidth: 1))
        .onAppear { color = Color(initial) }
        .onChange(of: color) { _, newValue in
            controller.applyLive(.color(RGBAColor(newValue, in: environment)))
        }
    }
}

extension RGBAColor {
    /// A platform-neutral color from a SwiftUI one, in sRGB.
    init(_ color: Color, in environment: EnvironmentValues) {
        let resolved = color.resolve(in: environment)
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)
        let converted = srgb.flatMap { resolved.cgColor.converted(to: $0, intent: .defaultIntent, options: nil) }
        let parts = converted?.components ?? []
        if parts.count >= 3 {
            self.init(red: Double(parts[0]), green: Double(parts[1]), blue: Double(parts[2]), alpha: Double(parts.count > 3 ? parts[3] : 1))
        } else {
            self.init(red: Double(resolved.red), green: Double(resolved.green), blue: Double(resolved.blue), alpha: Double(resolved.opacity))
        }
    }
}

/// The swatches offered wherever a color is picked.
enum ColorPresets {
    static let all: [RGBAColor] = [
        RGBAColor(red: 0.90, green: 0.30, blue: 0.30), RGBAColor(red: 0.95, green: 0.60, blue: 0.20),
        RGBAColor(red: 0.95, green: 0.82, blue: 0.25), RGBAColor(red: 0.40, green: 0.78, blue: 0.40),
        RGBAColor(red: 0.30, green: 0.75, blue: 0.75), RGBAColor(red: 0.30, green: 0.55, blue: 0.95),
        RGBAColor(red: 0.60, green: 0.40, blue: 0.90), RGBAColor(red: 0.90, green: 0.45, blue: 0.75),
        RGBAColor(red: 1, green: 1, blue: 1), RGBAColor(red: 0.6, green: 0.6, blue: 0.6),
        RGBAColor(red: 0.3, green: 0.3, blue: 0.3), RGBAColor(red: 0, green: 0, blue: 0),
    ]
}
#endif
