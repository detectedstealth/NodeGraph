import NodeGraphAI
import NodeGraphAssistant
import NodeGraphCore
import NodeGraphUI
import SwiftUI

/// What the assistant panel shows and does, on top of a frozen ``AssistantWorkspace``. It shows the
/// digest, lint findings, traces and proposals the tools produce, lets a person try the propose
/// tools with hand-written JSON, and, with a model available, explains a value and generates a
/// graph from a description. The model only phrases or chooses; the proposal still goes through
/// the same preview and Apply as any other (decisions 211 and 229).
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

    // MARK: Model state

    // MARK: Models and keys

    private static let endpointsKey = "assistant.endpoints"
    private static let endpointKey = "assistant.endpoint"
    private static let consentKey = "assistant.consented"

    /// Keys live in the Keychain, one item per model, never in settings (decision 214).
    let secrets: any SecretStore = KeychainSecretStore()

    /// The models the picker offers: the three built in, and any a person added (decision 235).
    private(set) var endpoints: [ModelEndpoint] = AssistantPanelModel.loadEndpoints()

    /// The chosen model, kept between launches.
    var endpointID: String = UserDefaults.standard.string(forKey: AssistantPanelModel.endpointKey)
        ?? ModelEndpoint.appleOnDevice.id {
        didSet {
            UserDefaults.standard.set(endpointID, forKey: Self.endpointKey)
            modelMessage = ""
            explanation = nil
        }
    }
    var generateRequest = ""
    private(set) var explanation: Explanation?
    private(set) var modelMessage = ""
    private(set) var isAsking = false
    private var modelTask: Task<Void, Never>?

    /// Models that send data off this device ask once before the first request (decision 235).
    var needsConsent = false
    private var consented = Set(UserDefaults.standard.stringArray(forKey: AssistantPanelModel.consentKey) ?? [])
    private var deferredAsk: (@MainActor () async throws -> Void)?

    private static func loadEndpoints() -> [ModelEndpoint] {
        let builtIn: [ModelEndpoint] = [.appleOnDevice, .applePrivateCloud, .claude()]
        guard let data = UserDefaults.standard.data(forKey: endpointsKey),
              let saved = try? JSONDecoder().decode([ModelEndpoint].self, from: data) else { return builtIn }
        // A saved list replaces the built-in ones it names, and the Apple ones always come first.
        var list = builtIn.filter { $0.kind == .appleOnDevice || $0.kind == .applePrivateCloud }
        list += saved.filter { $0.kind != .appleOnDevice && $0.kind != .applePrivateCloud }
        if !list.contains(where: { $0.id == "claude" }) { list.append(.claude()) }
        return list
    }

    private func saveEndpoints() {
        let editable = endpoints.filter { $0.kind != .appleOnDevice && $0.kind != .applePrivateCloud }
        UserDefaults.standard.set(try? JSONEncoder().encode(editable), forKey: Self.endpointsKey)
    }

    /// Adds a model or replaces the one with the same id, stores its key if one was given, and selects it.
    func save(_ endpoint: ModelEndpoint, key: String?) {
        if let index = endpoints.firstIndex(where: { $0.id == endpoint.id }) { endpoints[index] = endpoint } else { endpoints.append(endpoint) }
        saveEndpoints()
        if let key, let account = endpoint.keyAccount {
            do { try secrets.setSecret(key, for: account) } catch { modelMessage = "\(error.localizedDescription)" }
        }
        endpointID = endpoint.id
    }

    func remove(_ endpoint: ModelEndpoint) {
        guard endpoint.kind != .appleOnDevice, endpoint.kind != .applePrivateCloud, endpoint.id != "claude" else { return }
        endpoints.removeAll { $0.id == endpoint.id }
        saveEndpoints()
        if let account = endpoint.keyAccount { try? secrets.setSecret(nil, for: account) }
        if endpointID == endpoint.id { endpointID = ModelEndpoint.appleOnDevice.id }
    }

    func hasKey(_ endpoint: ModelEndpoint) -> Bool {
        endpoint.keyAccount.map { !(secrets.secret(for: $0)?.isEmpty ?? true) } ?? false
    }

    func removeKey(of endpoint: ModelEndpoint) {
        if let account = endpoint.keyAccount { try? secrets.setSecret(nil, for: account) }
    }

    func confirmConsent() {
        consented.insert(endpointID)
        UserDefaults.standard.set(Array(consented), forKey: Self.consentKey)
        needsConsent = false
        if let work = deferredAsk {
            deferredAsk = nil
            ask(work)
        }
    }

    func cancelConsent() {
        needsConsent = false
        deferredAsk = nil
    }

    /// The worked examples the on-device model sees when picking node types: a four-node one and a
    /// one-node one, since a lone big example makes it copy that shape. They name types of the
    /// standard pack and are used only if the registry has them (decisions 233 and 234).
    static let generationExamples = [
        GenerationExample(
            task: "double a number and show it",
            types: ["util.number", "util.number", "math.multiply", "util.watch"],
            explanation: "a number, the number 2, the multiply node, and a node that shows the result"),
        GenerationExample(
            task: "make a number with the value 7", types: ["util.number"],
            explanation: "just the number node, nothing else"),
    ]

    var endpoint: ModelEndpoint { endpoints.first { $0.id == endpointID } ?? .appleOnDevice }
    /// Asked each time it is read: a person can turn Apple Intelligence on while the app is open.
    var availability: ModelAvailability { endpoint.availability(secrets: secrets) }

    init(model: GraphEditorModel) {
        self.model = model
        workspace = AssistantWorkspace(editor: model.editor)
        // Not refresh(): this runs for every throwaway copy SwiftUI makes while it evaluates
        // ContentView.init, and a copy must not touch the canvas model it shares with the real one.
        takeSnapshot()
    }

    /// Whether the open graph is a subgraph's inside. The snapshot is of the root graph, so
    /// proposals are not offered there.
    var isInsideSubgraph: Bool { model.currentScope != nil }

    /// Takes a new snapshot of the graph, its selection and the last run, and redoes the checks.
    func refresh() {
        takeSnapshot()
        // A proposal made on an older graph is stale, and is shown as such rather than dropped.
        if let pending, pending.isStale(for: model.editor) {
            proposalMessage = "The graph changed since this was proposed. Propose it again."
        }
        showPreview()
    }

    private func takeSnapshot() {
        workspace = AssistantWorkspace(
            editor: model.editor, runValues: model.runValues, selection: model.selection.nodes)
        findings = workspace.lint()
        if let shown = try? workspace.digest() {
            digest = shown.text
            digestNote = (model.selection.nodes.isEmpty ? "Whole graph" : "Selection and its neighbours")
                + ", about \(shown.estimatedTokens) tokens"
                + (shown.omittedNodeCount > 0 ? ", \(shown.omittedNodeCount) nodes left out" : "")
        }
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
        explanation = nil
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

    // MARK: Model

    /// Asks the model to put the trace of `traceReference` in words. The trace itself is shown too.
    func explain() {
        let reference = traceReference.trimmingCharacters(in: .whitespaces)
        guard !reference.isEmpty else {
            traceMessage = "Type a port such as n3.result, or pick one from the selected nodes."
            return
        }
        guard let generator = endpoint.makeGenerator(secrets: secrets) else {
            modelMessage = availability.summary
            return
        }
        refresh()
        let explainer = ValueExplainer(workspace: workspace, generator: generator, contextTokens: endpoint.contextTokens)
        ask {
            let result = try await explainer.explain(reference)
            self.traceText = result.trace
            self.traceMessage = ""
            self.explanation = result
        }
    }

    /// Builds a graph from `generateRequest` in stages and shows it as a pending change.
    func generate() {
        let request = generateRequest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty, !isInsideSubgraph else { return }
        guard let generator = endpoint.makeGenerator(secrets: secrets) else {
            modelMessage = availability.summary
            return
        }
        refresh()
        let space = workspace
        let builder = GraphGenerator(
            workspace: space, generator: generator, maxNodes: endpoint.contextTokens <= 4_096 ? 8 : 12,
            examples: Self.generationExamples, allowsRepeatedOperations: endpoint.contextTokens > 4_096,
            strategy: endpoint.contextTokens > 4_096 ? .oneShot : .staged)
        ask {
            let outcome = try await builder.generate(request)
            self.pending = outcome.change
            var text = outcome.change.rendered(in: space)
            if !outcome.notes.isEmpty { text += "\nLeft out:\n" + outcome.notes.map { "- " + $0 }.joined(separator: "\n") }
            self.pendingText = text
            self.proposalMessage = outcome.change.isEmpty ? "The model proposed nothing." : ""
        }
    }

    func stopAsking() { modelTask?.cancel() }

    /// Runs one model request at a time and turns its failure into words for the person.
    private func ask(_ work: @escaping @MainActor () async throws -> Void) {
        guard !isAsking else { return }
        if endpoint.sendsDataOffDevice, !consented.contains(endpoint.id) {
            deferredAsk = work
            needsConsent = true
            return
        }
        isAsking = true
        modelMessage = ""
        modelTask = Task {
            defer {
                isAsking = false
                modelTask = nil
            }
            do {
                try await work()
            } catch is CancellationError {
                modelMessage = "Stopped."
            } catch {
                modelMessage = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
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
    @State private var editing: EndpointDraft?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                modelSection
                checksSection
                digestSection
                traceSection
                generateSection
                proposeSection
                pendingSection
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

    private var modelSection: some View {
        section("Model") {
            HStack {
                Picker("Model", selection: $assistant.endpointID) {
                    ForEach(assistant.endpoints) { endpoint in
                        Text(endpoint.name).tag(endpoint.id)
                    }
                }
                .labelsHidden()
                if assistant.endpoint.kind != .appleOnDevice && assistant.endpoint.kind != .applePrivateCloud {
                    Button("Edit", systemImage: "gearshape") {
                        editing = EndpointDraft(endpoint: assistant.endpoint, isNew: false)
                    }
                    .labelStyle(.iconOnly)
                    .help("Edit this model's address, name and key")
                }
                Menu("Add", systemImage: "plus") {
                    ForEach(ModelEndpoint.presets) { preset in
                        Button(preset.name) { editing = EndpointDraft(endpoint: newEndpoint(from: preset), isNew: true) }
                    }
                    Button("Other server…") {
                        editing = EndpointDraft(
                            endpoint: newEndpoint(from: .openAICompatible(
                                name: "My server", baseURL: URL(string: "http://localhost:8080/v1")!, model: "")),
                            isNew: true)
                    }
                }
                .labelStyle(.iconOnly)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Add a model: Ollama, LM Studio, OpenAI, OpenRouter or any OpenAI-compatible server")
            }
            let availability = assistant.availability
            Label(availability.summary, systemImage: availability.isAvailable ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(availability.isAvailable ? .green : .secondary)
                .font(.callout)
            if assistant.endpoint.sendsDataOffDevice {
                Text("This model is not on your device: the text of your request, and for Explain the node names and values in the trace, are sent to it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if assistant.isAsking {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Asking the model…").font(.callout)
                    Button("Stop") { assistant.stopAsking() }.controlSize(.small)
                }
            }
            note(assistant.modelMessage)
        }
        .sheet(item: $editing) { draft in
            EndpointEditor(assistant: assistant, draft: draft) { editing = nil }
        }
        .alert("Send to \(assistant.endpoint.name)?", isPresented: $assistant.needsConsent) {
            Button("Send") { assistant.confirmConsent() }
            Button("Cancel", role: .cancel) { assistant.cancelConsent() }
        } message: {
            Text("This model is not on your device. The text of your request, and for Explain the node names and values in the trace, will be sent to it. You are asked once for each model.")
        }
    }

    /// A copy of a preset to edit: its own id and Keychain account, so two models never share a key by accident.
    private func newEndpoint(from preset: ModelEndpoint) -> ModelEndpoint {
        var endpoint = preset
        endpoint.id = UUID().uuidString
        endpoint.keyAccount = "endpoint." + endpoint.id
        return endpoint
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
                Button("Explain", systemImage: "sparkles") { assistant.explain() }
                    .disabled(!assistant.availability.isAvailable || assistant.isAsking)
                    .help("Ask the model to put the trace in words")
            }
            note(assistant.traceMessage)
            if let explanation = assistant.explanation {
                VStack(alignment: .leading, spacing: 8) {
                    Label("From the run", systemImage: "checkmark.seal")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(explanation.summary).textSelection(.enabled)
                    Label("The model's reading. It can be wrong.", systemImage: "sparkles")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(explanation.narration).textSelection(.enabled)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }
            if !assistant.traceText.isEmpty {
                Text(assistant.traceText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var generateSection: some View {
        section("Generate a graph") {
            Text("Describe what to add. The result is previewed under Pending change; nothing is applied until you press Apply.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("For example: add two numbers and show the sum", text: $assistant.generateRequest, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
            Button("Generate", systemImage: "sparkles") { assistant.generate() }
                .disabled(assistant.generateRequest.isEmpty || !assistant.availability.isAvailable
                    || assistant.isAsking || assistant.isInsideSubgraph)
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
        }
    }

    @ViewBuilder private var pendingSection: some View {
        if let pending = assistant.pending {
            section("Pending change") {
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
