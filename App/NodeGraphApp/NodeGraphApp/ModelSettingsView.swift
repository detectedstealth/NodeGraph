import NodeGraphAI
import SwiftUI

/// A model being added or edited in the sheet.
struct EndpointDraft: Identifiable {
    let id = UUID()
    var endpoint: ModelEndpoint
    var isNew: Bool
}

/// Adds or edits a model: its address, name, context size and API key (decision 235). The key goes
/// to the Keychain only when saved; Test uses it from memory, so a wrong key is never stored.
struct EndpointEditor: View {
    let assistant: AssistantPanelModel
    let draft: EndpointDraft
    let dismiss: () -> Void

    @State private var name: String
    @State private var address: String
    @State private var modelName: String
    @State private var contextTokens: Int
    @State private var key = ""
    @State private var testing = false
    @State private var testResult: (ok: Bool, text: String)?

    init(assistant: AssistantPanelModel, draft: EndpointDraft, dismiss: @escaping () -> Void) {
        self.assistant = assistant
        self.draft = draft
        self.dismiss = dismiss
        let endpoint = draft.endpoint
        _name = State(initialValue: endpoint.name)
        _address = State(initialValue: endpoint.baseURL?.absoluteString ?? "")
        _modelName = State(initialValue: endpoint.modelName ?? "")
        _contextTokens = State(initialValue: endpoint.contextTokens)
    }

    private var isClaude: Bool { draft.endpoint.kind == .claude }
    private var removable: Bool { !draft.isNew && draft.endpoint.id != "claude" }

    /// The endpoint as the form describes it.
    private var edited: ModelEndpoint {
        var endpoint = draft.endpoint
        endpoint.name = name
        endpoint.modelName = modelName.trimmingCharacters(in: .whitespaces)
        endpoint.contextTokens = max(contextTokens, 1_000)
        if !isClaude { endpoint.baseURL = URL(string: address.trimmingCharacters(in: .whitespaces)) }
        if endpoint.keyAccount == nil { endpoint.keyAccount = "endpoint." + endpoint.id }
        return endpoint
    }

    private var addressProblem: String? {
        guard !isClaude else { return nil }
        guard let url = URL(string: address.trimmingCharacters(in: .whitespaces)), let scheme = url.scheme,
              ["http", "https"].contains(scheme), url.host() != nil else {
            return "Enter an address that starts with http:// or https://"
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(draft.isNew ? "Add a model" : "Edit \(draft.endpoint.name)").font(.headline)
            Form {
                TextField("Name", text: $name)
                if !isClaude {
                    TextField("Server address", text: $address, prompt: Text("http://localhost:11434/v1"))
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                    if let addressProblem { Text(addressProblem).font(.caption).foregroundStyle(.orange) }
                }
                TextField("Model", text: $modelName, prompt: Text(isClaude ? "claude-opus-5-5" : "llama3.1"))
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                TextField("Context window (tokens)", value: $contextTokens, format: .number)
                SecureField("API key", text: $key, prompt: Text(assistant.hasKey(edited) ? "Saved in the Keychain" : "Stored in the Keychain"))
                if !isClaude, !edited.sendsDataOffDevice {
                    Text("A server on this Mac does not need a key.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.columns)

            if edited.sendsDataOffDevice {
                Text("Requests to this model leave your device. You are asked once before the first one.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let testResult {
                Label(testResult.text, systemImage: testResult.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(testResult.ok ? .green : .orange)
                    .font(.callout)
                    .textSelection(.enabled)
            }
            HStack {
                if removable {
                    Button("Delete", role: .destructive) {
                        assistant.remove(draft.endpoint)
                        dismiss()
                    }
                }
                if assistant.hasKey(edited) {
                    Button("Remove key") { assistant.removeKey(of: edited) }
                }
                Spacer()
                Button(testing ? "Testing…" : "Test") { test() }
                    .disabled(testing || addressProblem != nil)
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") {
                    assistant.save(edited, key: key.isEmpty ? nil : key)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty || addressProblem != nil)
            }
        }
        .padding(20)
        .frame(minWidth: 420)
    }

    /// Sends one tiny request with the key as typed, so a wrong address, key or model name shows
    /// here and not in the middle of a task.
    private func test() {
        testing = true
        testResult = nil
        let endpoint = edited
        let temporary = InMemorySecretStore()
        let stored = endpoint.keyAccount.flatMap { assistant.secrets.secret(for: $0) }
        if let account = endpoint.keyAccount { try? temporary.setSecret(key.isEmpty ? stored : key, for: account) }
        Task {
            defer { testing = false }
            guard let generator = endpoint.makeGenerator(secrets: temporary) else {
                testResult = (false, endpoint.availability(secrets: temporary).summary)
                return
            }
            do {
                let reply = try await generator.narrate(prompt: "Reply with the single word: ready")
                testResult = (true, "The model answered: \(reply.prefix(60))")
            } catch {
                testResult = (false, (error as? LocalizedError)?.errorDescription ?? "\(error)")
            }
        }
    }
}
