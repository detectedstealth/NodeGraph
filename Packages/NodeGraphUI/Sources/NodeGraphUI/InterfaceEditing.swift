import Foundation
import NodeGraphCore

/// Editing the interface of the subgraph being edited: its name and category, and which inner
/// ports and properties are exposed on its instances, in what order, and under what names.
///
/// Each edit replaces the interface with `setSubgraphInterface`, so Core keeps links and values
/// on instances in step: renaming and reordering touch nothing outside, and removing an entry
/// drops only the links and values that belonged to it. Each is one undoable step.
extension GraphEditorModel {
    // MARK: Name and category

    /// Renames the subgraph being edited. A blank name is refused.
    @discardableResult
    public func renameSubgraph(to name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return editInterface("Rename Subgraph") { $0.name = trimmed }
    }

    @discardableResult
    public func setSubgraphCategory(_ category: String) -> Bool {
        let trimmed = category.trimmingCharacters(in: .whitespacesAndNewlines)
        return editInterface("Set Category") { $0.category = trimmed.isEmpty ? "Subgraph" : trimmed }
    }

    // MARK: Renaming

    @discardableResult
    public func renameInput(_ id: PortID, to name: String) -> Bool {
        guard !name.isEmpty else { return false }
        return tryEditInterface("Rename Input") { interface in
            guard let index = interface.inputs.firstIndex(where: { $0.id == id }) else { return false }
            interface.inputs[index].displayName = name
            return true
        }
    }

    @discardableResult
    public func renameOutput(_ id: PortID, to name: String) -> Bool {
        guard !name.isEmpty else { return false }
        return tryEditInterface("Rename Output") { interface in
            guard let index = interface.outputs.firstIndex(where: { $0.id == id }) else { return false }
            interface.outputs[index].displayName = name
            return true
        }
    }

    @discardableResult
    public func renameProperty(_ id: PropertyID, to name: String) -> Bool {
        guard !name.isEmpty else { return false }
        return tryEditInterface("Rename Property") { interface in
            guard let index = interface.properties.firstIndex(where: { $0.id == id }) else { return false }
            interface.properties[index].displayName = name
            return true
        }
    }

    // MARK: Removing and reordering

    /// Removes an exposed input. Links into it on instances are removed too.
    @discardableResult
    public func removeInput(_ id: PortID) -> Bool {
        editInterface("Remove Input") { $0.inputs.removeAll { $0.id == id } }
    }

    @discardableResult
    public func removeOutput(_ id: PortID) -> Bool {
        editInterface("Remove Output") { $0.outputs.removeAll { $0.id == id } }
    }

    /// Removes an exposed property. Values set on instances are dropped.
    @discardableResult
    public func removeProperty(_ id: PropertyID) -> Bool {
        editInterface("Remove Property") { $0.properties.removeAll { $0.id == id } }
    }

    /// Moves an exposed input up (negative) or down (positive) the list, which is the order its
    /// port appears on instances.
    @discardableResult
    public func moveInput(_ id: PortID, by offset: Int) -> Bool {
        tryEditInterface("Reorder Inputs") { Self.move(&$0.inputs, where: { $0.id == id }, by: offset) }
    }

    @discardableResult
    public func moveOutput(_ id: PortID, by offset: Int) -> Bool {
        tryEditInterface("Reorder Outputs") { Self.move(&$0.outputs, where: { $0.id == id }, by: offset) }
    }

    @discardableResult
    public func moveProperty(_ id: PropertyID, by offset: Int) -> Bool {
        tryEditInterface("Reorder Properties") { Self.move(&$0.properties, where: { $0.id == id }, by: offset) }
    }

    // MARK: Exposing inner ports and properties

    /// Whether an inner input port is one of the exposed inputs' targets. Nil outside a subgraph.
    public func isExposed(input address: PortAddress) -> Bool? {
        currentInterface.map { $0.inputs.contains { $0.targets.contains(address) } }
    }

    /// Whether an inner output port is the source of an exposed output. Nil outside a subgraph.
    public func isExposed(output address: PortAddress) -> Bool? {
        currentInterface.map { $0.outputs.contains { $0.source == address } }
    }

    /// Whether an inner property is a target of an exposed property. Nil outside a subgraph.
    public func isExposed(property target: PropertyTarget) -> Bool? {
        currentInterface.map { $0.properties.contains { $0.targets.contains(target) } }
    }

    /// Exposes an inner input port as a new input of the subgraph, or stops exposing it. The new
    /// input takes the port's name, type and default.
    @discardableResult
    public func setExposed(_ exposed: Bool, input address: PortAddress) -> Bool {
        guard address.direction == .input else { return false }
        if !exposed {
            return editInterface("Hide Input") { interface in
                for index in interface.inputs.indices { interface.inputs[index].targets.removeAll { $0 == address } }
                interface.inputs.removeAll { $0.targets.isEmpty }
            }
        }
        guard let port = innerPort(address) else { return false }
        return tryEditInterface("Expose Input") { interface in
            guard !interface.inputs.contains(where: { $0.targets.contains(address) }) else { return false }
            interface.inputs.append(SubgraphInput(
                id: PortID(Self.unique(port.id.rawValue, among: interface.inputs.map(\.id.rawValue))),
                displayName: port.displayName, kind: port.kind, type: port.type, defaultValue: port.defaultValue,
                allowsMultipleLinks: false, targets: [address]))
            return true
        }
    }

    @discardableResult
    public func setExposed(_ exposed: Bool, output address: PortAddress) -> Bool {
        guard address.direction == .output else { return false }
        if !exposed {
            return editInterface("Hide Output") { $0.outputs.removeAll { $0.source == address } }
        }
        guard let port = innerPort(address) else { return false }
        return tryEditInterface("Expose Output") { interface in
            guard !interface.outputs.contains(where: { $0.source == address }) else { return false }
            interface.outputs.append(SubgraphOutput(
                id: PortID(Self.unique(port.id.rawValue, among: interface.outputs.map(\.id.rawValue))),
                displayName: port.displayName, kind: port.kind, type: port.type, source: address))
            return true
        }
    }

    /// Exposes an inner property as a new property of the subgraph, with its current value as the
    /// default, or stops exposing it.
    @discardableResult
    public func setExposed(_ exposed: Bool, property target: PropertyTarget) -> Bool {
        if !exposed {
            return editInterface("Hide Property") { interface in
                for index in interface.properties.indices { interface.properties[index].targets.removeAll { $0 == target } }
                interface.properties.removeAll { $0.targets.isEmpty }
            }
        }
        guard let node = graph.nodes[target.node], let definition = definition(of: node),
              let property = definition.property(target.property) else { return false }
        return tryEditInterface("Expose Property") { interface in
            guard !interface.properties.contains(where: { $0.targets.contains(target) }) else { return false }
            interface.properties.append(PromotedProperty(
                id: PropertyID(Self.unique(property.id.rawValue, among: interface.properties.map(\.id.rawValue))),
                displayName: property.displayName, kind: property.kind,
                defaultValue: node.properties[property.id] ?? property.defaultValue, targets: [target]))
            return true
        }
    }

    // MARK: Helpers

    /// The interface of the subgraph being edited, or nil at the root.
    var currentInterface: SubgraphInterface? {
        currentScope.flatMap { editor.subgraphs[$0]?.interface }
    }

    private func innerPort(_ address: PortAddress) -> PortDefinition? {
        graph.nodes[address.node].flatMap { definition(of: $0) }?.port(address.port, direction: address.direction)
    }

    /// Applies `change` to a copy of the interface and, if it changed anything, records it.
    private func tryEditInterface(_ name: String, _ change: (inout SubgraphInterface) -> Bool) -> Bool {
        guard let scope = currentScope, var interface = editor.subgraphs[scope]?.interface else { return false }
        let original = interface
        if !change(&interface) { return false }
        guard interface != original else { return false }
        return (try? perform(.setSubgraphInterface(id: scope, interface: interface), name: name, isScoped: true)) != nil
    }

    private func editInterface(_ name: String, _ change: (inout SubgraphInterface) -> Void) -> Bool {
        tryEditInterface(name) { interface in
            change(&interface)
            return true
        }
    }

    /// Moves the first element matching `predicate` by `offset` places, stopping at the ends.
    private static func move<T>(_ items: inout [T], where predicate: (T) -> Bool, by offset: Int) -> Bool {
        guard let index = items.firstIndex(where: predicate) else { return false }
        let target = min(max(index + offset, 0), items.count - 1)
        guard target != index else { return false }
        items.insert(items.remove(at: index), at: target)
        return true
    }

    /// `base`, or `base_2`, `base_3`, ... so that it is not among `taken`.
    private static func unique(_ base: String, among taken: [String]) -> String {
        guard taken.contains(base) else { return base }
        var number = 2
        while taken.contains("\(base)_\(number)") { number += 1 }
        return "\(base)_\(number)"
    }
}
