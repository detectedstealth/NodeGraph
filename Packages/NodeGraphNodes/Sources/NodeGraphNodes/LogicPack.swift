import NodeGraphCore

/// Booleans, comparison and selection. Every node is pure.
public enum LogicPack: NodePack {
    public static func register(nodes: inout NodeRegistry, types: inout TypeRegistry) {
        StandardTypes.register(in: &types)

        binary("logic.and", "And", in: &nodes) { $0 && $1 }
        binary("logic.or", "Or", in: &nodes) { $0 || $1 }
        binary("logic.xor", "Xor", in: &nodes) { $0 != $1 }

        nodes.register(NodeDefinition(
            typeID: "logic.not", displayName: "Not", category: "Logic",
            ports: [bool("value", .input), bool("result", .output)],
            isPure: true)
        ) { ctx in ["result": .bool(!(try ctx.bool("value")))] }

        nodes.register(NodeDefinition(
            typeID: "logic.compare", displayName: "Compare", category: "Logic",
            ports: [
                PortDefinition(id: "a", direction: .input, type: .number, defaultValue: 0.0),
                PortDefinition(id: "b", direction: .input, type: .number, defaultValue: 0.0),
                bool("result", .output),
            ],
            properties: [PropertyDefinition(
                id: "operator", displayName: "Operator",
                kind: .choice(Comparison.allCases.map { PropertyChoice(value: $0.rawValue, label: $0.rawValue) }),
                defaultValue: .string(Comparison.equal.rawValue))],
            isPure: true)
        ) { ctx in
            let name = try ctx.property("operator").stringValue ?? ""
            guard let comparison = Comparison(rawValue: name) else {
                throw NodeExecutionError.failed("Unknown comparison \"\(name)\"")
            }
            return ["result": .bool(comparison.test(try ctx.number("a"), try ctx.number("b")))]
        }

        // Chooses between two values of any type. Only the chosen branch is read, so the other
        // may be unlinked.
        nodes.register(NodeDefinition(
            typeID: "logic.select", displayName: "Select", category: "Logic",
            ports: [
                bool("condition", .input),
                PortDefinition(id: "ifTrue", displayName: "If True", direction: .input),
                PortDefinition(id: "ifFalse", displayName: "If False", direction: .input),
                PortDefinition(id: "result", direction: .output),
            ],
            isPure: true)
        ) { ctx in
            ["result": try ctx.input(try ctx.bool("condition") ? "ifTrue" : "ifFalse")]
        }
    }

    /// The operators of `logic.compare`.
    enum Comparison: String, CaseIterable {
        case equal = "=="
        case notEqual = "!="
        case less = "<"
        case lessOrEqual = "<="
        case greater = ">"
        case greaterOrEqual = ">="

        func test(_ a: Double, _ b: Double) -> Bool {
            switch self {
            case .equal: a == b
            case .notEqual: a != b
            case .less: a < b
            case .lessOrEqual: a <= b
            case .greater: a > b
            case .greaterOrEqual: a >= b
            }
        }
    }

    private static func bool(_ id: PortID, _ direction: PortDirection) -> PortDefinition {
        PortDefinition(id: id, direction: direction, type: .bool, defaultValue: direction == .input ? false : nil)
    }

    private static func binary(
        _ id: NodeTypeID, _ name: String, in nodes: inout NodeRegistry,
        _ operation: @escaping @Sendable (Bool, Bool) -> Bool
    ) {
        nodes.register(NodeDefinition(
            typeID: id, displayName: name, category: "Logic",
            ports: [bool("a", .input), bool("b", .input), bool("result", .output)],
            isPure: true)
        ) { ctx in ["result": .bool(operation(try ctx.bool("a"), try ctx.bool("b")))] }
    }
}
