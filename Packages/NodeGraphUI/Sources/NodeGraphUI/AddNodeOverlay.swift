#if !os(tvOS) && !os(watchOS)
import NodeGraphCore
import SwiftUI

/// The add-node panel: a search field over a list of node types. With nothing typed it browses by
/// category; typing ranks matches. When opened from a dragged link it lists only nodes the link
/// can end on. Return or a click adds the highlighted node; Escape or a press on the canvas
/// closes it.
struct AddNodeOverlay: View {
    let controller: GraphInteractionController

    var body: some View {
        if let request = controller.addNodeRequest {
            AddNodePanel(controller: controller, request: request)
                .id(request)
        }
    }
}

private struct AddNodePanel: View {
    let controller: GraphInteractionController
    let request: GraphInteractionController.AddNodeRequest

    @State private var catalog: NodeCatalog?
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var isFocused: Bool

    private static let width: CGFloat = 300
    private static let height: CGFloat = 340

    private var theme: GraphTheme { controller.model.theme }

    /// Matches for the query. Empty browse of a plain request shows every node.
    private var matches: [NodeCatalogMatch] {
        catalog?.search(query, connecting: request.filter) ?? []
    }

    /// What the highlighted node does, shown under the list.
    private var highlightedHelp: String? {
        let found = matches
        guard found.indices.contains(highlighted) else { return nil }
        let help = found[highlighted].entry.help
        return help.isEmpty ? nil : help
    }

    /// Browse order groups by category; a search or a link shows one ranked list.
    private var isBrowsing: Bool { query.isEmpty && request.filter == nil }

    var body: some View {
        let size = controller.model.viewSize
        // Open beside the point, kept inside the view.
        let x = min(max(request.screenPoint.x + 8, 8), max(size.width - Self.width - 8, 8))
        let y = min(max(request.screenPoint.y + 8, 8), max(size.height - Self.height - 8, 8))

        VStack(spacing: 0) {
            TextField("Add node", text: $query)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .font(.body)
                .padding(10)
                .onSubmit(addHighlighted)
                #if os(iOS)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                #endif
            Divider().overlay(Color(theme.nodeBorder))
            results
            if let help = highlightedHelp {
                Divider().overlay(Color(theme.nodeBorder))
                Text(help)
                    .font(.caption)
                    .foregroundStyle(Color(theme.portLabel))
                    .frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
        }
        .foregroundStyle(Color(theme.nodeTitle))
        .tint(Color(theme.selection))
        .frame(width: Self.width, height: Self.height)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(theme.nodeHeader)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(theme.nodeBorder), lineWidth: 1))
        .shadow(radius: 12, y: 4)
        .position(x: x + Self.width / 2, y: y + Self.height / 2)
        .onAppear {
            catalog = controller.model.makeNodeCatalog()
            isFocused = true
        }
        .onChange(of: query) { _, _ in highlighted = 0 }
        .onKeyPress(.downArrow) { move(1) }
        .onKeyPress(.upArrow) { move(-1) }
        .onKeyPress(.escape) {
            controller.cancelAddNode()
            return .handled
        }
    }

    @ViewBuilder private var results: some View {
        let found = matches
        if found.isEmpty {
            Text(catalog == nil ? "" : "No matching nodes")
                .font(.callout)
                .foregroundStyle(Color(theme.portLabel))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if isBrowsing, let groups = catalog?.categories {
                            ForEach(groups, id: \.name) { group in
                                Text(group.name.uppercased())
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(Color(theme.portLabel))
                                    .padding(.horizontal, 10)
                                    .padding(.top, 8)
                                    .padding(.bottom, 2)
                                ForEach(group.entries) { entry in
                                    if let index = found.firstIndex(where: { $0.id == entry.id }) {
                                        row(found[index], index: index, showsCategory: false)
                                    }
                                }
                            }
                        } else {
                            ForEach(Array(found.enumerated()), id: \.element.id) { index, match in
                                row(match, index: index, showsCategory: true)
                            }
                        }
                    }
                }
                .onChange(of: highlighted) { _, newValue in
                    if found.indices.contains(newValue) { proxy.scrollTo(found[newValue].id) }
                }
            }
        }
    }

    private func row(_ match: NodeCatalogMatch, index: Int, showsCategory: Bool) -> some View {
        Button {
            controller.addNode(match)
        } label: {
            HStack {
                Text(match.entry.displayName).font(.callout)
                Spacer()
                if let port = match.port {
                    Text(port.displayName).font(.caption).foregroundStyle(Color(theme.portLabel))
                } else if showsCategory {
                    Text(match.entry.category).font(.caption).foregroundStyle(Color(theme.portLabel))
                }
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 28)
            .background(index == highlighted ? Color(theme.selection.withAlpha(0.35)) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(match.id)
    }

    private func move(_ step: Int) -> KeyPress.Result {
        let count = matches.count
        guard count > 0 else { return .handled }
        highlighted = min(max(highlighted + step, 0), count - 1)
        return .handled
    }

    private func addHighlighted() {
        let found = matches
        guard found.indices.contains(highlighted) else { return }
        controller.addNode(found[highlighted])
    }
}
#endif
