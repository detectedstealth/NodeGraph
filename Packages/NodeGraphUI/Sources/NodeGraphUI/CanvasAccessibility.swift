import CoreGraphics
import NodeGraphCore
import SwiftUI

/// What a VoiceOver action does. Pure data, so the actions each element offers are tested
/// without a screen reader.
public enum AccessibilityOperation: Hashable, Sendable {
    /// Makes the element the only selection.
    case select
    /// Selects the element, then runs the command on the selection.
    case command(CanvasCommand)
    /// Opens the connection chooser for a port on the element's node.
    case connect(from: PortAddress)
}

/// One action in an element's VoiceOver actions list.
public struct AccessibilityActionSpec: Hashable, Sendable {
    public var name: String
    public var operation: AccessibilityOperation
    /// Spoken after the action runs, so a result that is not visible to the user is announced.
    public var confirmation: String?
}

/// A node, link or group as VoiceOver sees it. The canvas is one drawn view, so these stand in
/// for what it draws.
public struct AccessibilityElement: Identifiable, Hashable, Sendable {
    public enum Subject: Hashable, Sendable {
        case node(NodeID)
        case link(LinkID)
        case group(GroupID)
    }

    public var subject: Subject
    public var id: Subject { subject }
    public var label: String
    public var value: String
    /// Where the element is drawn, in the canvas view's coordinates.
    public var frame: CGRect
    public var isSelected: Bool
    public var actions: [AccessibilityActionSpec]
}

/// A port a new link from a given port could end on.
public struct ConnectionCandidate: Identifiable, Hashable, Sendable {
    public var address: PortAddress
    public var nodeTitle: String
    public var portName: String
    public var typeName: String
    public var id: PortAddress { address }
}

/// The accessible way to draw a link: pick a port, then pick one of the ports it can reach from
/// a list, instead of dragging.
public struct ConnectionRequest: Hashable, Sendable {
    public var anchor: PortAddress
    public var nodeTitle: String
    public var portName: String
    public var candidates: [ConnectionCandidate]
}

extension GraphEditorModel {
    /// The title shown for a node: its own, else its type's name.
    public func displayTitle(of node: Node) -> String {
        node.title ?? definition(of: node)?.displayName ?? node.typeID.rawValue
    }

    /// Every group, node and link as an accessibility element: nodes in reading order (top to
    /// bottom, then left to right), then links, then groups.
    public func accessibilityElements() -> [AccessibilityElement] {
        var elements: [AccessibilityElement] = []
        let nodes = graph.nodes.values.sorted {
            ($0.position.y, $0.position.x) < ($1.position.y, $1.position.x)
        }
        for node in nodes {
            guard let layout = layout(of: node.id) else { continue }
            elements.append(AccessibilityElement(
                subject: .node(node.id), label: displayTitle(of: node), value: accessibilityValue(of: node),
                frame: screenRect(layout.frame), isSelected: selection.nodes.contains(node.id),
                actions: accessibilityActions(for: node)))
        }
        for link in graph.links.values {
            guard let ends = endpoints(of: link) else { continue }
            let from = camera.screenPoint(for: ends.source), to = camera.screenPoint(for: ends.target)
            let frame = CGRect(
                x: min(from.x, to.x), y: min(from.y, to.y), width: abs(from.x - to.x), height: abs(from.y - to.y))
            let middle = GraphPoint(x: (ends.source.x + ends.target.x) / 2, y: (ends.source.y + ends.target.y) / 2)
            elements.append(AccessibilityElement(
                subject: .link(link.id), label: accessibilityLabel(of: link),
                value: link.waypoints.isEmpty ? "" : "\(link.waypoints.count) reroute points",
                frame: frame, isSelected: selection.links.contains(link.id),
                actions: [
                    AccessibilityActionSpec(name: "Select", operation: .select),
                    AccessibilityActionSpec(
                        name: "Add Reroute Point", operation: .command(.addWaypoint(link.id, at: middle)),
                        confirmation: "Reroute point added"),
                    AccessibilityActionSpec(
                        name: "Delete Link", operation: .command(.deleteSelection), confirmation: "Link deleted"),
                ]))
        }
        for group in graph.groups.values {
            elements.append(AccessibilityElement(
                subject: .group(group.id), label: group.title.isEmpty ? "Group" : group.title,
                value: "Group", frame: screenRect(group.bounds), isSelected: selection.groups.contains(group.id),
                actions: [
                    AccessibilityActionSpec(name: "Select", operation: .select),
                    AccessibilityActionSpec(
                        name: "Delete Group", operation: .command(.deleteSelection), confirmation: "Group deleted"),
                ]))
        }
        return elements
    }

    private func screenRect(_ rect: GraphRect) -> CGRect {
        let origin = camera.screenPoint(for: rect.origin)
        return CGRect(
            x: origin.x, y: origin.y, width: rect.size.width * camera.zoom, height: rect.size.height * camera.zoom)
    }

    /// "Link from Source, out to Sink, a".
    func accessibilityLabel(of link: GraphLink) -> String {
        func end(_ address: PortAddress) -> String {
            guard let node = graph.nodes[address.node] else { return "missing node" }
            let port = layout(of: address.node)?.port(address)?.definition.displayName ?? address.port.rawValue
            return "\(displayTitle(of: node)), \(port)"
        }
        return "Link from \(end(link.source)) to \(end(link.target))"
    }

    /// State worth hearing: how the node is set, how its last run went, and how its ports are wired.
    func accessibilityValue(of node: Node) -> String {
        var parts: [String] = []
        if node.mode != .always { parts.append(node.mode.menuTitle) }
        if node.isCollapsed { parts.append("Collapsed") }
        if node.isPinned { parts.append("Pinned") }
        if subgraph(of: node.id) != nil { parts.append("Subgraph") }
        if let run = runDecoration(of: node.id) {
            switch run.badge {
            case .running:
                parts.append(run.progress.map { "Running, \(Int(($0 * 100).rounded())) percent" } ?? "Running")
            case .succeeded: parts.append("Succeeded")
            case .failed: parts.append(run.message.map { "Failed: \($0)" } ?? "Failed")
            case .cancelled: parts.append("Cancelled")
            case .skipped: parts.append("Skipped")
            case .cached: parts.append("Cached")
            }
        }
        if let layout = layout(of: node.id) {
            for (title, ports) in [("Inputs", layout.inputs), ("Outputs", layout.outputs)] where !ports.isEmpty {
                let described = ports.map { port in
                    let count = port.address.direction == .input
                        ? graph.links(into: port.address).count : graph.links(from: port.address).count
                    return count == 0 ? port.definition.displayName : "\(port.definition.displayName), \(count == 1 ? "1 link" : "\(count) links")"
                }
                parts.append("\(title): " + described.joined(separator: "; "))
            }
        }
        return parts.joined(separator: ". ")
    }

    private func accessibilityActions(for node: Node) -> [AccessibilityActionSpec] {
        var actions = [AccessibilityActionSpec(name: "Select", operation: .select)]
        if !isEditable {
            if subgraph(of: node.id) != nil {
                actions.append(AccessibilityActionSpec(name: "Open Subgraph", operation: .command(.openSubgraph)))
            }
            return actions
        }
        if let layout = layout(of: node.id) {
            for port in layout.outputs + layout.inputs {
                let side = port.address.direction == .output ? "output" : "input"
                actions.append(AccessibilityActionSpec(
                    name: "Connect \(side) \(port.definition.displayName)", operation: .connect(from: port.address)))
            }
        }
        if !graph.links(attachedTo: node.id).isEmpty {
            actions.append(AccessibilityActionSpec(
                name: "Disconnect All", operation: .command(.disconnectSelection), confirmation: "Disconnected"))
        }
        if subgraph(of: node.id) != nil {
            actions.append(AccessibilityActionSpec(name: "Open Subgraph", operation: .command(.openSubgraph)))
        }
        if !node.isPinned {
            for (name, dx, dy) in [("Move Left", -1, 0), ("Move Right", 1, 0), ("Move Up", 0, -1), ("Move Down", 0, 1)] {
                actions.append(AccessibilityActionSpec(
                    name: name, operation: .command(.nudge(dx: dx, dy: dy)), confirmation: "Moved"))
            }
        }
        actions.append(AccessibilityActionSpec(
            name: node.isCollapsed ? "Expand" : "Collapse", operation: .command(.toggleCollapsed)))
        actions.append(AccessibilityActionSpec(
            name: node.isPinned ? "Unpin" : "Pin", operation: .command(.togglePinned)))
        for mode in NodeMode.allCases where mode != node.mode {
            actions.append(AccessibilityActionSpec(
                name: "Set Mode \(mode.menuTitle)", operation: .command(.setMode(mode)),
                confirmation: "Mode \(mode.menuTitle)"))
        }
        actions.append(AccessibilityActionSpec(
            name: "Duplicate", operation: .command(.duplicate), confirmation: "Duplicated"))
        actions.append(AccessibilityActionSpec(
            name: "Delete", operation: .command(.deleteSelection), confirmation: "Deleted"))
        return actions
    }

    // MARK: Connecting without dragging

    /// Starts choosing where a link from or to `anchor` goes. Returns false if the port does
    /// not exist or nothing can connect to it.
    @discardableResult
    public func beginConnection(from anchor: PortAddress) -> Bool {
        guard isEditable, let node = graph.nodes[anchor.node], let port = layout(of: anchor.node)?.port(anchor) else { return false }
        let context = ValidationContext(graph: graph, nodes: editor.nodes, types: editor.types)
        var candidates: [ConnectionCandidate] = []
        for other in graph.nodes.values where other.id != anchor.node {
            guard let layout = layout(of: other.id) else { continue }
            for candidate in anchor.direction == .output ? layout.inputs : layout.outputs {
                let proposal = ConnectionProposal(source: anchor, target: candidate.address).oriented()
                guard editor.connectionValidator.check(proposal, in: context).isAllowed else { continue }
                candidates.append(ConnectionCandidate(
                    address: candidate.address, nodeTitle: displayTitle(of: other),
                    portName: candidate.definition.displayName,
                    typeName: editor.types.info(for: candidate.definition.type)?.displayName
                        ?? candidate.definition.type.rawValue))
            }
        }
        guard !candidates.isEmpty else { return false }
        connectionRequest = ConnectionRequest(
            anchor: anchor, nodeTitle: displayTitle(of: node), portName: port.definition.displayName,
            candidates: candidates)
        return true
    }

    /// Connects the chooser's port to `target` as one undoable step and closes the chooser.
    @discardableResult
    public func completeConnection(to target: PortAddress) -> Bool {
        guard let request = connectionRequest else { return false }
        connectionRequest = nil
        return (try? connect(ConnectionProposal(source: request.anchor, target: target).oriented(), name: "Connect")) != nil
    }

    public func cancelConnection() {
        if connectionRequest != nil { connectionRequest = nil }
    }
}

extension GraphInteractionController {
    /// Runs a VoiceOver action on an element. Returns whether it did anything.
    @discardableResult
    public func perform(_ operation: AccessibilityOperation, on subject: AccessibilityElement.Subject) -> Bool {
        switch subject {
        case .node(let id): model.selection = GraphSelection(nodes: [id])
        case .link(let id): model.selection = GraphSelection(links: [id])
        case .group(let id): model.selection = GraphSelection(groups: [id])
        }
        switch operation {
        case .select: return true
        case .command(let command): return perform(command)
        case .connect(let anchor): return model.beginConnection(from: anchor)
        }
    }
}

/// Dynamic Type: how much larger or smaller than the default size the canvas draws its text.
extension GraphEditorModel {
    /// The factor for a Dynamic Type size: its body text size over the default's (17 points).
    /// Capped at 2.5, since the canvas also zooms and nodes that big stop being a graph.
    public static func textScale(for size: DynamicTypeSize) -> Double {
        let points: Double
        switch size {
        case .xSmall: points = 14
        case .small: points = 15
        case .medium: points = 16
        case .large: points = 17
        case .xLarge: points = 19
        case .xxLarge: points = 21
        case .xxxLarge: points = 23
        case .accessibility1: points = 28
        case .accessibility2: points = 33
        case .accessibility3: points = 40
        case .accessibility4: points = 47
        case .accessibility5: points = 53
        @unknown default: points = 17
        }
        return min(points / 17, 2.5)
    }
}

private struct ExposesCanvasElementsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Builds the canvas's accessibility elements even when VoiceOver is off. UI tests set this
    /// so XCUIAutomation can find nodes, links and groups; the elements are rebuilt whenever
    /// the graph or view moves, so leave it off otherwise.
    public var exposesCanvasElements: Bool {
        get { self[ExposesCanvasElementsKey.self] }
        set { self[ExposesCanvasElementsKey.self] = newValue }
    }
}

/// The accessibility stand-ins for what the canvas draws, laid out where they are drawn so
/// VoiceOver's focus ring lands on the right place.
struct AccessibilityElementsView: View {
    let controller: GraphInteractionController

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(controller.model.accessibilityElements()) { element in
                Color.clear
                    .frame(width: max(element.frame.width, 1), height: max(element.frame.height, 1))
                    .offset(x: element.frame.minX, y: element.frame.minY)
                    .accessibilityElement()
                    .accessibilityLabel(element.label)
                    .accessibilityValue(element.value)
                    .accessibilityAddTraits(element.isSelected ? [.isButton, .isSelected] : .isButton)
                    .accessibilityAction { run(.select, on: element) }
                    .accessibilityActions {
                        ForEach(element.actions.dropFirst(), id: \.name) { action in
                            Button(action.name) { run(action, on: element) }
                        }
                    }
            }
        }
    }

    private func run(_ action: AccessibilityActionSpec, on element: AccessibilityElement) {
        if controller.perform(action.operation, on: element.subject), let message = action.confirmation {
            AccessibilityNotification.Announcement(message).post()
        }
    }

    private func run(_ operation: AccessibilityOperation, on element: AccessibilityElement) {
        controller.perform(operation, on: element.subject)
    }
}
