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
            case .subgraph(let info): SubgraphSections(model: model, info: info)
            case .node(let info): NodeSections(model: model, info: info)
            case .nodes(let info): NodesSection(model: model, info: info)
            case .link(let info): LinkSection(model: model, info: info)
            case .group(let info): GroupSection(model: model, info: info)
            }
        }
        .formStyle(.grouped)
        // A viewer shows the same facts but offers no edits. Navigation buttons in here go with it;
        // the breadcrumb, double click and Return still open and leave subgraphs.
        .disabled(!model.isEditable)
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
        VariablesSection(model: model)
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
            diagnostics = GraphValidator(connections: model.editor.connectionValidator).validate(model.editor.validationContext(in: model.currentScope) ?? model.editor.validationContext)
        }
    }
}

// MARK: - Variables

/// The graph's variables: values nodes read by name (a Variable node). Edits the declared value;
/// a run can still override it.
private struct VariablesSection: View {
    let model: GraphEditorModel

    var body: some View {
        Section("Variables") {
            let variables = Array(model.graph.variables.values)
            if variables.isEmpty {
                Text("None. Add one, then use its add-node button to read it.").foregroundStyle(.secondary)
            }
            ForEach(variables, id: \.name) { variable in
                HStack {
                    CommitTextField(text: variable.name, placeholder: "Name") { text in
                        // A refused name (blank or taken) puts the old one back.
                        guard let text, text != variable.name else { return true }
                        return model.renameVariable(variable.name, to: text)
                    }
                    Spacer(minLength: 8)
                    VariableValueField(model: model, variable: variable)
                    if model.variableReaderType != nil {
                        IconButton(systemName: "plus.square") { model.addVariableReader(for: variable.name) }
                            .accessibilityLabel("Add a node that reads \(variable.name)")
                    }
                    IconButton(systemName: "trash") { model.removeVariable(variable.name) }
                }
            }
            Menu("Add Variable") {
                ForEach(VariableKind.allCases, id: \.self) { kind in
                    Button(kind.title) { model.addVariable(kind: kind) }
                }
            }
        }
    }
}

/// The control for a variable's value, chosen by its kind. Kinds with no control here (arrays,
/// objects and so on) show a summary.
private struct VariableValueField: View {
    let model: GraphEditorModel
    let variable: GraphVariable

    var body: some View {
        switch variable.value {
        case .double(let number):
            NumberField(value: number) { model.setVariable(variable.name, to: .double($0)) }
        case .int(let number):
            NumberField(value: Double(number)) { text in
                guard let whole = Int64(exactly: text) else { return false }
                return model.setVariable(variable.name, to: .int(whole))
            }
        case .string(let text):
            CommitTextField(text: text, placeholder: "") { model.setVariable(variable.name, to: .string($0 ?? "")) }
                .multilineTextAlignment(.trailing)
        case .bool(let on):
            Toggle("", isOn: Binding(get: { on }, set: { model.setVariable(variable.name, to: .bool($0)) }))
                .labelsHidden()
        default:
            Text(variable.value.summary(limit: 30)).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Node

private struct NodeSections: View {
    let model: GraphEditorModel
    let info: NodeInspection

    var body: some View {
        Section(info.typeName) {
            if !info.help.isEmpty { Text(info.help).font(.callout).foregroundStyle(.secondary) }
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
            // "Default" clears the node's own choice, so it follows its type again.
            Picker("Shape", selection: Binding(get: { info.shape }, set: { model.setShape($0, of: [info.id]) })) {
                Text("Default").tag(NodeShape?.none)
                ForEach(NodeShape.allCases, id: \.self) { Text($0.menuTitle).tag(Optional($0)) }
            }
            Picker("Title Bar", selection: Binding(get: { info.titleMode }, set: { model.setTitleMode($0, of: [info.id]) })) {
                Text("Default").tag(NodeTitleMode?.none)
                ForEach(NodeTitleMode.allCases, id: \.self) { Text($0.menuTitle).tag(Optional($0)) }
            }
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

        Section("Subgraph") {
            if let subgraph = model.subgraph(of: info.id) {
                ActionButton("Open \(model.scopeName(subgraph))") { model.enterSubgraph(of: info.id) }
                ActionButton("Unpack Subgraph") { model.unpackSubgraph(instance: info.id) }
            }
            ActionButton("Create Subgraph…") { model.beginCreateSubgraph() }
        }

        if !info.properties.isEmpty {
            Section("Properties") {
                ForEach(info.properties) { property in
                    PropertyRow(model: model, node: info.id, property: property)
                }
            }
        }
        if !info.inputs.isEmpty {
            Section("Inputs") { ForEach(info.inputs) { PortRow(model: model, node: info.id, port: $0) } }
        }
        if !info.outputs.isEmpty {
            Section("Outputs") { ForEach(info.outputs) { PortRow(model: model, node: info.id, port: $0) } }
        }
    }
}

private struct PortRow: View {
    let model: GraphEditorModel
    let node: NodeID
    let port: InspectedPort

    var body: some View {
        HStack {
            LabeledContent {
                Text(detail).foregroundStyle(.secondary)
            } label: {
                HStack(spacing: 6) {
                    Circle().fill(Color(port.color)).frame(width: 9, height: 9)
                    // Blank puts the type's own name back.
                    CommitTextField(text: port.definition.displayName, placeholder: port.defaultName) { text in
                        model.setPortLabel(
                            PortAddress(node: node, port: port.definition.id, direction: port.definition.direction),
                            to: text)
                        return true
                    }
                }
            }
            if let exposed = port.isExposed {
                ExposeButton(isExposed: exposed, what: port.definition.direction == .input ? "input" : "output") {
                    let address = PortAddress(node: node, port: port.definition.id, direction: port.definition.direction)
                    if port.definition.direction == .input {
                        model.setExposed(!exposed, input: address)
                    } else {
                        model.setExposed(!exposed, output: address)
                    }
                }
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

// MARK: - Buttons

/// A text button for the inspector. In a form, iPadOS draws a plain button in the accent color,
/// which is hard to read on the inspector's gray; macOS draws it in the normal text color. This
/// draws it in the text color on both, and dims it when disabled.
private struct ActionButton: View {
    let title: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title).foregroundStyle(Color.primary).opacity(isEnabled ? 1 : 0.35)
        }
        .buttonStyle(.borderless)
    }
}

/// A symbol-only button, drawn in the text color for the same reason as ``ActionButton``.
private struct IconButton: View {
    let systemName: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName).foregroundStyle(Color.primary).opacity(isEnabled ? 1 : 0.35)
        }
        .buttonStyle(.borderless)
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
            if let exposed = property.isExposed {
                ExposeButton(isExposed: exposed, what: "property") {
                    model.setExposed(!exposed, property: PropertyTarget(node: node, property: property.definition.id))
                }
            }
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

/// A button that adds a port or property to the subgraph's interface, or takes it off again.
private struct ExposeButton: View {
    let isExposed: Bool
    let what: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isExposed ? "arrow.up.right.square.fill" : "arrow.up.right.square")
                .foregroundStyle(isExposed ? Color.accentColor : .secondary)
        }
        .buttonStyle(.borderless)
        .help(isExposed ? "Stop exposing this \(what) on the subgraph" : "Expose this \(what) on the subgraph")
        .accessibilityLabel(isExposed ? "Stop exposing \(what)" : "Expose \(what)")
    }
}

// MARK: - Subgraph interface

/// The subgraph being edited, when nothing inside it is selected: its name and category, how
/// many nodes use it, and the inputs, outputs and properties it exposes, which can be renamed,
/// reordered and removed here. Select a node inside to add to the list.
private struct SubgraphSections: View {
    let model: GraphEditorModel
    let info: SubgraphInspection

    var body: some View {
        Section("Subgraph") {
            LabeledContent("Name") {
                CommitTextField(text: info.name, placeholder: "Subgraph") { model.renameSubgraph(to: $0 ?? "") }
            }
            LabeledContent("Category") {
                CommitTextField(text: info.category, placeholder: "Subgraph") { model.setSubgraphCategory($0 ?? "") }
            }
            LabeledContent("Used by", value: info.instanceCount == 1 ? "1 node" : "\(info.instanceCount) nodes")
            ActionButton("Leave Subgraph") { model.leaveSubgraph() }
        }

        InterfaceSection(
            title: "Inputs", empty: "None. Select a node inside and expose one of its inputs.", entries: info.inputs,
            rename: { model.renameInput(PortID($0), to: $1) }, remove: { model.removeInput(PortID($0)) },
            move: { model.moveInput(PortID($0), by: $1) })
        InterfaceSection(
            title: "Outputs", empty: "None. Select a node inside and expose one of its outputs.", entries: info.outputs,
            rename: { model.renameOutput(PortID($0), to: $1) }, remove: { model.removeOutput(PortID($0)) },
            move: { model.moveOutput(PortID($0), by: $1) })
        InterfaceSection(
            title: "Properties", empty: "None. Select a node inside and expose one of its properties.", entries: info.properties,
            rename: { model.renameProperty(PropertyID($0), to: $1) }, remove: { model.removeProperty(PropertyID($0)) },
            move: { model.moveProperty(PropertyID($0), by: $1) })

        Section("Inside") {
            LabeledContent("Nodes", value: "\(info.summary.nodeCount)")
            LabeledContent("Links", value: "\(info.summary.linkCount)")
            LabeledContent("Groups", value: "\(info.summary.groupCount)")
        }
    }
}

/// One list of the interface: each entry renamed in place, moved up or down, or removed.
private struct InterfaceSection: View {
    let title: String
    let empty: String
    let entries: [InterfaceEntry]
    let rename: (String, String) -> Bool
    let remove: (String) -> Bool
    let move: (String, Int) -> Bool

    var body: some View {
        Section(title) {
            if entries.isEmpty {
                Text(empty).font(.callout).foregroundStyle(.secondary)
            }
            ForEach(entries) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        if let color = entry.color { Circle().fill(Color(color)).frame(width: 9, height: 9) }
                        CommitTextField(text: entry.displayName, placeholder: entry.id) { rename(entry.id, $0 ?? "") }
                        IconButton(systemName: "chevron.up") { _ = move(entry.id, -1) }
                            .disabled(!entry.canMoveUp)
                            .accessibilityLabel("Move \(entry.displayName) up")
                        IconButton(systemName: "chevron.down") { _ = move(entry.id, 1) }
                            .disabled(!entry.canMoveDown)
                            .accessibilityLabel("Move \(entry.displayName) down")
                        Button(role: .destructive) { _ = remove(entry.id) } label: { Image(systemName: "trash") }
                            .accessibilityLabel("Remove \(entry.displayName)")
                    }
                    .buttonStyle(.borderless)
                    Text("\(entry.typeName) · \(entry.detail)").font(.caption).foregroundStyle(.secondary)
                }
            }
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

        Section("Subgraph") {
            ActionButton("Create Subgraph…") { model.beginCreateSubgraph() }
        }

        Section("Arrange") {
            LabeledContent("Align") {
                HStack {
                    ForEach(AlignEdge.allCases, id: \.self) { edge in
                        IconButton(systemName: edge.symbol) { model.align(info.ids, to: edge) }
                            .help("Align \(edge.title)")
                            .accessibilityLabel("Align \(edge.title)")
                    }
                }
            }
            ActionButton("Auto-Arrange") { model.autoArrange(info.ids) }
                .disabled(info.ids.count < 2)
            LabeledContent("Distribute") {
                HStack {
                    ForEach(DistributeAxis.allCases, id: \.self) { axis in
                        IconButton(systemName: axis.symbol) { model.distribute(info.ids, along: axis) }
                            .disabled(info.ids.count < 3)
                            .help("Distribute \(axis.title)")
                            .accessibilityLabel("Distribute \(axis.title)")
                    }
                }
            }
        }
        .buttonStyle(.borderless)
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
                ActionButton("Remove Reroute Points") { model.clearWaypoints(of: info.id) }
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
                    ActionButton("Clear") { _ = apply(nil) }
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


private extension AlignEdge {
    var symbol: String {
        switch self {
        case .left: "align.horizontal.left"
        case .right: "align.horizontal.right"
        case .top: "align.vertical.top"
        case .bottom: "align.vertical.bottom"
        case .centerX: "align.horizontal.center"
        case .centerY: "align.vertical.center"
        }
    }
}

private extension DistributeAxis {
    var symbol: String { self == .horizontal ? "distribute.horizontal.center" : "distribute.vertical.center" }
}
