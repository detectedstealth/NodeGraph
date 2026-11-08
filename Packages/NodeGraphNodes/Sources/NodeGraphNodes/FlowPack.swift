import NodeGraphCore

/// Time and event flow: delaying values, periodic triggers, and gating triggers.
public enum FlowPack: NodePack {
    public static func register(nodes: inout NodeRegistry, types: inout TypeRegistry) {
        StandardTypes.register(in: &types)
        defer { NodeHelp.apply(to: &nodes) }

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

        // Fires when both inputs fired in the same pass. It does not remember an input that
        // fired in an earlier pass; for that, latch each input first. Chain two for three inputs.
        nodes.register(NodeDefinition(
            typeID: "flow.both", displayName: "Both Triggers", category: "Flow",
            ports: [
                PortDefinition(id: "a", direction: .input, kind: .trigger),
                PortDefinition(id: "b", direction: .input, kind: .trigger),
                PortDefinition(id: "fire", direction: .output, kind: .trigger),
            ],
            isPure: true)
        ) { ctx in NodeOutputs(triggers: ctx.didTrigger("a") && ctx.didTrigger("b") ? ["fire"] : []) }

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

        // The nodes below keep per-node state (decision 193), so none is pure.

        // Counts events. Each pass applies reset, then increment, then decrement.
        nodes.register(NodeDefinition(
            typeID: "flow.counter", displayName: "Counter", category: "Flow",
            ports: [
                PortDefinition(id: "increment", direction: .input, kind: .trigger),
                PortDefinition(id: "decrement", direction: .input, kind: .trigger),
                PortDefinition(id: "reset", direction: .input, kind: .trigger),
                PortDefinition(id: "count", direction: .output, type: .number),
            ],
            properties: [PropertyDefinition(
                id: "start", displayName: "Start", kind: .int(), defaultValue: .int(0))])
        ) { ctx in
            let start = try ctx.property("start").intValue ?? 0
            var count = ctx.state?.intValue ?? start
            if ctx.didTrigger("reset") { count = start }
            if ctx.didTrigger("increment") { count &+= 1 }
            if ctx.didTrigger("decrement") { count &-= 1 }
            return NodeOutputs(["count": .int(count)], state: .int(count))
        }

        // Passes the first event on and swallows the rest, until `reset` arms it again.
        nodes.register(NodeDefinition(
            typeID: "flow.once", displayName: "Once", category: "Flow",
            ports: [
                PortDefinition(id: "trigger", direction: .input, kind: .trigger),
                PortDefinition(id: "reset", direction: .input, kind: .trigger),
                PortDefinition(id: "fire", direction: .output, kind: .trigger),
            ])
        ) { ctx in
            var spent = ctx.state?.boolValue ?? false
            if ctx.didTrigger("reset") { spent = false }
            let fires = ctx.didTrigger("trigger") && !spent
            if fires { spent = true }
            return NodeOutputs(triggers: fires ? ["fire"] : [], state: .bool(spent))
        }

        // A flip-flop: `set` turns it on, `reset` turns it off, and it stays that way between
        // events. `reset` wins when both fire in one pass.
        nodes.register(NodeDefinition(
            typeID: "flow.latch", displayName: "Latch", category: "Flow",
            ports: [
                PortDefinition(id: "set", direction: .input, kind: .trigger),
                PortDefinition(id: "reset", direction: .input, kind: .trigger),
                PortDefinition(id: "on", direction: .output, type: .bool),
            ])
        ) { ctx in
            var on = ctx.state?.boolValue ?? false
            if ctx.didTrigger("set") { on = true }
            if ctx.didTrigger("reset") { on = false }
            return NodeOutputs(["on": .bool(on)], state: .bool(on))
        }
    }
}
