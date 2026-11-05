import NodeGraphCore

/// Constants, reroute points and notes.
public enum UtilityPack: NodePack {
    public static func register(nodes: inout NodeRegistry, types: inout TypeRegistry) {
        StandardTypes.register(in: &types)

        constant("util.number", "Number", .number, .double(), 0.0, in: &nodes)
        constant("util.bool", "Boolean", .bool, .bool, false, in: &nodes)
        constant("util.string", "String", .string, .string(multiline: false), "", in: &nodes)

        // A point to bend a link around. Passes any value through unchanged.
        nodes.register(NodeDefinition(
            typeID: "util.reroute", displayName: "Reroute", category: "Utility",
            ports: [
                PortDefinition(id: "value", direction: .input),
                PortDefinition(id: "result", direction: .output),
            ],
            defaultSize: GraphSize(width: 40, height: 24),
            isPure: true)
        ) { ctx in ["result": try ctx.input("value")] }

        // Free text on the canvas. Takes no part in execution.
        nodes.register(NodeDefinition(
            typeID: "util.note", displayName: "Note", category: "Utility",
            properties: [PropertyDefinition(
                id: "text", displayName: "Text", kind: .string(multiline: true), defaultValue: "")],
            defaultSize: GraphSize(width: 200, height: 100),
            isPure: true)
        ) { _ in NodeOutputs.empty }
    }

    private static func constant(
        _ id: NodeTypeID, _ name: String, _ type: PortType, _ kind: PropertyKind, _ value: GraphValue,
        in nodes: inout NodeRegistry
    ) {
        nodes.register(NodeDefinition(
            typeID: id, displayName: name, category: "Utility",
            ports: [PortDefinition(id: "value", direction: .output, type: type)],
            properties: [PropertyDefinition(id: "value", displayName: "Value", kind: kind, defaultValue: value)],
            isPure: true)
        ) { ctx in ["value": try ctx.property("value")] }
    }
}
