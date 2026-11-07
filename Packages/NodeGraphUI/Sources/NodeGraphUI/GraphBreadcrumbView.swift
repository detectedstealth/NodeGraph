import NodeGraphCore
import SwiftUI

/// Shows where you are when editing inside a subgraph: "Graph › Outer › Inner", each level but
/// the last a button that goes back to it. Draws nothing at the root graph.
public struct GraphBreadcrumbView: View {
    private let controller: GraphInteractionController

    public init(controller: GraphInteractionController) {
        self.controller = controller
    }

    public var body: some View {
        let model = controller.model
        // A snapshot of the levels. SwiftUI can still be updating a row for a level that has just
        // gone (leaving a subgraph), so rows must not index the live path.
        let path = model.scopePath
        let levels: [SubgraphID?] = [nil] + path.map { Optional($0) }
        if !path.isEmpty {
            HStack(spacing: 6) {
                ForEach(Array(levels.enumerated()), id: \.offset) { depth, scope in
                    if depth > 0 {
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                    }
                    let isCurrent = depth == path.count
                    Button(model.scopeName(scope)) { controller.navigate(toDepth: depth) }
                        .buttonStyle(.plain)
                        .fontWeight(isCurrent ? .semibold : .regular)
                        .foregroundStyle(isCurrent ? Color.primary : Color.accentColor)
                        .disabled(isCurrent)
                        .accessibilityLabel(isCurrent ? "Editing \(model.scopeName(scope))" : "Go to \(model.scopeName(scope))")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
        }
    }
}
