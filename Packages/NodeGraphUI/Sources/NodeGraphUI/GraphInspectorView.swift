import NodeGraphCore
import SwiftUI

/// The inspector: shows and edits whatever is selected. A node's title, color, mode, position,
/// size and properties, and its ports; the settings several nodes share; a link's ends; a
/// group's title and color; or, with nothing selected, a summary of the graph and its problems.
/// Every edit is an undoable command through the model.
public struct GraphInspectorView: View {
    private let model: GraphEditorModel

    public init(model: GraphEditorModel) {
        self.model = model
    }

    public var body: some View {
        Form {
            switch model.inspection() {
            case .graph(let summary): GraphSection(model: model, summary: summary)
            case .node(let info): NodeSections(model: model, info: info)
            case .nodes(let info): NodesSection(model: model, info: info)
            case .link(let info): LinkSection(model: model, info: info)
            case .group(let info): GroupSection(model: model, info: info)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Graph

private struct GraphSection: View {
    let model: GraphEditorModel
    let summary: GraphSummary
    @State private var diagnostics: [GraphDiagnostic] = []

    var body: some View {
        Section("Graph") {
            LabeledContent("Nodes", value: "\(summary.nodeCount)")
            LabeledContent("Links", value: "\(summary.linkCount)")
            LabeledContent("Groups", value: "\(summary.groupCount)")
        }
        Section("Problems") {
            if diagnostics.isEmpty {
                Text("None").foregroundStyle(.secondary)
            } else {
                ForEach(Array(diagnostics.prefix(30).enumerated()), id: \.offset) { _, diagnostic in
                    Button {
                        if let node = diagnostic.node { model.select(node: node) }
                    } label: {
                        Label(diagnostic.message, systemImage: diagnostic.severity == .error ? "xmark.octagon" : "exclamationmark.triangle")
                            .foregroundStyle(diagnostic.severity == .error ? .red : .orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .task(id: model.revision) {
            diagnostics = GraphValidator(connections: model.editor.connectionValidator).validate(model.editor.validationContext)
        }
    }
}

// MARK: - Node

private struct NodeSections: View {
    let model: GraphEditorModel
    let info: NodeInspection

    var body: some View {
        Section(info.typeName) {
            LabeledContent("Title") {
                CommitTextField(text: info.title, placeholder: info.typeName) { model.setTitle($0, of: [info.id]) }
            }
            if !info.category.isEmpty { LabeledContent("Category", value: info.category) }
            if !info.isKnownType {
                Label("This node's type is not available. Its data is kept.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            Picker("Mode", selection: Binding(get: { info.mode }, set: { model.setMode($0, of: [info.id]) })) {
                ForEach(NodeMode.allCases, id: \.self) { Text($0.menuTitle).tag($0) }
            }
            Toggle("Pinned", isOn: Binding(get: { info.isPinned }, set: { model.setPinned($0, of: [info.id]) }))
            Toggle("Collapsed", isOn: Binding(get: { info.isCollapsed }, set: { model.setCollapsed($0, of: [info.id]) }))
            ColorRow(title: "Color", color: info.color, allowsClear: true) { model.setColor($0, of: [info.id]) }
        }

        Section("Layout") {
            LabeledContent("Position") {
                HStack {
                    NumberField(value: info.position.x) { model.setPosition(GraphPoint(x: $0, y: info.position.y), of: info.id) }
                    NumberField(value: info.position.y) { model.setPosition(GraphPoint(x: info.position.x, y: $0), of: info.id) }
                }
            }
            LabeledContent("Size") {
                HStack {
                    NumberField(value: info.size.width) { model.setSize(GraphSize(width: $0, height: info.size.height), of: info.id) }
                    NumberField(value: info.size.height) { model.setSize(GraphSize(width: info.size.width, height: $0), of: info.id) }
                }
            }
        }

        if !info.properties.isEmpty {
            Section("Properties") {
                ForEach(info.properties) { property in
                    PropertyRow(model: model, node: info.id, property: property)
                }
            }
        }
        if !info.inputs.isEmpty {
            Section("Inputs") { ForEach(info.inputs) { PortRow(port: $0) } }
        }
        if !info.outputs.isEmpty {
            Section("Outputs") { ForEach(info.outputs) { PortRow(port: $0) } }
        }
    }
}

private struct PortRow: View {
    let port: InspectedPort

    var body: some View {
        LabeledContent {
            Text(detail).foregroundStyle(.secondary)
        } label: {
            HStack(spacing: 6) {
                Circle().fill(Color(port.color)).frame(width: 9, height: 9)
                Text(port.definition.displayName)
            }
        }
    }

    private var detail: String {
        var parts = [port.typeName]
        if port.linkCount > 0 {
            parts.append(port.linkCount == 1 ? "1 link" : "\(port.linkCount) links")
        } else if port.definition.direction == .input, port.definition.kind == .data, let value = port.definition.defaultValue {
            parts.append("default \(WidgetKind.readOnly.display(value))")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Properties

private struct PropertyRow: View {
    let model: GraphEditorModel
    let node: NodeID
    let property: InspectedProperty

    private var title: String { property.definition.displayName }

    var body: some View {
        HStack {
            control
            if !property.isDefault {
                Button {
                    model.setProperty(nil, named: property.definition.id, of: node)
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .help("Reset to default")
                .accessibilityLabel("Reset \(title)")
            }
        }
    }

    private func set(_ value: GraphValue, coalescing: Bool = false) {
        model.setProperty(value, named: property.definition.id, of: node, coalescing: coalescing)
    }

    @ViewBuilder private var control: some View {
        let kind = property.spec.kind
        switch kind {
        case .toggle:
            Toggle(title, isOn: Binding(
                get: { if case .bool(let on) = property.value { on } else { false } },
                set: { set(.bool($0)) }))

        case .slider(let lo, let hi, let step, let isInteger):
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title)
                    Spacer()
                    Text(kind.display(property.value)).foregroundStyle(.secondary).monospacedDigit()
                }
                Slider(
                    value: Binding(
                        get: { property.value.numberValue ?? lo },
                        set: { set(isInteger ? .int(Int64($0.rounded())) : .double($0), coalescing: true) }),
                    in: lo...max(hi, lo + .leastNonzeroMagnitude), step: step ?? (isInteger ? 1 : 0.0001)
                ) { editing in
                    if !editing { model.endCoalescing() }
                }
            }

        case .number:
            LabeledContent(title) {
                CommitTextField(text: kind.display(property.value), placeholder: "") { text in
                    if let value = kind.value(fromText: text ?? "") { set(value) }
                    return true
                }
                .multilineTextAlignment(.trailing)
            }

        case .text:
            LabeledContent(title) {
                CommitTextField(text: property.value.stringValue ?? "", placeholder: "") { set(.string($0 ?? "")); return true }
            }

        case .multilineText:
            VStack(alignment: .leading) {
                Text(title)
                CommitTextEditor(text: property.value.stringValue ?? "") { set(.string($0)) }
                    .frame(height: 80)
            }

        case .combo(let choices):
            Picker(title, selection: Binding(
                get: { property.value.stringValue ?? "" }, set: { set(.string($0)) })
            ) {
                ForEach(choices, id: \.value) { Text($0.label).tag($0.value) }
            }

        case .color:
            ColorRow(
                title: title, color: { if case .color(let c) = property.value { c } else { nil } }(), allowsClear: false
            ) { color in
                guard let color else { return false }
                set(.color(color))
                return true
            }

        case .readOnly, .custom, .button:
            LabeledContent(title, value: kind.display(property.value))
        }
    }
}

// MARK: - Several nodes, links, groups

private struct NodesSection: View {
    let model: GraphEditorModel
    let info: NodesInspection

    var body: some View {
        Section("\(info.ids.count) Nodes") {
            Picker("Mode", selection: Binding<NodeMode?>(get: { info.mode }, set: { if let mode = $0 { model.setMode(mode, of: info.ids) } })) {
                if info.mode == nil { Text("Mixed").tag(NodeMode?.none) }
                ForEach(NodeMode.allCases, id: \.self) { Text($0.menuTitle).tag(Optional($0)) }
            }
            Toggle("Pinned", isOn: Binding(get: { info.isPinned ?? false }, set: { model.setPinned($0, of: info.ids) }))
                .toggleStyle(.switch)
            Toggle("Collapsed", isOn: Binding(get: { info.isCollapsed ?? false }, set: { model.setCollapsed($0, of: info.ids) }))
            ColorRow(title: info.hasMixedColors ? "Color (mixed)" : "Color", color: info.color, allowsClear: true) {
                model.setColor($0, of: info.ids)
            }
        }
    }
}

private struct LinkSection: View {
    let model: GraphEditorModel
    let info: LinkInspection

    var body: some View {
        Section("Link") {
            LabeledContent("From", value: info.source)
            LabeledContent("To", value: info.target)
            if !info.typeName.isEmpty { LabeledContent("Type", value: info.typeName) }
            LabeledContent("Reroute points", value: "\(info.waypointCount)")
            if info.waypointCount > 0 {
                Button("Remove Reroute Points") { model.clearWaypoints(of: info.id) }
            }
        }
    }
}

private struct GroupSection: View {
    let model: GraphEditorModel
    let info: GroupInspection

    var body: some View {
        Section("Group") {
            LabeledContent("Title") {
                CommitTextField(text: info.title, placeholder: "Group") { model.setGroupTitle($0 ?? "", of: info.id) }
            }
            ColorRow(title: "Color", color: info.color, allowsClear: true) { model.setGroupColor($0, of: info.id) }
            LabeledContent("Contains", value: info.memberCount == 1 ? "1 node" : "\(info.memberCount) nodes")
            LabeledContent("Size", value: "\(Int(info.bounds.size.width)) × \(Int(info.bounds.size.height))")
        }
    }
}

// MARK: - Controls

/// A text field that applies its text when Return is pressed or focus leaves it, not on every
/// keystroke, so typing one title is one undo step. The closure returns whether the edit was
/// accepted; a refused edit puts the old text back.
private struct CommitTextField: View {
    let text: String
    let placeholder: String
    let commit: (String?) -> Bool

    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(placeholder, text: $draft)
            .focused($isFocused)
            .onSubmit(apply)
            .onChange(of: isFocused) { _, focused in if !focused { apply() } }
            .onChange(of: text, initial: true) { _, new in if !isFocused { draft = new } }
    }

    private func apply() {
        guard draft != text else { return }
        if !commit(draft) { draft = text }
    }
}

/// A multi-line field with the same commit-on-leaving behavior.
private struct CommitTextEditor: View {
    let text: String
    let commit: (String) -> Void

    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextEditor(text: $draft)
            .focused($isFocused)
            .onChange(of: isFocused) { _, focused in if !focused, draft != text { commit(draft) } }
            .onChange(of: text, initial: true) { _, new in if !isFocused { draft = new } }
    }
}

/// A number field that applies a valid number and ignores anything else.
private struct NumberField: View {
    let value: Double
    let commit: (Double) -> Bool

    var body: some View {
        CommitTextField(text: WidgetKind.format(value), placeholder: "") { text in
            guard let number = Double(text ?? ""), number.isFinite else { return false }
            return commit(number)
        }
        .multilineTextAlignment(.trailing)
        .frame(minWidth: 56)
    }
}

/// Preset swatches, the system picker, and (optionally) a way to clear the color.
private struct ColorRow: View {
    let title: String
    let color: RGBAColor?
    let allowsClear: Bool
    let apply: (RGBAColor?) -> Bool

    @Environment(\.self) private var environment

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                ColorPicker(title, selection: Binding(
                    get: { color.map(Color.init) ?? .gray },
                    set: { _ = apply(RGBAColor($0, in: environment)) }), supportsOpacity: true)
                    .labelsHidden()
                if allowsClear, color != nil {
                    Button("Clear") { _ = apply(nil) }.buttonStyle(.borderless)
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 26), spacing: 6)], alignment: .leading, spacing: 6) {
                ForEach(Array(ColorPresets.all.enumerated()), id: \.offset) { _, preset in
                    Button {
                        _ = apply(preset)
                    } label: {
                        Circle().fill(Color(preset)).frame(width: 20, height: 20)
                            .overlay(Circle().stroke(color == preset ? Color.accentColor : Color.white.opacity(0.3), lineWidth: color == preset ? 2 : 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
