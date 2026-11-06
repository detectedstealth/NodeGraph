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
