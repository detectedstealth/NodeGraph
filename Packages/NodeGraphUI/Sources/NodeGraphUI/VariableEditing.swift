import NodeGraphCore

/// What kind of value a new variable holds, as the editor offers it.
public enum VariableKind: String, Hashable, Sendable, CaseIterable {
    case number
    case text
    case toggle

    public var title: String {
        switch self {
        case .number: "Number"
        case .text: "Text"
        case .toggle: "Toggle"
        }
    }

    /// The value a new variable of this kind starts with.
    public var initialValue: GraphValue {
        switch self {
        case .number: .double(0)
        case .text: .string("")
        case .toggle: .bool(false)
        }
    }
}

/// Editing the graph's variables. They live on the root graph, so inside a subgraph these do
/// nothing. Every edit is an undoable command.
extension GraphEditorModel {
    /// `base`, or `base 2`, `base 3`, and so on, whichever is not already a variable's name.
    public func uniqueVariableName(_ base: String = "variable") -> String {
        guard graph.variables[base] != nil else { return base }
        var number = 2
        while graph.variables["\(base) \(number)"] != nil { number += 1 }
        return "\(base) \(number)"
    }

    /// Declares a variable of `kind`, returning the name it got (made unique), or nil if
    /// the graph cannot take one right now (inside a subgraph, or read-only).
    @discardableResult
    public func addVariable(named name: String = "variable", kind: VariableKind) -> String? {
        guard currentScope == nil, GraphVariable.isValidName(name) else { return nil }
        let unique = uniqueVariableName(name)
        let variable = GraphVariable(name: unique, value: kind.initialValue)
        return (try? perform(.addVariable(variable: variable), name: "Add Variable", isScoped: true)) == nil ? nil : unique
    }

    /// Sets a variable's declared value. The new value must be the same kind as the old one, so
    /// a number field cannot turn a toggle into text; a nil or mismatched value changes nothing.
    /// With `coalescing`, repeated calls (a drag) are one undo step.
    @discardableResult
    public func setVariable(_ name: String, to value: GraphValue, coalescing: Bool = false) -> Bool {
        guard currentScope == nil, var variable = graph.variables[name],
              variable.value.kindName == value.kindName, variable.value != value else { return false }
        variable.value = value
        return (try? perform(
            .updateVariable(variable: variable), name: "Set Variable", coalescing: coalescing, isScoped: true)) != nil
    }

    @discardableResult
    public func removeVariable(_ name: String) -> Bool {
        guard currentScope == nil, graph.variables[name] != nil else { return false }
        return (try? perform(.removeVariable(name: name), name: "Remove Variable", isScoped: true)) != nil
    }
}
