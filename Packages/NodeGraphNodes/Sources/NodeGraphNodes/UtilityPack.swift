import NodeGraphCore

/// Constants, reroute points, notes, and the run-time helpers Watch, Time and Log.
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

        // Shows the value passing through it: the editor draws the last value this node published
        // (see `RunValues`). Passes the value on, so it can sit in the middle of a link.
        nodes.register(NodeDefinition(
            typeID: "util.watch", displayName: "Watch", category: "Utility",
            ports: [
                PortDefinition(id: "value", direction: .input),
                PortDefinition(id: "result", direction: .output),
            ],
            defaultSize: GraphSize(width: 180, height: 60),
            isPure: true)
        ) { ctx in
            ctx.inputs["value"].map { ["result": $0] } ?? .empty
        }

        // Where the run is in time. Not pure: it changes every pass.
        nodes.register(NodeDefinition(
            typeID: "util.time", displayName: "Time", category: "Utility",
            ports: [
                PortDefinition(id: "elapsed", displayName: "Elapsed (s)", direction: .output, type: .number),
                PortDefinition(id: "delta", displayName: "Delta (s)", direction: .output, type: .number),
                PortDefinition(id: "tick", direction: .output, type: .number),
            ])
        ) { ctx in
            [
                "elapsed": .double(ctx.time.elapsedSeconds),
                "delta": .double(ctx.time.deltaSeconds),
                "tick": .int(Int64(ctx.time.tick)),
            ]
        }

        // Writes its input to the node's logger every pass it runs, then passes it on.
        nodes.register(NodeDefinition(
            typeID: "util.log", displayName: "Log", category: "Utility",
            ports: [
                PortDefinition(id: "value", direction: .input),
                PortDefinition(id: "result", direction: .output),
            ],
            properties: [
                PropertyDefinition(id: "label", displayName: "Label", kind: .string(), defaultValue: ""),
                PropertyDefinition(
                    id: "level", displayName: "Level",
                    kind: .choice([
                        PropertyChoice(value: "debug", label: "Debug"),
                        PropertyChoice(value: "info", label: "Info"),
                        PropertyChoice(value: "warning", label: "Warning"),
                        PropertyChoice(value: "error", label: "Error"),
                    ]),
                    defaultValue: "info"),
            ])
        ) { ctx in
            guard let value = ctx.inputs["value"] else { return .empty }
            let label = try ctx.property("label").stringValue ?? ""
            let line = "\(label.isEmpty ? "" : label + ": ")\(value.summary(limit: 500))"
            switch try ctx.property("level").stringValue {
            case "debug": ctx.logger.debug("\(line)")
            case "warning": ctx.logger.warning("\(line)")
            case "error": ctx.logger.error("\(line)")
            default: ctx.logger.info("\(line)")
            }
            return ["result": value]
        }

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
