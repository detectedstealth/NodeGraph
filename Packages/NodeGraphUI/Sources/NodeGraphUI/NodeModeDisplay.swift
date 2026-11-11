import NodeGraphCore

/// How the canvas shows a node's ``NodeMode``: a mark on the title, the text for hover and the
/// inspector, and how links leaving the node are drawn. Kept apart from drawing so the mapping
/// is testable.
struct NodeModeDisplay: Equatable {
    /// The mark drawn at the right of the title bar.
    enum Mark: Equatable {
        /// A circle with a bar through it: switched off.
        case off
        /// A speaker with a slash: runs nothing and publishes nothing.
        case muted
        /// An arrow straight through: passes inputs to outputs.
        case bypass
        /// A bolt: runs only when a trigger fires.
        case trigger
    }

    var mark: Mark
    /// Whether the node is drawn faded. `onTrigger` nodes do run, so they are not.
    var isFaded: Bool
    /// Whether links leaving the node are drawn dashed and faded: nothing flows along them.
    var dimsOutgoingLinks: Bool

    /// Nil for `always`, which needs no mark.
    init?(_ mode: NodeMode) {
        switch mode {
        case .always: return nil
        case .never: self.init(mark: .off, isFaded: true, dimsOutgoingLinks: true)
        case .muted: self.init(mark: .muted, isFaded: true, dimsOutgoingLinks: true)
        case .bypassed: self.init(mark: .bypass, isFaded: true, dimsOutgoingLinks: false)
        case .onTrigger: self.init(mark: .trigger, isFaded: false, dimsOutgoingLinks: false)
        }
    }

    private init(mark: Mark, isFaded: Bool, dimsOutgoingLinks: Bool) {
        self.mark = mark
        self.isFaded = isFaded
        self.dimsOutgoingLinks = dimsOutgoingLinks
    }
}

extension NodeMode {
    /// What the mode does to the node and to the nodes around it, for hover and the inspector.
    var effectSummary: String {
        switch self {
        case .always: "Runs every evaluation."
        case .never: "Switched off. Nodes that depend on it are skipped too."
        case .muted: "Does not run and publishes nothing. Nodes after it still run, with those inputs unlinked."
        case .bypassed: "Does not run. Its inputs pass straight through to its outputs."
        case .onTrigger: "Runs only when a trigger input fires, and keeps its last outputs in between."
        }
    }

    /// The mode a quick toggle sets: `mode` itself, or back to `always` if every node already has it.
    static func toggled(_ mode: NodeMode, among current: some Collection<NodeMode>) -> NodeMode {
        !current.isEmpty && current.allSatisfy({ $0 == mode }) ? .always : mode
    }
}

extension GraphEditorModel {
    /// Whether a link is drawn as carrying nothing, because the node it leaves is off or muted.
    func isLinkInactive(_ link: GraphLink) -> Bool {
        guard let node = graph.nodes[link.source.node], let display = NodeModeDisplay(node.mode) else { return false }
        return display.dimsOutgoingLinks
    }
}
