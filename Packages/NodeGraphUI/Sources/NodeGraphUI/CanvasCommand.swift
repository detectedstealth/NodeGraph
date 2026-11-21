#if !os(tvOS) && !os(watchOS)
import CoreGraphics
import NodeGraphCore

/// An action on the canvas that a key, a menu item or a button can trigger. Pure data, so key
/// maps and menus are tested without any UI.
public enum CanvasCommand: Hashable, Sendable {
    case selectAll
    /// Cancels a drag in progress, otherwise clears the selection.
    case escape
    case deleteSelection
    /// Deletes the selection, but joins what fed each selected node to what it fed, where the
    /// connection rules allow.
    case deleteAndReconnect
    /// Moves the selection by whole grid cells (`dx`, `dy` in cells, usually -1, 0 or 1; times
    /// ten with Shift).
    case nudge(dx: Int, dy: Int)
    case zoomToFit
    case resetZoom
    case zoomIn
    case zoomOut
    case toggleSnapToGrid
    /// Shows or hides an arrowhead on each link.
    case toggleLinkArrows
    /// Shows or hides each node's place in the run order.
    case toggleExecutionOrder
    /// Shows or hides the stats panel.
    case toggleStats
    /// Sends a PNG of the whole graph to ``GraphEditorModel/onExportImage``.
    case exportImage
    /// Copies the selection (and the contents of selected groups) to the clipboard.
    case copy
    /// Copies, then removes.
    case cut
    /// Pastes the clipboard, centered on a graph-space point, or on the pointer when nil.
    case paste(at: GraphPoint?)
    /// Pastes like ``paste(at:)``, and links each pasted node again to the nodes outside the copy
    /// that fed the original, where they still exist and the rules allow it.
    case pasteWithConnections(at: GraphPoint?)
    /// Makes a copy of the selection a little way off, without touching the clipboard.
    case duplicate
    /// Lines the selected nodes up on an edge or center of the box around them.
    case align(AlignEdge)
    /// Spaces three or more selected nodes evenly.
    case distribute(DistributeAxis)
    /// Lays the selection out in columns by data flow, or every node when fewer than two are selected.
    case autoArrange
    /// Adds a group around the selected nodes.
    case groupSelection
    /// Adds an empty group centered on a graph-space point.
    case addGroup(at: GraphPoint)
    /// Opens the Create Subgraph form for the selected nodes.
    case createSubgraph
    /// Replaces the selected subgraph instance with the nodes inside it.
    case unpackSubgraph
    /// Opens the subgraph the single selected node is an instance of, to edit inside it.
    case openSubgraph
    /// Goes back out of the subgraph being edited.
    case leaveSubgraph
    /// Opens the add-node search at a graph-space position, or at the pointer when nil.
    case addNode(at: GraphPoint?)
    /// Adds the default node for a port's type beside it, linked to it.
    case addDefaultNode(for: PortAddress)
    /// Opens the editor over a port to give it another name on this node.
    case renamePort(PortAddress)
    /// Collapses the selected nodes, or expands them if all are already collapsed.
    case toggleCollapsed
    /// Pins the selected nodes, or unpins them if all are already pinned.
    case togglePinned
    case setMode(NodeMode)
    /// Sets the mode on the selected nodes, or back to `always` if they all have it already.
    case toggleMode(NodeMode)
    /// Sets the outline of the selected nodes.
    case setShape(NodeShape)
    /// Sets how the selected nodes' title bars are shown.
    case setTitleMode(NodeTitleMode)
    /// Removes every link attached to the selected nodes.
    case disconnectSelection
    /// Adds a reroute point on a link at a graph-space position.
    case addWaypoint(LinkID, at: GraphPoint)
}

extension CanvasCommand {
    /// Whether the command changes the graph. A read-only canvas (``GraphEditorModel/isEditable``
    /// false) refuses these and keeps the rest: selecting, copying, zooming and navigating.
    public var isEdit: Bool {
        switch self {
        case .deleteSelection, .deleteAndReconnect, .nudge, .cut, .paste, .pasteWithConnections, .duplicate, .align, .distribute, .autoArrange, .groupSelection, .addGroup, .createSubgraph,
             .unpackSubgraph, .addNode, .addDefaultNode, .renamePort, .toggleCollapsed, .togglePinned, .setMode, .toggleMode, .setShape, .setTitleMode,
             .disconnectSelection,
             .addWaypoint:
            true
        case .selectAll, .escape, .zoomToFit, .resetZoom, .zoomIn, .zoomOut, .toggleSnapToGrid, .toggleLinkArrows,
             .toggleExecutionOrder, .toggleStats, .exportImage, .copy,
             .openSubgraph, .leaveSubgraph:
            false
        }
    }
}

/// A key as the canvas understands it. The view converts platform key events into this.
public enum CanvasKey: Hashable, Sendable {
    case delete
    case escape
    case `return`
    case left, right, up, down
    case character(Character)
}

/// Which key does what.
public enum CanvasKeyMap {
    /// The command for a key press, or nil if the canvas does not use it.
    public static func command(for key: CanvasKey, modifiers: InputModifiers) -> CanvasCommand? {
        let step = modifiers.contains(.shift) ? 10 : 1
        switch key {
        case .delete: return modifiers.contains(.shift) ? .deleteAndReconnect : .deleteSelection
        case .escape: return .escape
        case .return: return .openSubgraph
        case .left: return .nudge(dx: -step, dy: 0)
        case .right: return .nudge(dx: step, dy: 0)
        case .up: return .nudge(dx: 0, dy: -step)
        case .down: return .nudge(dx: 0, dy: step)
        case .character(let character):
            let commandKey = modifiers.contains(.command)
            switch character.lowercased() {
            case "g" where modifiers.contains([.command, .option]): return .groupSelection
            case "a" where commandKey: return .selectAll
            case "c" where commandKey: return .copy
            case "x" where commandKey: return .cut
            case "v" where commandKey && modifiers.contains(.shift): return .pasteWithConnections(at: nil)
            case "v" where commandKey: return .paste(at: nil)
            case "d" where commandKey: return .duplicate
            case "g" where commandKey && modifiers.contains(.shift): return .unpackSubgraph
            case "g" where commandKey: return .createSubgraph
            case "0" where commandKey: return .resetZoom
            case "=" where commandKey, "+" where commandKey: return .zoomIn
            case "-" where commandKey: return .zoomOut
            case "[" where commandKey: return .leaveSubgraph
            case "m" where modifiers.isEmpty: return .toggleMode(.muted)
            case "b" where modifiers.isEmpty: return .toggleMode(.bypassed)
            case "d" where modifiers.isEmpty: return .toggleMode(.never)
            case "a" where modifiers == .shift: return .addNode(at: nil)
            case "f" where modifiers.isDisjoint(with: [.command, .control, .option]): return .zoomToFit
            default: return nil
            }
        }
    }
}

/// One entry of a context menu.
public struct CanvasMenuItem: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case command(CanvasCommand)
        case submenu([CanvasMenuItem])
        case separator
    }

    public var title: String
    public var kind: Kind
    public var isEnabled: Bool
    public var isChecked: Bool

    public init(_ title: String, _ command: CanvasCommand, isEnabled: Bool = true, isChecked: Bool = false) {
        self.title = title
        self.kind = .command(command)
        self.isEnabled = isEnabled
        self.isChecked = isChecked
    }

    public init(_ title: String, submenu: [CanvasMenuItem], isEnabled: Bool = true) {
        self.title = title
        self.kind = .submenu(submenu)
        self.isEnabled = isEnabled
        self.isChecked = false
    }

    public static let separator = CanvasMenuItem(separatorOnly: ())

    /// The items with every edit disabled, and any submenu left with nothing to do disabled too.
    func disablingEdits() -> CanvasMenuItem {
        var item = self
        switch kind {
        case .command(let command):
            if command.isEdit { item.isEnabled = false }
        case .submenu(let items):
            let remaining = items.map { $0.disablingEdits() }
            item.kind = .submenu(remaining)
            if !remaining.contains(where: \.isEnabled) { item.isEnabled = false }
        case .separator:
            break
        }
        return item
    }

    private init(separatorOnly: ()) {
        title = ""
        kind = .separator
        isEnabled = false
        isChecked = false
    }
}
#endif
