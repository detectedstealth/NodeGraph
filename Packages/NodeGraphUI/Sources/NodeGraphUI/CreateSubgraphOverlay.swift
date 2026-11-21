#if !os(tvOS) && !os(watchOS)
import NodeGraphCore
import SwiftUI

/// The Create Subgraph form: a name, which inner properties to expose on the new node, and
/// whether to open the subgraph afterwards. It dims the canvas, so a tap outside cancels.
struct CreateSubgraphOverlay: View {
    let model: GraphEditorModel

    var body: some View {
        if let request = model.createSubgraphRequest {
            ZStack {
                Color.black.opacity(0.35)
                    .contentShape(Rectangle())
                    .onTapGesture { model.cancelCreateSubgraph() }
                CreateSubgraphForm(model: model, request: request)
                    .id(request.nodes)
            }
        }
    }
}

private struct CreateSubgraphForm: View {
    let model: GraphEditorModel
    let request: CreateSubgraphRequest

    @State private var name = ""
    @State private var promoted = Set<String>()
    @State private var opensAfterwards = true
    @State private var selection: TextSelection?
    @FocusState private var isFocused: Bool

    private var theme: GraphTheme { model.theme }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Create Subgraph").font(.headline)
            Text(request.nodes.count == 1 ? "Wraps the selected node." : "Wraps the \(request.nodes.count) selected nodes.")
                .font(.footnote).foregroundStyle(.secondary)

            // Drawn with the theme's own colors: the system's rounded field is light, and the
            // form's text is light on dark.
            TextField("Name", text: $name, selection: $selection)
                .textFieldStyle(.plain)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(theme.nodeBody)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(
                    Color(isFocused ? theme.selection : theme.nodeBorder), lineWidth: isFocused ? 1.5 : 1))
                .tint(Color(theme.selection))
                .focused($isFocused)
                .onSubmit(create)
                #if os(iOS)
                .autocorrectionDisabled()
                #endif

            if !request.candidates.isEmpty {
                Text("Expose properties").font(.subheadline.weight(.semibold))
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(request.candidates) { candidate in
                            Toggle(isOn: Binding(
                                get: { promoted.contains(candidate.id) },
                                set: { if $0 { promoted.insert(candidate.id) } else { promoted.remove(candidate.id) } })
                            ) {
                                HStack {
                                    Text("\(candidate.nodeTitle) · \(candidate.title)")
                                    Spacer()
                                    Text(candidate.valueText).foregroundStyle(.secondary).monospacedDigit()
                                }
                                .font(.callout)
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
                .frame(maxHeight: 160)
                Text("Exposed properties can be set on each copy of the subgraph.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Toggle("Open it afterwards", isOn: $opensAfterwards).font(.callout)

            if let error = request.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.cancelCreateSubgraph() }
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .frame(width: 380)
        .foregroundStyle(Color(theme.nodeTitle))
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(theme.nodeHeader)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(theme.nodeBorder), lineWidth: 1))
        .shadow(radius: 20, y: 6)
        .task {
            name = request.suggestedName
            isFocused = true
            // Select the suggestion so typing replaces it. The field resets its selection as it
            // takes focus, so this waits for that to settle.
            try? await Task.sleep(for: .milliseconds(100))
            selection = TextSelection(range: name.startIndex..<name.endIndex)
        }
    }

    private func create() {
        let targets = request.candidates.filter { promoted.contains($0.id) }.map(\.target)
        model.createSubgraph(name: name, promoting: targets, open: opensAfterwards)
    }
}
#endif
