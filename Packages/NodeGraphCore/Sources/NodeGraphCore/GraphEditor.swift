import Foundation
import Synchronization

/// How strictly ``GraphEditor`` checks a command.
public enum EditValidation: Sendable {
    /// Checks structure plus registered node types, property values and connection rules.
    /// Use for new edits from users, tools, and generators.
    case full
    /// Checks only that referenced nodes, links and groups exist. Use to replay a command
    /// that was already validated, such as undo, redo, and a server's change log.
    case structural
}

/// The only way to change a graph. Applies ``GraphCommand``s, returns the inverse of each for
/// undo, and publishes every change on a stream.
///
/// Not `Sendable`: own it from one actor (the UI model on the main actor, a runner on its
/// own). The streams returned by ``changes()`` can be consumed from anywhere.
public final class GraphEditor {
    public private(set) var graph: Graph
    /// Increments once per applied top-level command.
    public private(set) var revision: Int
    public var nodes: NodeRegistry
    public var types: TypeRegistry
    public var connectionValidator: ConnectionValidator

    private let broadcaster = Broadcaster<GraphChange>()

    public init(
        graph: Graph = Graph(),
        revision: Int = 0,
        nodes: NodeRegistry,
        types: TypeRegistry,
        connectionValidator: ConnectionValidator = ConnectionValidator()
    ) {
        self.graph = graph
        self.revision = revision
        self.nodes = nodes
        self.types = types
        self.connectionValidator = connectionValidator
    }

    /// The registries and graph as validators see them.
    public var validationContext: ValidationContext {
        ValidationContext(graph: graph, nodes: nodes, types: types)
    }

    /// Applies `command` atomically. On failure the graph, revision and streams are untouched.
    @discardableResult
    public func apply(_ command: GraphCommand, validation: EditValidation = .full) throws -> GraphChange {
        var working = graph
        let inverse = try perform(command, on: &working, validation: validation)
        graph = working
        revision += 1
        let change = GraphChange(revision: revision, command: command, inverse: inverse)
        broadcaster.send(change)
        return change
    }

    /// Undoes a change by applying its inverse. Returns the change describing the undo; its
    /// `inverse` redoes the original.
    @discardableResult
    public func revert(_ change: GraphChange) throws -> GraphChange {
        try apply(change.inverse, validation: .structural)
    }

    /// Connects two ports, removing any link a single-link port gives up, as one change.
    ///
    /// The proposal is oriented first, so it may start on either end.
    @discardableResult
    public func connect(_ proposal: ConnectionProposal) throws -> GraphChange {
        try apply(connectCommand(for: proposal))
    }

    /// The command that ``connect(_:)`` would apply, without applying it. Lets ``GraphHistory``
    /// record a connection. Throws `invalidConnection` if the rules reject the proposal.
    public func connectCommand(for proposal: ConnectionProposal) throws -> GraphCommand {
        let proposal = proposal.oriented()
        let check = connectionValidator.check(proposal, in: validationContext)
        guard check.isAllowed else { throw GraphEditError.invalidConnection(check.diagnostics) }
        let link = Link(
            sourceNode: proposal.source.node, sourcePort: proposal.source.port,
            targetNode: proposal.target.node, targetPort: proposal.target.port)
        let commands = check.replacedLinks.map { GraphCommand.removeLink(id: $0) }
            + [.addLink(link: link)]
        return commands.count == 1 ? commands[0] : .batch(commands: commands)
    }

    /// A new stream of every change applied from now on. Each call returns an independent stream.
    public func changes() -> AsyncStream<GraphChange> {
        broadcaster.stream()
    }

    // MARK: Applying commands

    /// Applies `command` to `graph` and returns its inverse.
    private func perform(
        _ command: GraphCommand, on graph: inout Graph, validation: EditValidation
    ) throws -> GraphCommand {
        switch command {
        case .addNode(let node, let index):
            guard graph.nodes[node.id] == nil else { throw GraphEditError.duplicateID(node.id.description) }
            try checkIndex(index, count: graph.nodes.count)
            if validation == .full { try validate(node) }
            graph.insert(node, at: index)
            return .removeNode(id: node.id)

        case .removeNode(let id):
            guard let node = graph.nodes[id] else { throw GraphEditError.nodeNotFound(id) }
            let nodeIndex = graph.nodes.index(forKey: id)
            // Links go first, ascending, so re-adding them in order restores their positions.
            let attached = graph.links.enumerated()
                .filter { $0.element.value.touches(id) }
                .map { (index: $0.offset, link: $0.element.value) }
            for (_, link) in attached { graph.removeLink(link.id) }
            graph.removeNode(id)
            return .batch(commands: [.addNode(node: node, index: nodeIndex)]
                + attached.map { .addLink(link: $0.link, index: $0.index) })

        case .setNodePositions(let placements):
            var previous: [NodePlacement] = []
            for placement in placements {
                guard let node = graph.nodes[placement.node] else {
                    throw GraphEditError.nodeNotFound(placement.node)
                }
                if validation == .full, !(placement.position.x.isFinite && placement.position.y.isFinite) {
                    throw GraphEditError.nonFiniteValue
                }
                previous.append(NodePlacement(node: node.id, position: node.position))
            }
            for placement in placements {
                graph.updateNode(placement.node) { $0.position = placement.position }
            }
            return .setNodePositions(placements: previous)

        case .setNodeAttribute(let id, let attribute):
            guard let node = graph.nodes[id] else { throw GraphEditError.nodeNotFound(id) }
            let previous = attribute.current(in: node)
            graph.updateNode(id) { attribute.apply(to: &$0) }
            return .setNodeAttribute(node: id, attribute: previous)

        case .setNodeProperty(let id, let property, let value):
            guard let node = graph.nodes[id] else { throw GraphEditError.nodeNotFound(id) }
            if validation == .full, let value {
                try validate(value, for: property, on: node)
            }
            let previous = node.properties[property]
            graph.updateNode(id) { $0.properties[property] = value }
            return .setNodeProperty(node: id, property: property, value: previous)

        case .addLink(let link, let index):
            guard graph.links[link.id] == nil else { throw GraphEditError.duplicateID(link.id.description) }
            try checkIndex(index, count: graph.links.count)
            for node in [link.source.node, link.target.node] where graph.nodes[node] == nil {
                throw GraphEditError.nodeNotFound(node)
            }
            if validation == .full { try validate(link, in: graph) }
            graph.insert(link, at: index)
            return .removeLink(id: link.id)

        case .removeLink(let id):
            guard let link = graph.links[id] else { throw GraphEditError.linkNotFound(id) }
            let index = graph.links.index(forKey: id)
            graph.removeLink(id)
            return .addLink(link: link, index: index)

        case .addGroup(let group, let index):
            guard graph.groups[group.id] == nil else { throw GraphEditError.duplicateID(group.id.description) }
            try checkIndex(index, count: graph.groups.count)
            if validation == .full { try validate(group.bounds) }
            graph.insert(group, at: index)
            return .removeGroup(id: group.id)

        case .removeGroup(let id):
            guard let group = graph.groups[id] else { throw GraphEditError.groupNotFound(id) }
            let index = graph.groups.index(forKey: id)
            graph.removeGroup(id)
            return .addGroup(group: group, index: index)

        case .updateGroup(let group):
            guard let previous = graph.groups[group.id] else { throw GraphEditError.groupNotFound(group.id) }
            if validation == .full { try validate(group.bounds) }
            graph.insert(group)
            return .updateGroup(group: previous)

        case .batch(let commands):
            var inverses: [GraphCommand] = []
            for command in commands {
                inverses.append(try perform(command, on: &graph, validation: validation))
            }
            return .batch(commands: inverses.reversed())
        }
    }

    private func checkIndex(_ index: Int?, count: Int) throws {
        if let index, !(0...count).contains(index) { throw GraphEditError.indexOutOfRange(index) }
    }

    private func validate(_ bounds: GraphRect) throws {
        let values = [bounds.origin.x, bounds.origin.y, bounds.size.width, bounds.size.height]
        guard values.allSatisfy(\.isFinite), bounds.size.width > 0, bounds.size.height > 0 else {
            throw GraphEditError.invalidGeometry
        }
    }

    private func validate(_ node: Node) throws {
        guard let definition = nodes.definition(for: node.typeID) else {
            throw GraphEditError.unknownNodeType(node.typeID)
        }
        for (id, value) in node.properties.sorted(by: { $0.key < $1.key }) {
            guard let property = definition.property(id) else { throw GraphEditError.unknownProperty(id) }
            do { try property.validate(value) } catch let error as PropertyValidationError {
                throw GraphEditError.invalidProperty(id, error)
            }
        }
    }

    private func validate(_ value: GraphValue, for id: PropertyID, on node: Node) throws {
        guard let definition = nodes.definition(for: node.typeID) else {
            throw GraphEditError.unknownNodeType(node.typeID)
        }
        guard let property = definition.property(id) else { throw GraphEditError.unknownProperty(id) }
        do { try property.validate(value) } catch let error as PropertyValidationError {
            throw GraphEditError.invalidProperty(id, error)
        }
    }

    /// Checks a link against the connection rules. A link that would displace another is
    /// rejected here; ``connect(_:)`` removes the displaced link in the same batch first.
    private func validate(_ link: Link, in graph: Graph) throws {
        let context = ValidationContext(graph: graph, nodes: nodes, types: types)
        let check = connectionValidator.check(
            ConnectionProposal(source: link.source, target: link.target), in: context)
        var diagnostics = check.diagnostics
        if check.isAllowed, !check.replacedLinks.isEmpty {
            diagnostics.append(GraphDiagnostic(
                code: .tooManyLinks,
                message: "The port already has a link; remove it first or use connect(_:).",
                node: link.target.node, port: link.target))
        }
        if diagnostics.containsErrors { throw GraphEditError.invalidConnection(diagnostics) }
    }
}
