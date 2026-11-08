import Foundation
import NodeGraphCore

extension RoboticsPack {
    static func registerControl(in nodes: inout NodeRegistry) {
        // Derivative acts on the measurement, not the error, so a setpoint step gives no kick. The
        // integral stops growing while the output is saturated and the error pushes further in.
        // State: [integral term, last measurement, primed (0 or 1)].
        nodes.register(NodeDefinition(
            typeID: "robotics.pid", displayName: "PID Controller", category: "Robotics",
            ports: [
                number("setpoint", .input, 0), number("measurement", .input, 0),
                PortDefinition(id: "reset", direction: .input, kind: .trigger),
                number("output", .output), number("error", .output),
            ],
            properties: [
                double("kp", "Proportional gain", 1), double("ki", "Integral gain", 0), double("kd", "Derivative gain", 0),
                double("min", "Output minimum", -1), double("max", "Output maximum", 1),
            ],
            help: "Drives the measurement toward the setpoint. The output is limited to min..max, and the integral does not wind up while it is limited. Reset clears the memory.")
        ) { ctx in
            let low = try ctx.property("min").numberValue ?? 0, high = try ctx.property("max").numberValue ?? 0
            guard low <= high else { throw NodeExecutionError.failed("Min must not be above max") }
            let setpoint = try ctx.number("setpoint"), measurement = try ctx.number("measurement")
            let kp = try ctx.property("kp").numberValue ?? 0, ki = try ctx.property("ki").numberValue ?? 0
            let kd = try ctx.property("kd").numberValue ?? 0

            var memory: [Double] = [0, 0, 0]
            if case .vector(let saved)? = ctx.state, saved.count == 3 { memory = saved }
            if ctx.didTrigger("reset") { memory = [0, 0, 0] }

            let dt = ctx.time.deltaSeconds
            let error = setpoint - measurement
            let proportional = kp * error
            var integral = memory[0], derivative = 0.0
            if memory[2] == 1, dt > 0 {
                let grown = integral + ki * error * dt
                derivative = -kd * (measurement - memory[1]) / dt
                let raw = proportional + grown + derivative
                let windingUp = (raw > high && error > 0) || (raw < low && error < 0)
                if !windingUp { integral = grown }
            }
            let output = clamp(try finite(proportional + integral + derivative, "PID output"), low, high)
            return NodeOutputs(
                ["output": .double(output), "error": .double(error)],
                state: .vector([integral, measurement, 1]))
        }

        // A stand-in for the thing being controlled, so a control loop can run with no robot.
        // It is a feedback node: links leaving it carry its value from the previous pass, which
        // is the sensor reading before this pass's command acts. That closes a loop without a
        // separate delay node.
        nodes.register(NodeDefinition(
            typeID: "robotics.plant", displayName: "First-Order Plant", category: "Robotics",
            ports: [number("input", .input, 0), number("output", .output)],
            properties: [
                double("gain", "Gain", 1), double("tau", "Time constant (s)", 0.5, min: 0),
                double("initial", "Initial value", 0),
            ],
            isFeedback: true,
            help: "A simulated system that moves toward gain times its input, with a time constant. Its output reaches the next pass, like a sensor read before this pass's command acts.")
        ) { ctx in
            let gain = try ctx.property("gain").numberValue ?? 1
            let tau = try ctx.property("tau").numberValue ?? 0
            let initial = try ctx.property("initial").numberValue ?? 0
            let current = ctx.state?.numberValue ?? initial
            let target = gain * (try ctx.number("input"))
            // The exact solution for a constant input over the step, so it stays stable at any dt.
            let blend = tau > 0 ? 1 - exp(-ctx.time.deltaSeconds / tau) : 1
            let next = try finite(current + (target - current) * blend, "Plant")
            // Links leaving a feedback node deliver this value on the next pass.
            return NodeOutputs(["output": .double(next)], state: .double(next))
        }
    }
}
