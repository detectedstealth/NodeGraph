import Foundation
import NodeGraphCore

extension RoboticsPack {
    static func registerActuators(in nodes: inout NodeRegistry) {
        // The last stage before hardware: limits the command to the actuator's range and speed.
        // Disabled means an emergency stop, so it goes straight to the safe value with no rate
        // limit. State: the value last applied.
        nodes.register(NodeDefinition(
            typeID: "robotics.actuator", displayName: "Actuator", category: "Robotics",
            ports: [
                number("command", .input, 0),
                PortDefinition(id: "enabled", direction: .input, type: .bool, defaultValue: true),
                number("applied", .output),
                PortDefinition(id: "limited", direction: .output, type: .bool),
            ],
            properties: [
                double("min", "Minimum", -1), double("max", "Maximum", 1),
                double("maxRate", "Maximum rate (per s, 0 = none)", 0, min: 0),
                double("safe", "Safe value", 0),
            ],
            help: "Limits a command to the range and speed the hardware allows. While disabled it applies the safe value at once. Limited is true when the command was changed.")
        ) { ctx in
            let low = try ctx.property("min").numberValue ?? 0, high = try ctx.property("max").numberValue ?? 0
            guard low <= high else { throw NodeExecutionError.failed("Minimum must not be above maximum") }
            let maxRate = try ctx.property("maxRate").numberValue ?? 0
            let safe = clamp(try ctx.property("safe").numberValue ?? 0, low, high)
            let command = try ctx.number("command")

            let enabled = try ctx.bool("enabled")
            let applied: Double
            if !enabled {
                applied = safe
            } else {
                var target = clamp(command, low, high)
                if maxRate > 0, let previous = ctx.state?.numberValue {
                    let step = maxRate * ctx.time.deltaSeconds
                    target = clamp(target, previous - step, previous + step)
                }
                applied = target
            }
            return NodeOutputs(
                ["applied": .double(applied), "limited": .bool(enabled && applied != command)],
                state: .double(applied))
        }
    }
}
