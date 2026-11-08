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

    /// A node in a particular graph (the root, or a subgraph's inner graph).
    private struct ScopedNode: Hashable {
        var scope: SubgraphID?
        var node: NodeID
    }

    /// Nodes with automatically resized port groups whose links changed during this `apply`.
    private var resizeQueue = Set<ScopedNode>()

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
    ///
    /// - Parameter adjustsPorts: Whether to resize automatically sized port groups after the
    ///   command (see ``DynamicPortGroup/Resizing/keepOneFree``). Leave it on for new edits and for
    ///   replaying a command, which recomputes the same adjustments. Turn it off only when applying
    ///   a recorded inverse, which already contains them, so undo restores the exact earlier state.
    @discardableResult
    public func apply(
        _ command: GraphCommand, validation: EditValidation = .full, adjustsPorts: Bool = true
    ) throws -> GraphChange {
        resizeQueue.removeAll()
        var inverse: GraphCommand
        do {
            inverse = try perform(command, on: &graph, validation: validation)
        } catch {
            resizeQueue.removeAll()
            throw error
        }
        // Nodes whose links changed may now need more or fewer dynamic ports. The adjustments are
        // part of the same change, so undo takes them back together with the command.
        let adjustments = adjustsPorts ? automaticResizes() : []
        resizeQueue.removeAll()
        if !adjustments.isEmpty {
            var undo: [GraphCommand] = []
            for adjustment in adjustments { undo.append(try perform(adjustment, on: &graph, validation: .structural)) }
            inverse = .batch(commands: undo.reversed() + [inverse])
        }
        revision += 1
        let change = GraphChange(revision: revision, command: command, inverse: inverse)
        broadcaster.send(change)
        return change
    }

    /// The command that renames variable `old` to `new` and keeps every reader of it working: a
    /// batch that redeclares the variable under the new name at the same position, and sets each
    /// node property of kind ``PropertyKind/variable`` that holds `old` (in the root graph, in
    /// subgraph definitions, and on subgraph instances) to `new`. As one batch it is a single
    /// undo step and replays on a server like any other change.
    ///
    /// Apply it to the root graph only. A run's override of `old` is not carried over, since
    /// ``GraphRunner/update(graph:registry:)`` drops overrides of names the graph no longer declares.
    /// - Throws: ``GraphEditError/variableNotFound(_:)``, ``GraphEditError/invalidVariableName`` or
    ///   ``GraphEditError/duplicateVariable(_:)`` (`new` is taken by another variable).
    public func renameVariableCommand(from old: String, to new: String) throws -> GraphCommand {
        guard var variable = graph.variables[old] else { throw GraphEditError.variableNotFound(old) }
        guard GraphVariable.isValidName(new) else { throw GraphEditError.invalidVariableName }
        guard new == old || graph.variables[new] == nil else { throw GraphEditError.duplicateVariable(new) }
        variable.name = new
        var commands: [GraphCommand] = [
            .removeVariable(name: old),
            .addVariable(variable: variable, index: graph.variables.index(forKey: old)),
        ]
        func readers(in graph: Graph, scope: SubgraphID?) {
            for node in graph.nodes.values {
                guard let definition = nodes.definition(for: node) else { continue }
                for property in definition.properties where property.kind == .variable {
                    guard node.value(of: property.id, in: definition) == .string(old) else { continue }
                    let set = GraphCommand.setNodeProperty(node: node.id, property: property.id, value: .string(new))
                    commands.append(scope.map { .inSubgraph(id: $0, command: set) } ?? set)
                }
            }
        }
        readers(in: graph, scope: nil)
        for definition in subgraphs.values { readers(in: definition.graph, scope: definition.id) }
        return .batch(commands: commands)
    }

    /// Undoes a change by applying its inverse. Returns the change describing the undo; its
    /// `inverse` redoes the original.
    @discardableResult
    public func revert(_ change: GraphChange) throws -> GraphChange {
        try apply(change.inverse, validation: .structural, adjustsPorts: false)
    }

    /// The graph edited in `scope`: the root graph for nil, or a subgraph's inner graph. Nil if
    /// the subgraph does not exist.
    public func editedGraph(in scope: SubgraphID?) -> Graph? {
        guard let scope else { return graph }
        return subgraphs[scope]?.graph
    }

    /// The registries and the graph edited in `scope`, as validators see them. Nil if the
    /// subgraph does not exist.
    public func validationContext(in scope: SubgraphID?) -> ValidationContext? {
        editedGraph(in: scope).map {
            ValidationContext(graph: $0, nodes: nodes, types: types, variableNames: Set(graph.variables.keys))
        }
    }

    /// Connects two ports, removing any link a single-link port gives up, as one change.
    ///
    /// The proposal is oriented first, so it may start on either end. With `scope`, the ports
    /// are in that subgraph's inner graph.
    @discardableResult
    public func connect(_ proposal: ConnectionProposal, in scope: SubgraphID? = nil) throws -> GraphChange {
        try apply(connectCommand(for: proposal, in: scope))
    }

    /// The command that ``connect(_:in:)`` would apply, without applying it. Lets ``GraphHistory``
    /// record a connection. Throws `invalidConnection` if the rules reject the proposal, and
    /// `subgraphNotFound` if `scope` does not exist. In a scope the command is wrapped in
    /// ``GraphCommand/inSubgraph(id:command:)``.
    public func connectCommand(for proposal: ConnectionProposal, in scope: SubgraphID? = nil) throws -> GraphCommand {
        guard let context = validationContext(in: scope) else { throw GraphEditError.subgraphNotFound(scope!) }
        let proposal = proposal.oriented()
        let check = connectionValidator.check(proposal, in: context)
        guard check.isAllowed else { throw GraphEditError.invalidConnection(check.diagnostics) }
        let link = Link(
            sourceNode: proposal.source.node, sourcePort: proposal.source.port,
            targetNode: proposal.target.node, targetPort: proposal.target.port)
        let commands = check.replacedLinks.map { GraphCommand.removeLink(id: $0) }
            + [.addLink(link: link)]
        let command = commands.count == 1 ? commands[0] : .batch(commands: commands)
        return scope.map { .inSubgraph(id: $0, command: command) } ?? command
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
            for (_, link) in attached {
                graph.removeLink(link.id)
                queueResize(link.source.node, link.target.node, scope: scope, in: graph)
            }
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

        case .setPortLabel(let id, let port, let direction, let label):
            guard let node = graph.nodes[id] else { throw GraphEditError.nodeNotFound(id) }
            // A node of an unregistered type keeps whatever labels it has but takes no new ones.
            guard nodes.definition(for: node)?.port(port, direction: direction) != nil else {
                throw GraphEditError.portNotFound(node: id, port: port, direction: direction)
            }
            let key = Node.portLabelKey(port, direction: direction)
            let previous = node.portLabels[key]
            let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines)
            graph.updateNode(id) { $0.portLabels[key] = trimmed?.isEmpty == false ? trimmed : nil }
            return .setPortLabel(node: id, port: port, direction: direction, label: previous)

        case .setNodeProperty(let id, let property, let value):
            guard let node = graph.nodes[id] else { throw GraphEditError.nodeNotFound(id) }
            if validation == .full, let value {
                try validate(value, for: property, on: node)
            }
            let previous = node.properties[property]
            graph.updateNode(id) { $0.properties[property] = value }
            return .setNodeProperty(node: id, property: property, value: previous)

        case .setPortCount(let id, let group, let count):
            guard let node = graph.nodes[id] else { throw GraphEditError.nodeNotFound(id) }
            guard let declared = nodes.definition(for: node.typeID)?.dynamicPorts.first(where: { $0.id == group }) else {
                throw GraphEditError.unknownPortGroup(group)
            }
            guard count == declared.clamped(count) else {
                throw GraphEditError.portCountOutOfRange(group: group, count: count)
            }
            let oldCount = declared.clamped(node.portCounts[group])
            // Links to ports that go away go first, so undo can put them back after the ports.
            var undo: [GraphCommand] = []
            if count < oldCount {
                let gone = Set(((count + 1)...oldCount).map(declared.portID))
                for link in graph.links(attachedTo: id) {
                    let end = declared.direction == .input ? link.target : link.source
                    if end.node == id, gone.contains(end.port) {
                        let at = graph.links.index(forKey: link.id)
                        graph.removeLink(link.id)
                        undo.append(.addLink(link: link, index: at))
                    }
                }
            }
            graph.updateNode(id) {
                $0.portCounts[group] = count == declared.initialCount ? nil : count
            }
            return .batch(commands: [.setPortCount(node: id, group: group, count: oldCount)] + undo.reversed())

        case .addLink(let link, let index):
            guard graph.links[link.id] == nil else { throw GraphEditError.duplicateID(link.id.description) }
            try checkIndex(index, count: graph.links.count)
            for node in [link.source.node, link.target.node] where graph.nodes[node] == nil {
                throw GraphEditError.nodeNotFound(node)
            }
            if validation == .full { try validate(link, in: graph) }
            graph.insert(link, at: index)
            queueResize(link.source.node, link.target.node, scope: scope, in: graph)
            return .removeLink(id: link.id)

        case .removeLink(let id):
            guard let link = graph.links[id] else { throw GraphEditError.linkNotFound(id) }
            let index = graph.links.index(forKey: id)
            graph.removeLink(id)
            queueResize(link.source.node, link.target.node, scope: scope, in: graph)
            return .addLink(link: link, index: index)

        case .setLinkWaypoints(let id, let waypoints):
            guard let link = graph.links[id] else { throw GraphEditError.linkNotFound(id) }
            if validation == .full, !waypoints.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) {
                throw GraphEditError.nonFiniteValue
            }
            graph.setWaypoints(of: id, to: waypoints)
            return .setLinkWaypoints(link: id, waypoints: link.waypoints)

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

        case .addVariable(let variable, let index):
            guard scope == nil else { throw GraphEditError.invalidScope }
            guard GraphVariable.isValidName(variable.name) else { throw GraphEditError.invalidVariableName }
            guard graph.variables[variable.name] == nil else { throw GraphEditError.duplicateVariable(variable.name) }
            try checkIndex(index, count: graph.variables.count)
            graph.insert(variable, at: index)
            return .removeVariable(name: variable.name)

        case .removeVariable(let name):
            guard scope == nil else { throw GraphEditError.invalidScope }
            guard let variable = graph.variables[name] else { throw GraphEditError.variableNotFound(name) }
            let index = graph.variables.index(forKey: name)
            graph.removeVariable(name)
            return .addVariable(variable: variable, index: index)

        case .updateVariable(let variable):
            guard scope == nil else { throw GraphEditError.invalidScope }
            guard let previous = graph.variables[variable.name] else {
                throw GraphEditError.variableNotFound(variable.name)
            }
            graph.insert(variable)
            return .updateVariable(variable: previous)

        case .addSubgraph(let definition, let index):
            guard scope == nil else { throw GraphEditError.invalidScope }
            guard subgraphs[definition.id] == nil else { throw GraphEditError.duplicateID(definition.id.description) }
            try checkIndex(index, count: subgraphs.count)
            for contained in definition.directDependencies.sorted() { try checkNoLoop(placing: contained, inside: definition.id) }
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
            guard var updated = subgraphs[id] else { throw GraphEditError.subgraphNotFound(id) }
            updated.interface = interface
            let result = try replaceDefinition(updated, rootGraph: &graph, validation: validation)
            return .batch(commands: [.setSubgraphInterface(id: id, interface: result.old.interface)] + result.undo)

        case .updateSubgraph(let definition):
            guard scope == nil else { throw GraphEditError.invalidScope }
            let result = try replaceDefinition(definition, rootGraph: &graph, validation: validation)
            return .batch(commands: [.updateSubgraph(definition: result.old)] + result.undo)

        case .inSubgraph(let id, let inner):
            guard scope == nil else { throw GraphEditError.invalidScope }
            guard let at = subgraphs.index(forKey: id) else { throw GraphEditError.subgraphNotFound(id) }
            // Checked before the inner graph is borrowed for editing, while the other definitions can
            // still be read.
            for contained in instancesAdded(by: inner) { try checkNoLoop(placing: contained, inside: id) }
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

    /// The subgraphs that `command` places instances of, looking through batches.
    private func instancesAdded(by command: GraphCommand) -> [SubgraphID] {
        switch command {
        case .addNode(let node, _): node.typeID.subgraphID.map { [$0] } ?? []
        case .batch(let commands): commands.flatMap(instancesAdded)
        default: []
        }
    }

    /// Refuses to put an instance of `contained` inside `container` if that would make a subgraph
    /// contain itself: `contained` is `container`, or already contains an instance of it somewhere
    /// below.
    private func checkNoLoop(placing contained: SubgraphID, inside container: SubgraphID) throws {
        if contained == container { throw GraphEditError.recursiveSubgraph([container, container]) }
        var visited = Set<SubgraphID>()
        func path(from id: SubgraphID) -> [SubgraphID]? {
            guard visited.insert(id).inserted, let definition = subgraphs[id] else { return nil }
            for next in definition.directDependencies.sorted() {
                if next == container { return [id, next] }
                if let rest = path(from: next) { return [id] + rest }
            }
            return nil
        }
        if let route = path(from: contained) { throw GraphEditError.recursiveSubgraph([container] + route) }
    }

    /// Remembers nodes whose automatically resized port groups may need adjusting after this command.
    private func queueResize(_ nodeIDs: NodeID..., scope: SubgraphID?, in graph: Graph) {
        for id in nodeIDs {
            guard let node = graph.nodes[id],
                  nodes.definition(for: node.typeID)?.dynamicPorts.contains(where: { $0.resizing == .keepOneFree }) == true
            else { continue }
            resizeQueue.insert(ScopedNode(scope: scope, node: id))
        }
    }

    /// The `setPortCount` commands that leave every queued node with exactly one free port at the
    /// end of each automatically resized group, within the group's limits.
    private func automaticResizes() -> [GraphCommand] {
        var commands: [GraphCommand] = []
        let queued = resizeQueue.sorted { ($0.scope?.description ?? "", $0.node) < ($1.scope?.description ?? "", $1.node) }
        for entry in queued {
            let graph = entry.scope.flatMap { subgraphs[$0]?.graph } ?? self.graph
            guard entry.scope == nil || subgraphs[entry.scope!] != nil,
                  let node = graph.nodes[entry.node],
                  let definition = nodes.definition(for: node.typeID) else { continue }
            for group in definition.dynamicPorts where group.resizing == .keepOneFree {
                let current = group.clamped(node.portCounts[group.id])
                var highestLinked = 0
                for n in stride(from: current, through: 1, by: -1) {
                    let address = PortAddress(node: node.id, port: group.portID(n), direction: group.direction)
                    let linked = group.direction == .input
                        ? !graph.links(into: address).isEmpty : !graph.links(from: address).isEmpty
                    if linked { highestLinked = n; break }
                }
                let wanted = group.clamped(max(highestLinked + 1, group.initialCount))
                if wanted != current {
                    let command = GraphCommand.setPortCount(node: node.id, group: group.id, count: wanted)
                    commands.append(entry.scope.map { .inSubgraph(id: $0, command: command) } ?? command)
                }
            }
        }
        return commands
    }

    /// Everything wrong with a definition that is about to be added or changed.
    private func validate(_ definition: SubgraphDefinition) throws {
        var problems = definition.problems(nodes: nodes)
        let context = ValidationContext(graph: definition.graph, nodes: nodes, types: types)
        problems += GraphValidator(connections: connectionValidator).validate(context)
            .filter { $0.severity == .error }.map(\.message)
        guard problems.isEmpty else { throw GraphEditError.invalidSubgraph(problems) }
    }

    /// Replaces a subgraph definition (interface, inner graph and origin) and removes what
    /// instances can no longer have: links to ports that are gone or changed kind, and values of
    /// properties that are gone. Returns the definition it replaced and the commands that put the
    /// removed links and values back.
    private func replaceDefinition(
        _ updated: SubgraphDefinition, rootGraph: inout Graph, validation: EditValidation
    ) throws -> (old: SubgraphDefinition, undo: [GraphCommand]) {
        guard let at = subgraphs.index(forKey: updated.id) else { throw GraphEditError.subgraphNotFound(updated.id) }
        let old = subgraphs.values[at]
        for contained in updated.directDependencies.sorted() { try checkNoLoop(placing: contained, inside: updated.id) }
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
        return (old, undo)
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
