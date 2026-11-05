import NodeGraphCore

/// Time and event flow: delaying values, periodic triggers, and gating triggers.
public enum FlowPack: NodePack {
    public static func register(nodes: inout NodeRegistry, types: inout TypeRegistry) {
        StandardTypes.register(in: &types)

        // A feedback node: links leaving it deliver this node's output from the previous pass.
        // That lets a graph close a loop, for example an accumulator or a smoothing filter.
        nodes.register(NodeDefinition(
            typeID: "flow.delay", displayName: "Delay", category: "Flow",
            ports: [
                PortDefinition(id: "value", direction: .input),
                PortDefinition(id: "result", direction: .output),
            ],
            isFeedback: true, isPure: true)
        ) { ctx in ["result": try ctx.input("value")] }

        // Fires its trigger every `interval` passes, starting with the first. Reads the pass
        // number, so it is not pure.
        nodes.register(NodeDefinition(
            typeID: "flow.every", displayName: "Every N Passes", category: "Flow",
            ports: [PortDefinition(id: "fire", direction: .output, kind: .trigger)],
            properties: [PropertyDefinition(
                id: "interval", displayName: "Interval", kind: .int(min: 1), defaultValue: .int(1))])
        ) { ctx in
            let interval = max(try ctx.property("interval").intValue ?? 1, 1)
            return NodeOutputs(triggers: Int64(ctx.time.tick) % interval == 0 ? ["fire"] : [])
        }

        // Passes a trigger on only while `open` is true.
        nodes.register(NodeDefinition(
            typeID: "flow.gate", displayName: "Gate", category: "Flow",
            ports: [
                PortDefinition(id: "trigger", direction: .input, kind: .trigger),
                PortDefinition(id: "open", direction: .input, type: .bool, defaultValue: true),
                PortDefinition(id: "fire", direction: .output, kind: .trigger),
            ],
            isPure: true)
        ) { ctx in
            NodeOutputs(triggers: try ctx.didTrigger("trigger") && ctx.bool("open") ? ["fire"] : [])
        }

        // Turns "something fired" into a value, so triggers can drive data.
        nodes.register(NodeDefinition(
            typeID: "flow.triggerToBool", displayName: "Trigger To Bool", category: "Flow",
            ports: [
                PortDefinition(id: "trigger", direction: .input, kind: .trigger),
                PortDefinition(id: "result", direction: .output, type: .bool),
            ],
            isPure: true)
        ) { ctx in ["result": .bool(ctx.didTrigger("trigger"))] }

        // Fires when its input is true.
        nodes.register(NodeDefinition(
            typeID: "flow.boolToTrigger", displayName: "Bool To Trigger", category: "Flow",
            ports: [
                PortDefinition(id: "value", direction: .input, type: .bool, defaultValue: false),
                PortDefinition(id: "fire", direction: .output, kind: .trigger),
            ],
            isPure: true)
        ) { ctx in NodeOutputs(triggers: (try ctx.bool("value")) ? ["fire"] : []) }
    }
}
