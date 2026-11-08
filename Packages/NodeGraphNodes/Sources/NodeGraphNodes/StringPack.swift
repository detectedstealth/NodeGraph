import Foundation
import NodeGraphCore

/// Text manipulation. Every node is pure.
public enum StringPack: NodePack {
    public static func register(nodes: inout NodeRegistry, types: inout TypeRegistry) {
        StandardTypes.register(in: &types)
        defer { NodeHelp.apply(to: &nodes) }

        text("string.concat", "Concatenate", inputs: ["a", "b"], in: &nodes) { ctx in
            ["result": .string(try ctx.string("a") + ctx.string("b"))]
        }
        text("string.uppercase", "Uppercase", inputs: ["value"], in: &nodes) { ctx in
            ["result": .string(try ctx.string("value").uppercased())]
        }
        text("string.lowercase", "Lowercase", inputs: ["value"], in: &nodes) { ctx in
            ["result": .string(try ctx.string("value").lowercased())]
        }
        text("string.trim", "Trim", inputs: ["value"], in: &nodes) { ctx in
            ["result": .string(try ctx.string("value").trimmingCharacters(in: .whitespacesAndNewlines))]
        }
        text("string.replace", "Replace", inputs: ["value", "find", "replacement"], in: &nodes) { ctx in
            let find = try ctx.string("find")
            guard !find.isEmpty else { throw NodeExecutionError.failed("Nothing to find") }
            return ["result": .string(try ctx.string("value").replacingOccurrences(of: find, with: try ctx.string("replacement")))]
        }

        // Cuts text at every occurrence of the separator, keeping empty pieces: "a,,b" gives
        // "a", "", "b". An empty separator splits into characters.
        nodes.register(NodeDefinition(
            typeID: "string.split", displayName: "Split", category: "String",
            ports: [
                PortDefinition(id: "value", direction: .input, type: .string, defaultValue: ""),
                PortDefinition(id: "separator", direction: .input, type: .string, defaultValue: ","),
                PortDefinition(id: "result", direction: .output, type: .array),
            ],
            isPure: true)
        ) { ctx in
            let value = try ctx.string("value"), separator = try ctx.string("separator")
            let pieces = separator.isEmpty
                ? value.map(String.init) : value.components(separatedBy: separator)
            return ["result": .array(pieces.map(GraphValue.string))]
        }

        // A number with a fixed count of decimals: 3.14159 with 2 gives "3.14".
        nodes.register(NodeDefinition(
            typeID: "string.toFixed", displayName: "Format Number", category: "String",
            ports: [
                PortDefinition(id: "value", direction: .input, type: .number, defaultValue: 0.0),
                PortDefinition(id: "result", direction: .output, type: .string),
            ],
            properties: [PropertyDefinition(
                id: "decimals", displayName: "Decimals", kind: .int(min: 0, max: 15), defaultValue: .int(2))],
            isPure: true)
        ) { ctx in
            let number = try ctx.number("value")
            guard number.isFinite else { throw NodeExecutionError.failed("Not a finite number") }
            let decimals = min(max(Int(try ctx.property("decimals").intValue ?? 2), 0), 15)
            return ["result": .string(String(format: "%.\(decimals)f", number))]
        }

        // Joins any number of strings, in port order, with a separator. Unlinked ports are skipped.
        nodes.register(NodeDefinition(
            typeID: "string.join", displayName: "Join", category: "String",
            ports: [PortDefinition(id: "result", direction: .output, type: .string)],
            dynamicPorts: [DynamicPortGroup(
                id: "in", displayName: "Text", type: .string, minimum: 2, initialCount: 2, resizing: .keepOneFree)],
            properties: [PropertyDefinition(
                id: "separator", displayName: "Separator", kind: .string(multiline: false), defaultValue: "")],
            isPure: true)
        ) { ctx in
            let parts = try ctx.values(inGroup: "in").map { value -> String in
                guard let text = value.stringValue else { throw NodeExecutionError.failed("Join needs strings") }
                return text
            }
            return ["result": .string(parts.joined(separator: try ctx.property("separator").stringValue ?? ""))]
        }

        nodes.register(NodeDefinition(
            typeID: "string.length", displayName: "Length", category: "String",
            ports: [
                PortDefinition(id: "value", direction: .input, type: .string, defaultValue: ""),
                PortDefinition(id: "result", direction: .output, type: .number),
            ],
            isPure: true)
        ) { ctx in ["result": .double(Double(try ctx.string("value").count))] }

        nodes.register(NodeDefinition(
            typeID: "string.contains", displayName: "Contains", category: "String",
            ports: [
                PortDefinition(id: "value", direction: .input, type: .string, defaultValue: ""),
                PortDefinition(id: "search", direction: .input, type: .string, defaultValue: ""),
                PortDefinition(id: "result", direction: .output, type: .bool),
            ],
            isPure: true)
        ) { ctx in
            let search = try ctx.string("search"), value = try ctx.string("value")
            return ["result": .bool(search.isEmpty || value.contains(search))]
        }

        // Describes any value as text; numbers that are whole print without a decimal point.
        nodes.register(NodeDefinition(
            typeID: "string.format", displayName: "To String", category: "String",
            ports: [
                PortDefinition(id: "value", direction: .input),
                PortDefinition(id: "result", direction: .output, type: .string),
            ],
            isPure: true)
        ) { ctx in ["result": .string(describe(try ctx.input("value")))] }

        nodes.register(NodeDefinition(
            typeID: "string.parseNumber", displayName: "Parse Number", category: "String",
            ports: [
                PortDefinition(id: "value", direction: .input, type: .string, defaultValue: "0"),
                PortDefinition(id: "result", direction: .output, type: .number),
            ],
            isPure: true)
        ) { ctx in
            let text = try ctx.string("value").trimmingCharacters(in: .whitespaces)
            guard let number = Double(text), number.isFinite else {
                throw NodeExecutionError.failed("\"\(text)\" is not a number")
            }
            return ["result": .double(number)]
        }
    }

    /// Text for any value, used by `string.format`.
    static func describe(_ value: GraphValue) -> String {
        switch value {
        case .null: "null"
        case .bool(let v): v ? "true" : "false"
        case .int(let v): String(v)
        case .double(let v): v == v.rounded() && abs(v) < 1e15 ? String(Int64(v)) : String(v)
        case .string(let v): v
        case .vector(let v): "[" + v.map { describe(.double($0)) }.joined(separator: ", ") + "]"
        case .array(let v): "[" + v.map(describe).joined(separator: ", ") + "]"
        case .object(let v): "{" + v.sorted { $0.key < $1.key }.map { "\($0.key): \(describe($0.value))" }.joined(separator: ", ") + "}"
        case .matrix(let m): "matrix \(m.rows)x\(m.columns)"
        case .color(let c): "rgba(\(c.red), \(c.green), \(c.blue), \(c.alpha))"
        case .data(let d): "\(d.count) bytes"
        case .handle(let h): "handle \(h)"
        }
    }

    /// A pure node that maps string inputs (defaulting to empty) to a string `result`.
    private static func text(
        _ id: NodeTypeID, _ name: String, inputs: [PortID], in nodes: inout NodeRegistry,
        _ run: @escaping NodeExecutor
    ) {
        nodes.register(NodeDefinition(
            typeID: id, displayName: name, category: "String",
            ports: inputs.map { PortDefinition(id: $0, direction: .input, type: .string, defaultValue: "") }
                + [PortDefinition(id: "result", direction: .output, type: .string)],
            isPure: true), execute: run)
    }
}
