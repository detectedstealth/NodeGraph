import NodeGraphAssistant
import NodeGraphCore
import NodeGraphUI
import SwiftUI

/// What the assistant panel shows and does, on top of a frozen ``AssistantWorkspace``. There is
/// no model behind it: it lets a person see the digest, lint findings, traces and proposals the
/// tools produce, and try the propose tools with hand-written JSON.
@MainActor
@Observable
final class AssistantPanelModel {
    let model: GraphEditorModel
    private(set) var workspace: AssistantWorkspace
    private(set) var findings: [LintFinding] = []
    private(set) var digest = ""
    private(set) var digestNote = ""

    var traceReference = ""
    private(set) var traceText = ""

    var proposalText = ""
    /// The proposal under review. It is drawn on the canvas as a ghost while it is current.
    private(set) var pending: PendingChange? {
        didSet { showPreview() }
    }
    private(set) var pendingText = ""
    private(set) var isComparing = false

    /// What went wrong or was done, shown under the section it belongs to.
    private(set) var traceMessage = ""
    private(set) var proposalMessage = ""
    private(set) var fixMessage = ""

    init(model: GraphEditorModel) {
        self.model = model
        workspace = AssistantWorkspace(editor: model.editor)
        refresh()
    }

    /// Whether the open graph is a subgraph's inside. The snapshot is of the root graph, so
    /// proposals are not offered there.
    var isInsideSubgraph: Bool { model.currentScope != nil }

    /// Takes a new snapshot of the graph, its selection and the last run, and redoes the checks.
    func refresh() {
        workspace = AssistantWorkspace(
            editor: model.editor, runValues: model.runValues, selection: model.selection.nodes)
        findings = workspace.lint()
        if let shown = try? workspace.digest() {
            digest = shown.text
            digestNote = (model.selection.nodes.isEmpty ? "Whole graph" : "Selection and its neighbours")
                + ", about \(shown.estimatedTokens) tokens"
                + (shown.omittedNodeCount > 0 ? ", \(shown.omittedNodeCount) nodes left out" : "")
        }
        // A proposal made on an older graph is stale, and is shown as such rather than dropped.
        if let pending, pending.isStale(for: model.editor) {
            proposalMessage = "The graph changed since this was proposed. Propose it again."
        }
        showPreview()
    }

    /// Draws `pending` on the canvas, unless the graph has changed since it was proposed: then
    /// the ghost would be in the wrong place.
    private func showPreview() {
        if let pending, !pending.isStale(for: model.editor) {
            model.preview = GraphPreview(base: model.editor.graph, result: pending.resultGraph)
        } else {
            model.preview = nil
        }
    }

    /// The output ports of the selected nodes, named the way the trace box wants them.
    var selectedOutputs: [String] { workspace.selectedOutputReferences() }

    func name(of finding: LintFinding) -> String {
        guard let node = finding.diagnostic.node else { return "Graph" }
        return "\(workspace.aliases.alias(for: node) ?? "?") \(model.consoleName(of: node))"
    }

    func reveal(_ finding: LintFinding) {
        if let node = finding.diagnostic.node { model.reveal(node: node) }
    }

    // MARK: Fixes

    func applyFix(_ finding: LintFinding) {
        guard let change = workspace.proposeFix(finding) else { return }
        fixMessage = apply(change)
    }

    // MARK: Trace

    func trace() {
        let reference = traceReference.trimmingCharacters(in: .whitespaces)
        guard !reference.isEmpty else {
            traceMessage = "Type a port such as n3.result, or pick one from the selected nodes."
            return
        }
        do {
            let trace = try workspace.traceUpstream(reference)
            traceText = trace.rendered(aliases: workspace.aliases)
            traceMessage = ""
        } catch {
            traceText = ""
            traceMessage = "\(error)"
        }
    }

    // MARK: Proposals

    func propose() {
        refresh()
        do {
            let change = try workspace.propose(json: proposalText)
            pending = change
            pendingText = change.rendered(in: workspace)
            proposalMessage = change.isEmpty ? "That proposes no changes." : ""
        } catch {
            pending = nil
            pendingText = ""
            proposalMessage = "\(error)"
        }
    }

    /// Runs the graph with and without the proposal and adds what differs to the description.
    func compareRun() {
        guard let change = pending, !isComparing else { return }
        isComparing = true
        let space = workspace
        Task {
            defer { isComparing = false }
            do {
                let compared = try await change.withRunComparison(in: space)
                pending = compared
                pendingText = compared.rendered(in: space)
            } catch {
                proposalMessage = "\(error)"
            }
        }
    }

    func applyPending() {
        guard let change = pending else { return }
        proposalMessage = apply(change)
    }

    func discardPending() {
        pending = nil
        pendingText = ""
    }

    /// Applies a change as one undo step. Returns what to tell the person.
    private func apply(_ change: PendingChange) -> String {
        guard !isInsideSubgraph else { return "Leave the subgraph first: the assistant works on the root graph." }
        guard !change.isStale(for: model.editor) else { return "The graph changed since this was proposed. Propose it again." }
        do {
            try model.perform(change.command, name: change.title)
            pending = nil
            pendingText = ""
            refresh()
            return "Applied: \(change.title). Undo reverts it."
        } catch {
            return "Could not apply: \(error)"
        }
    }
}

/// The assistant panel: checks with a fix button each, the digest, a value trace, and a box to
/// try a proposal written as JSON. Laid out in a plain scroll view, not a grouped Form: a Form is
/// backed by a table on macOS, and a multi-line text box inside a table row does not reliably
/// take the keyboard.
struct AssistantPanel: View {
    @Bindable var assistant: AssistantPanelModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                checksSection
                digestSection
                traceSection
                proposeSection
            }
            .padding(12)
        }
        // The snapshot follows edits, selection and each run's values.
        .onChange(of: assistant.model.revision) { assistant.refresh() }
        .onChange(of: assistant.model.selection) { assistant.refresh() }
        .onChange(of: assistant.model.runValues) { assistant.refresh() }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }

    private var checksSection: some View {
        section("Checks") {
            if assistant.findings.isEmpty {
                Text("Nothing to report.").foregroundStyle(.secondary)
            }
            ForEach(Array(assistant.findings.enumerated()), id: \.offset) { _, finding in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: finding.level == .problem ? "exclamationmark.triangle.fill" : "lightbulb")
                            .foregroundStyle(finding.level == .problem ? .orange : .secondary)
                        VStack(alignment: .leading) {
                            Text(assistant.name(of: finding)).font(.caption).foregroundStyle(.secondary)
                            Text(finding.diagnostic.message)
                        }
                    }
                    if let fix = finding.fix {
                        Button(fix.description, systemImage: "wand.and.stars") { assistant.applyFix(finding) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(assistant.isInsideSubgraph)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { assistant.reveal(finding) }
                Divider()
            }
            note(assistant.fixMessage)
        }
    }

    private var digestSection: some View {
        section("Digest") {
            Text(assistant.digestNote).font(.caption).foregroundStyle(.secondary)
            ScrollView([.horizontal, .vertical]) {
                Text(assistant.digest)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 140)
            .padding(6)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private var traceSection: some View {
        section("Trace a value") {
            HStack {
                TextField("Port, such as n3.result", text: $assistant.traceReference)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { assistant.trace() }
                if !assistant.selectedOutputs.isEmpty {
                    Menu("Selected", systemImage: "list.bullet") {
                        ForEach(assistant.selectedOutputs, id: \.self) { port in
                            Button(port) {
                                assistant.traceReference = port
                                assistant.trace()
                            }
                        }
                    }
                    .labelStyle(.iconOnly)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Outputs of the selected nodes")
                }
                Button("Trace") { assistant.trace() }
            }
            note(assistant.traceMessage)
            if !assistant.traceText.isEmpty {
                Text(assistant.traceText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var proposeSection: some View {
        section("Propose a change") {
            Text("JSON: a graph spec or a list of edits. Nodes are named n1, n2, ... as in the Digest.")
                .font(.caption).foregroundStyle(.secondary)
            Text("""
                {"nodes": [{"alias": "a", "type": "util.number"}]}
                [{"op": "setMode", "node": "n3", "value": "muted"}]
                [{"op": "connect", "from": "n1.out", "to": "n2.a"}]
                """)
                .font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary)
                .textSelection(.enabled)
            TextEditor(text: $assistant.proposalText)
                .font(.system(.caption, design: .monospaced))
                .scrollContentBackground(.hidden)
                .autocorrectionDisabled()
                .padding(4)
                .frame(height: 120)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            Button("Propose") { assistant.propose() }
                .disabled(assistant.proposalText.isEmpty || assistant.isInsideSubgraph)
            note(assistant.proposalMessage)
            if let pending = assistant.pending {
                Text(assistant.pendingText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    Button("Apply") { assistant.applyPending() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!pending.canApply)
                    Button(assistant.isComparing ? "Running…" : "Compare run") { assistant.compareRun() }
                        .disabled(assistant.isComparing || pending.isEmpty)
                    Button("Discard", role: .cancel) { assistant.discardPending() }
                }
            }
        }
    }

    /// A line of feedback under the control that caused it, if there is one.
    @ViewBuilder private func note(_ text: String) -> some View {
        if !text.isEmpty { Text(text).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
    }
}
