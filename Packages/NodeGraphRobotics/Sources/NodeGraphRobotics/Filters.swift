import Foundation
import NodeGraphCore

extension RoboticsPack {
    static func registerFilters(in nodes: inout NodeRegistry) {
        // First-order low-pass. The blend is dt / (tau + dt), so the response depends on the time
        // step rather than on how many passes have run. The first sample passes through.
        nodes.register(NodeDefinition(
            typeID: "robotics.lowPass", displayName: "Low-Pass Filter", category: "Robotics",
            ports: [number("value", .input, 0), number("result", .output)],
            properties: [double("tau", "Time constant (s)", 0.1)],
            help: "Smooths a noisy value. Tau is the time constant in seconds: larger is smoother and slower.")
        ) { ctx in
            let tau = try ctx.property("tau").numberValue ?? 0
            guard tau >= 0 else { throw NodeExecutionError.failed("Time constant must not be negative") }
            let input = try ctx.number("value")
            let dt = ctx.time.deltaSeconds
            let output: Double
            if let previous = ctx.state?.numberValue, tau + dt > 0 {
                output = previous + (input - previous) * (dt / (tau + dt))
            } else {
                output = input
            }
            let result = try finite(output, "Low-pass filter")
            return NodeOutputs(["result": .double(result)], state: .double(result))
        }

        // Limits how fast a value may change, in units per second.
        nodes.register(NodeDefinition(
            typeID: "robotics.rateLimit", displayName: "Rate Limiter", category: "Robotics",
            ports: [number("value", .input, 0), number("result", .output)],
            properties: [double("maxRate", "Maximum rate (per s, 0 = none)", 1)],
            help: "Limits how fast a value can change, in units per second. A rate of 0 means no limit.")
        ) { ctx in
            let rate = try ctx.property("maxRate").numberValue ?? 0
            guard rate >= 0 else { throw NodeExecutionError.failed("Maximum rate must not be negative") }
            let input = try ctx.number("value")
            var output = input
            if rate > 0, let previous = ctx.state?.numberValue {
                let step = rate * ctx.time.deltaSeconds
                output = clamp(input, previous - step, previous + step)
            }
            return NodeOutputs(["result": .double(output)], state: .double(output))
        }

        nodes.register(NodeDefinition(
            typeID: "robotics.deadband", displayName: "Deadband", category: "Robotics",
            ports: [number("value", .input, 0), number("result", .output)],
            properties: [double("width", "Width", 0.05)],
            isPure: true,
            help: "Reports 0 while the value is within the width of zero, and the value itself otherwise.")
        ) { ctx in
            let width = try ctx.property("width").numberValue ?? 0, value = try ctx.number("value")
            guard width >= 0 else { throw NodeExecutionError.failed("Width must not be negative") }
            return ["result": .double(abs(value) <= width ? 0 : value)]
        }

        // A comparator with hysteresis: switches on above `high`, off below `low`, and holds in
        // between, so a noisy value near one threshold does not chatter.
        nodes.register(NodeDefinition(
            typeID: "robotics.threshold", displayName: "Threshold", category: "Robotics",
            ports: [
                number("value", .input, 0),
                PortDefinition(id: "active", direction: .output, type: .bool),
                PortDefinition(id: "rose", direction: .output, kind: .trigger),
                PortDefinition(id: "fell", direction: .output, kind: .trigger),
            ],
            properties: [double("high", "High", 0.6), double("low", "Low", 0.4)],
            help: "Switches on above High and off below Low. Between them it holds, so noise does not make it flicker.")
        ) { ctx in
            let high = try ctx.property("high").numberValue ?? 0, low = try ctx.property("low").numberValue ?? 0, value = try ctx.number("value")
            guard low <= high else { throw NodeExecutionError.failed("Low must not be above high") }
            let was = ctx.state?.boolValue ?? false
            let now = value > high ? true : (value < low ? false : was)
            var triggers = Set<PortID>()
            if now && !was { triggers.insert("rose") }
            if !now && was { triggers.insert("fell") }
            return NodeOutputs(["active": .bool(now)], triggers: triggers, state: .bool(now))
        }
    }
}
