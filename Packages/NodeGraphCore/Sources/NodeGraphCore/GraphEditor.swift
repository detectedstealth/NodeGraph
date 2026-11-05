import Collections
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
    /// Subgraph definitions, in storage order. Edit them with the subgraph commands.
    public private(set) var subgraphs: OrderedDictionary<SubgraphID, SubgraphDefinition>
    /// Increments once per applied top-level command.
    public private(set) var revision: Int
    public var nodes: NodeRegistry
    public var types: TypeRegistry
    public var connectionValidator: ConnectionValidator

    private let broadcaster = Broadcaster<GraphChange>()

    public init(
        graph: Graph = Graph(),
        subgraphs: [SubgraphDefinition] = [],
        revision: Int = 0,
        nodes: NodeRegistry,
        types: TypeRegistry,
        connectionValidator: ConnectionValidator = ConnectionValidator()
    ) {
        self.graph = graph
        self.subgraphs = OrderedDictionary(subgraphs.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        self.revision = revision
        self.nodes = nodes
        self.types = types
        self.connectionValidator = connectionValidator
        refreshSubgraphTypes()
    }

    /// Opens a saved document for editing.
    public convenience init(
        document: GraphDocument,
        nodes: NodeRegistry,
        types: TypeRegistry,
        connectionValidator: ConnectionValidator = ConnectionValidator()
    ) {
        self.init(
            graph: document.graph, subgraphs: document.subgraphs, nodes: nodes, types: types,
            connectionValidator: connectionValidator)
    }

    /// The current state as a document, ready to save.
    public func makeDocument(metadata: [String: GraphValue] = [:]) -> GraphDocument {
        GraphDocument(graph: graph, subgraphs: Array(subgraphs.values), metadata: metadata)
    }

    /// Registers the node type of every subgraph so instances can be created, linked and
    /// validated. Done automatically; call it after replacing ``nodes`` with a new registry.
    /// Executors already registered for these types are kept.
    public func refreshSubgraphTypes() {
        for definition in subgraphs.values { registerType(of: definition) }
    }

    private func registerType(of definition: SubgraphDefinition) {
        nodes.register(definition.nodeDefinition, execute: nodes.executor(for: definition.typeID))
    }

    /// The registries and graph as validators see them.
    public var validationContext: ValidationContext {
        ValidationContext(graph: graph, nodes: nodes, types: types)
    }

    /// Applies `command` atomically. On failure the graph, revision and streams are untouched.
    ///
    /// Cost does not grow with the size of the graph for single commands: they check before they
    /// change anything. A batch that fails part-way is rolled back with the inverses of the steps
    /// that had succeeded.
    @discardableResult
    public func apply(_ command: GraphCommand, validation: EditValidation = .full) throws -> GraphChange {
        let inverse = try perform(command, on: &graph, validation: validation)
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
    ///
    /// `scope` is the subgraph whose inner graph `graph` is, or nil for the root graph.
    private func perform(
        _ command: GraphCommand, on graph: inout Graph, scope: SubgraphID? = nil, validation: EditValidation
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
            let attached = graph.links(attachedTo: id)
                .compactMap { link in graph.links.index(forKey: link.id).map { (index: $0, link: link) } }
                .sorted { $0.index < $1.index }
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

        case .addSubgraph(let definition, let index):
            guard scope == nil else { throw GraphEditError.invalidScope }
            guard subgraphs[definition.id] == nil else { throw GraphEditError.duplicateID(definition.id.description) }
            try checkIndex(index, count: subgraphs.count)
            if validation == .full { try validate(definition) }
            if let index {
                subgraphs.updateValue(definition, forKey: definition.id, insertingAt: index)
            } else {
                subgraphs[definition.id] = definition
            }
            registerType(of: definition)
            return .removeSubgraph(id: definition.id)

        case .removeSubgraph(let id):
            guard scope == nil else { throw GraphEditError.invalidScope }
            guard let definition = subgraphs[id] else { throw GraphEditError.subgraphNotFound(id) }
            let inUse = graph.nodes.values.contains { $0.typeID == definition.typeID }
                || subgraphs.values.contains { $0.graph.nodes.values.contains { $0.typeID == definition.typeID } }
            guard !inUse else { throw GraphEditError.subgraphInUse(id) }
            let index = subgraphs.index(forKey: id)
            subgraphs.removeValue(forKey: id)
            nodes.unregister(definition.typeID)
            return .addSubgraph(definition: definition, index: index)

        case .setSubgraphInterface(let id, let interface):
            guard scope == nil else { throw GraphEditError.invalidScope }
            return try setInterface(of: id, to: interface, rootGraph: &graph, validation: validation)

        case .inSubgraph(let id, let inner):
            guard scope == nil else { throw GraphEditError.invalidScope }
            guard let at = subgraphs.index(forKey: id) else { throw GraphEditError.subgraphNotFound(id) }
            let inverse = try perform(inner, on: &subgraphs.values[at].graph, scope: id, validation: validation)
            return .inSubgraph(id: id, command: inverse)

        case .batch(let commands):
            var inverses: [GraphCommand] = []
            do {
                for command in commands {
                    inverses.append(try perform(command, on: &graph, scope: scope, validation: validation))
                }
            } catch {
                // Put back what the earlier steps changed. Inverses restore exactly, so this
                // cannot fail on a graph the steps just produced.
                for inverse in inverses.reversed() {
                    _ = try? perform(inverse, on: &graph, scope: scope, validation: .structural)
                }
                throw error
            }
            return .batch(commands: inverses.reversed())
        }
    }

    /// Everything wrong with a definition that is about to be added or changed.
    private func validate(_ definition: SubgraphDefinition) throws {
        var problems = definition.problems(nodes: nodes)
        let context = ValidationContext(graph: definition.graph, nodes: nodes, types: types)
        problems += GraphValidator(connections: connectionValidator).validate(context)
            .filter { $0.severity == .error }.map(\.message)
        guard problems.isEmpty else { throw GraphEditError.invalidSubgraph(problems) }
    }

    /// Replaces a subgraph's interface and removes what instances can no longer have: links to
    /// ports that are gone or changed kind, and values of properties that are gone. Returns the
    /// command that undoes all of it.
    private func setInterface(
        of id: SubgraphID, to interface: SubgraphInterface, rootGraph: inout Graph, validation: EditValidation
    ) throws -> GraphCommand {
        guard let at = subgraphs.index(forKey: id) else { throw GraphEditError.subgraphNotFound(id) }
        let old = subgraphs.values[at]
        var updated = old
        updated.interface = interface
        if validation == .full { try validate(updated) }

        let typeID = old.typeID, newDefinition = updated.nodeDefinition, oldDefinition = old.nodeDefinition
        func cleanup(in graph: Graph) -> [GraphCommand] {
            var commands: [GraphCommand] = []
            var removed = Set<LinkID>()
            for node in graph.nodes.values where node.typeID == typeID {
                func broken(_ address: PortAddress) -> Bool {
                    guard let port = newDefinition.port(address.port, direction: address.direction) else { return true }
                    return oldDefinition.port(address.port, direction: address.direction)?.kind != port.kind
                }
                for link in graph.links(attachedTo: node.id) where !removed.contains(link.id) {
                    let sourceBroken = link.source.node == node.id && broken(link.source)
                    let targetBroken = link.target.node == node.id && broken(link.target)
                    if sourceBroken || targetBroken {
                        removed.insert(link.id)
                        commands.append(.removeLink(id: link.id))
                    }
                }
                for property in node.properties.keys.sorted() where newDefinition.property(property) == nil {
                    commands.append(.setNodeProperty(node: node.id, property: property, value: nil))
                }
            }
            return commands
        }

        // Clean up the root graph and every subgraph that contains instances.
        var undo: [GraphCommand] = []
        let rootCleanup = cleanup(in: rootGraph)
        if !rootCleanup.isEmpty {
            undo.append(try perform(.batch(commands: rootCleanup), on: &rootGraph, validation: .structural))
        }
        for index in subgraphs.values.indices {
            let otherID = subgraphs.values[index].id
            let commands = cleanup(in: subgraphs.values[index].graph)
            guard !commands.isEmpty else { continue }
            let inverse = try perform(
                .batch(commands: commands), on: &subgraphs.values[index].graph, scope: otherID, validation: .structural)
            undo.append(.inSubgraph(id: otherID, command: inverse))
        }

        subgraphs.values[at] = updated
        registerType(of: updated)
        return .batch(commands: [.setSubgraphInterface(id: id, interface: old.interface)] + undo)
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
