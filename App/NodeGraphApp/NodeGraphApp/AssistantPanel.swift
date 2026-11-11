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
    private(set) var pending: PendingChange?
    private(set) var pendingText = ""
    private(set) var isComparing = false

    /// The last thing that went wrong or was done, shown under the controls.
    private(set) var message = ""

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
            message = "The graph changed since this was proposed. Propose it again."
        }
    }

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
        apply(change)
    }

    // MARK: Trace

    func trace() {
        let reference = traceReference.trimmingCharacters(in: .whitespaces)
        guard !reference.isEmpty else { return }
        do {
            let trace = try workspace.traceUpstream(reference)
            traceText = trace.rendered(aliases: workspace.aliases)
            message = ""
        } catch {
            traceText = ""
            message = "\(error)"
        }
    }

    // MARK: Proposals

    func propose() {
        refresh()
        do {
            let change = try workspace.propose(json: proposalText)
            pending = change
            pendingText = change.rendered(in: workspace)
            message = ""
        } catch {
            pending = nil
            pendingText = ""
            message = "\(error)"
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
                message = "\(error)"
            }
        }
    }

    func applyPending() {
        guard let change = pending else { return }
        apply(change)
    }

    func discardPending() {
        pending = nil
        pendingText = ""
    }

    /// Applies a change as one undo step.
    private func apply(_ change: PendingChange) {
        guard !isInsideSubgraph else {
            message = "Leave the subgraph first: the assistant works on the root graph."
            return
        }
        guard !change.isStale(for: model.editor) else {
            message = "The graph changed since this was proposed. Propose it again."
            return
        }
        do {
            try model.perform(change.command, name: change.title)
            pending = nil
            pendingText = ""
            message = "Applied: \(change.title). Undo reverts it."
        } catch {
            message = "Could not apply: \(error)"
        }
        refresh()
    }
}

/// The assistant panel: checks with a fix button each, the digest, a value trace, and a box to
/// try a proposal written as JSON.
struct AssistantPanel: View {
    @Bindable var assistant: AssistantPanelModel

    var body: some View {
        Form {
            checksSection
            digestSection
            traceSection
            proposeSection
            if !assistant.message.isEmpty {
                Section { Text(assistant.message).font(.callout).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .toolbar {
            ToolbarItem { Button("Refresh", systemImage: "arrow.clockwise") { assistant.refresh() } }
        }
        // The snapshot follows edits and selection, and a Refresh picks up a new run.
        .onChange(of: assistant.model.revision) { assistant.refresh() }
        .onChange(of: assistant.model.selection) { assistant.refresh() }
    }

    private var checksSection: some View {
        Section("Checks") {
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
                .contentShape(Rectangle())
                .onTapGesture { assistant.reveal(finding) }
            }
        }
    }

    private var digestSection: some View {
        Section("Digest") {
            Text(assistant.digestNote).font(.caption).foregroundStyle(.secondary)
            ScrollView([.horizontal, .vertical]) {
                Text(assistant.digest)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 140)
        }
    }

    private var traceSection: some View {
        Section("Trace a value") {
            HStack {
                TextField("Port, such as n3.result", text: $assistant.traceReference)
                    .onSubmit { assistant.trace() }
                Button("Trace") { assistant.trace() }
            }
            if !assistant.traceText.isEmpty {
                Text(assistant.traceText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var proposeSection: some View {
        Section("Propose a change") {
            TextEditor(text: $assistant.proposalText)
                .font(.system(.caption, design: .monospaced))
                .frame(height: 110)
                .overlay(alignment: .topLeading) {
                    if assistant.proposalText.isEmpty {
                        Text("A graph spec ({\"nodes\": [...], \"links\": [...]}) or edits ([{\"op\": \"setMode\", ...}])")
                            .font(.caption).foregroundStyle(.tertiary).padding(6).allowsHitTesting(false)
                    }
                }
            Button("Propose") { assistant.propose() }
                .disabled(assistant.proposalText.isEmpty || assistant.isInsideSubgraph)
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
}
