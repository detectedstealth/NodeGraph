import Foundation
import NodeGraphCore

/// Arithmetic and trigonometry on numbers. Every node is pure. Unlinked inputs use the defaults
/// shown in each definition (identity values for multiply, divide and power).
public enum MathPack: NodePack {
    public static func register(nodes: inout NodeRegistry, types: inout TypeRegistry) {
        StandardTypes.register(in: &types)

        binary("math.add", "Add", a: 0, b: 0, in: &nodes) { a, b in a + b }
        binary("math.subtract", "Subtract", a: 0, b: 0, in: &nodes) { a, b in a - b }
        binary("math.multiply", "Multiply", a: 1, b: 1, in: &nodes) { a, b in a * b }
        binary("math.divide", "Divide", a: 0, b: 1, in: &nodes) { a, b in
            guard b != 0 else { throw NodeExecutionError.failed("Division by zero") }
            return a / b
        }
        binary("math.modulo", "Modulo", a: 0, b: 1, in: &nodes) { a, b in
            guard b != 0 else { throw NodeExecutionError.failed("Modulo by zero") }
            return a.truncatingRemainder(dividingBy: b)
        }
        binary("math.power", "Power", a: 0, b: 1, in: &nodes) { a, b in try finite(pow(a, b), "Power") }
        binary("math.min", "Min", a: 0, b: 0, in: &nodes) { a, b in min(a, b) }
        binary("math.max", "Max", a: 0, b: 0, in: &nodes) { a, b in max(a, b) }

        unary("math.negate", "Negate", in: &nodes) { -$0 }
        unary("math.abs", "Absolute Value", in: &nodes) { abs($0) }
        unary("math.floor", "Floor", in: &nodes) { $0.rounded(.down) }
        unary("math.ceil", "Ceiling", in: &nodes) { $0.rounded(.up) }
        unary("math.round", "Round", in: &nodes) { $0.rounded(.toNearestOrAwayFromZero) }
        unary("math.sqrt", "Square Root", in: &nodes) { value in
            guard value >= 0 else { throw NodeExecutionError.failed("Square root of a negative number") }
            return value.squareRoot()
        }
        unary("math.sin", "Sine", in: &nodes) { sin($0) }
        unary("math.cos", "Cosine", in: &nodes) { cos($0) }
        unary("math.tan", "Tangent", in: &nodes) { tan($0) }
        unary("math.asin", "Arcsine", in: &nodes) { value in
            guard (-1...1).contains(value) else { throw NodeExecutionError.failed("Arcsine needs a value from -1 to 1") }
            return asin(value)
        }
        unary("math.acos", "Arccosine", in: &nodes) { value in
            guard (-1...1).contains(value) else { throw NodeExecutionError.failed("Arccosine needs a value from -1 to 1") }
            return acos(value)
        }
        unary("math.atan", "Arctangent", in: &nodes) { atan($0) }
        // The angle of the point (x, y), in radians from -pi to pi.
        binary("math.atan2", "Arctangent 2", a: 0, b: 1, in: &nodes) { y, x in atan2(y, x) }
        // The part after the decimal point, always 0 up to 1: frac(-0.25) is 0.75.
        unary("math.frac", "Fraction", in: &nodes) { $0 - $0.rounded(.down) }

        // Adds any number of inputs. The node always shows one free input after the last linked
        // one, so connecting the last port makes another.
        nodes.register(NodeDefinition(
            typeID: "math.sum", displayName: "Sum", category: "Math",
            ports: [number("result", .output)],
            dynamicPorts: [DynamicPortGroup(
                id: "in", displayName: "Value", type: .number, minimum: 2, initialCount: 2, resizing: .keepOneFree)],
            isPure: true)
        ) { ctx in
            var total = 0.0
            for value in ctx.values(inGroup: "in") {
                guard let number = value.numberValue else { throw NodeExecutionError.failed("Sum needs numbers") }
                total += number
            }
            return ["result": .double(try finite(total, "Sum"))]
        }

        nodes.register(NodeDefinition(
            typeID: "math.clamp", displayName: "Clamp", category: "Math",
            ports: [
                number("value", .input, 0), number("min", .input, 0), number("max", .input, 1),
                number("result", .output),
            ],
            isPure: true)
        ) { ctx in
            let low = try ctx.number("min"), high = try ctx.number("max")
            guard low <= high else { throw NodeExecutionError.failed("Clamp minimum is above its maximum") }
            return ["result": .double(min(max(try ctx.number("value"), low), high))]
        }

        // Maps `value` from one range onto another. The ranges may run backwards. With `clamp`
        // on, values outside the input range stop at the ends of the output range.
        nodes.register(NodeDefinition(
            typeID: "math.remap", displayName: "Remap", category: "Math",
            ports: [
                number("value", .input, 0), number("inMin", .input, 0), number("inMax", .input, 1),
                number("outMin", .input, 0), number("outMax", .input, 1), number("result", .output),
            ],
            properties: [PropertyDefinition(id: "clamp", displayName: "Clamp", kind: .bool, defaultValue: false)],
            isPure: true)
        ) { ctx in
            let low = try ctx.number("inMin"), high = try ctx.number("inMax")
            guard low != high else { throw NodeExecutionError.failed("Remap input range is empty") }
            var t = (try ctx.number("value") - low) / (high - low)
            if try ctx.property("clamp").boolValue == true { t = min(max(t, 0), 1) }
            let start = try ctx.number("outMin"), end = try ctx.number("outMax")
            return ["result": .double(try finite(start + (end - start) * t, "Remap"))]
        }

        // 0 below `edge0`, 1 above `edge1`, and an S-shaped ease between them.
        nodes.register(NodeDefinition(
            typeID: "math.smoothstep", displayName: "Smoothstep", category: "Math",
            ports: [number("x", .input, 0), number("edge0", .input, 0), number("edge1", .input, 1), number("result", .output)],
            isPure: true)
        ) { ctx in
            let low = try ctx.number("edge0"), high = try ctx.number("edge1")
            guard low != high else { throw NodeExecutionError.failed("Smoothstep edges are equal") }
            let t = min(max((try ctx.number("x") - low) / (high - low), 0), 1)
            return ["result": .double(t * t * (3 - 2 * t))]
        }

        // A number from `min` up to (not including) `max` that is a pure function of the seed,
        // the pass number and this node, so the same seed always gives the same run, including in
        // deterministic runs, and every pass gets a fresh number. Not pure: it reads the pass.
        // A node inside a subgraph instance repeats its sequence in every instance.
        nodes.register(NodeDefinition(
            typeID: "math.random", displayName: "Random", category: "Math",
            ports: [number("min", .input, 0), number("max", .input, 1), number("result", .output)],
            properties: [PropertyDefinition(id: "seed", displayName: "Seed", kind: .int(), defaultValue: .int(0))])
        ) { ctx in
            let low = try ctx.number("min"), high = try ctx.number("max")
            let seed = UInt64(bitPattern: try ctx.property("seed").intValue ?? 0)
            var state = seed ^ (UInt64(ctx.time.tick) &* 0x9E37_79B9_7F4A_7C15)
            withUnsafeBytes(of: ctx.nodeID.uuid.uuid) { bytes in
                for byte in bytes { state = (state ^ UInt64(byte)) &* 0x0000_0100_0000_01B3 }
            }
            // SplitMix64 finalizer: spreads the mixed bits over the whole word.
            state = (state ^ (state >> 30)) &* 0xBF58_476D_1CE4_E5B9
            state = (state ^ (state >> 27)) &* 0x94D0_49BB_1331_11EB
            state ^= state >> 31
            let unit = Double(state >> 11) / Double(1 << 53)
            return ["result": .double(try finite(low + (high - low) * unit, "Random"))]
        }

        nodes.register(NodeDefinition(
            typeID: "math.lerp", displayName: "Lerp", category: "Math",
            ports: [
                number("a", .input, 0), number("b", .input, 1), number("t", .input, 0),
                number("result", .output),
            ],
            isPure: true)
        ) { ctx in
            let a = try ctx.number("a"), b = try ctx.number("b"), t = try ctx.number("t")
            return ["result": .double(a + (b - a) * t)]
        }
    }

    // MARK: Helpers

    private static func number(_ id: PortID, _ direction: PortDirection, _ value: Double? = nil) -> PortDefinition {
        PortDefinition(id: id, direction: direction, type: .number, defaultValue: value.map { .double($0) })
    }

    private static func finite(_ value: Double, _ name: String) throws -> Double {
        guard value.isFinite else { throw NodeExecutionError.failed("\(name) is not a finite number") }
        return value
    }

    private static func binary(
        _ id: NodeTypeID, _ name: String, a: Double, b: Double, in nodes: inout NodeRegistry,
        _ operation: @escaping @Sendable (Double, Double) throws -> Double
    ) {
        nodes.register(NodeDefinition(
            typeID: id, displayName: name, category: "Math",
            ports: [number("a", .input, a), number("b", .input, b), number("result", .output)],
            isPure: true)
        ) { ctx in
            ["result": .double(try finite(operation(try ctx.number("a"), try ctx.number("b")), name))]
        }
    }

    private static func unary(
        _ id: NodeTypeID, _ name: String, in nodes: inout NodeRegistry,
        _ operation: @escaping @Sendable (Double) throws -> Double
    ) {
        nodes.register(NodeDefinition(
            typeID: id, displayName: name, category: "Math",
            ports: [number("value", .input, 0), number("result", .output)],
            isPure: true)
        ) { ctx in
            ["result": .double(try finite(operation(try ctx.number("value")), name))]
        }
    }
}
