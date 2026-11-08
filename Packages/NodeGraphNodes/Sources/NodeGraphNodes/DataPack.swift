import Foundation
import NodeGraphCore

/// Arrays, objects, JSON and explicit conversions between value kinds. Every node is pure.
///
/// Arrays are `GraphValue.array` (a `.vector` is read as an array of numbers). Indexes count
/// from zero. Nothing here changes its input: `set`, `append` and `merge` return a new value.
public enum DataPack: NodePack {
    public static func register(nodes: inout NodeRegistry, types: inout TypeRegistry) {
        StandardTypes.register(in: &types)

        // MARK: Arrays

        // Collects any number of inputs, in port order. Unlinked ports are skipped.
        nodes.register(NodeDefinition(
            typeID: "array.make", displayName: "Make Array", category: "Array",
            ports: [PortDefinition(id: "result", direction: .output, type: .array)],
            dynamicPorts: [DynamicPortGroup(
                id: "in", displayName: "Item", minimum: 1, initialCount: 2, resizing: .keepOneFree)],
            isPure: true)
        ) { ctx in ["result": .array(ctx.values(inGroup: "in"))] }

        nodes.register(NodeDefinition(
            typeID: "array.length", displayName: "Array Length", category: "Array",
            ports: [
                PortDefinition(id: "array", direction: .input, type: .array, defaultValue: .array([])),
                PortDefinition(id: "result", direction: .output, type: .number),
            ],
            isPure: true)
        ) { ctx in ["result": .int(Int64(try items(ctx, "array").count))] }

        nodes.register(NodeDefinition(
            typeID: "array.get", displayName: "Get Item", category: "Array",
            ports: [
                PortDefinition(id: "array", direction: .input, type: .array, defaultValue: .array([])),
                PortDefinition(id: "index", direction: .input, type: .number, defaultValue: .int(0)),
                PortDefinition(id: "result", direction: .output),
            ],
            isPure: true)
        ) { ctx in
            let list = try items(ctx, "array"), index = try index(ctx, "index")
            guard list.indices.contains(index) else {
                throw NodeExecutionError.failed("Index \(index) is outside an array of \(list.count)")
            }
            return ["result": list[index]]
        }

        nodes.register(NodeDefinition(
            typeID: "array.set", displayName: "Set Item", category: "Array",
            ports: [
                PortDefinition(id: "array", direction: .input, type: .array, defaultValue: .array([])),
                PortDefinition(id: "index", direction: .input, type: .number, defaultValue: .int(0)),
                PortDefinition(id: "value", direction: .input),
                PortDefinition(id: "result", direction: .output, type: .array),
            ],
            isPure: true)
        ) { ctx in
            var list = try items(ctx, "array")
            let index = try index(ctx, "index")
            guard list.indices.contains(index) else {
                throw NodeExecutionError.failed("Index \(index) is outside an array of \(list.count)")
            }
            list[index] = try ctx.input("value")
            return ["result": .array(list)]
        }

        nodes.register(NodeDefinition(
            typeID: "array.append", displayName: "Append", category: "Array",
            ports: [
                PortDefinition(id: "array", direction: .input, type: .array, defaultValue: .array([])),
                PortDefinition(id: "value", direction: .input),
                PortDefinition(id: "result", direction: .output, type: .array),
            ],
            isPure: true)
        ) { ctx in ["result": .array(try items(ctx, "array") + [try ctx.input("value")])] }

        // `count` below zero means "to the end". The range is clamped to the array, never an error.
        nodes.register(NodeDefinition(
            typeID: "array.slice", displayName: "Slice", category: "Array",
            ports: [
                PortDefinition(id: "array", direction: .input, type: .array, defaultValue: .array([])),
                PortDefinition(id: "start", direction: .input, type: .number, defaultValue: .int(0)),
                PortDefinition(id: "count", direction: .input, type: .number, defaultValue: .int(-1)),
                PortDefinition(id: "result", direction: .output, type: .array),
            ],
            isPure: true)
        ) { ctx in
            let list = try items(ctx, "array")
            let start = min(max(try index(ctx, "start"), 0), list.count)
            let count = try index(ctx, "count")
            let end = count < 0 ? list.count : min(start + count, list.count)
            return ["result": .array(Array(list[start..<end]))]
        }

        // MARK: Objects

        // `found` is false, and `value` absent, when the key is missing.
        nodes.register(NodeDefinition(
            typeID: "object.get", displayName: "Get Field", category: "Object",
            ports: [
                PortDefinition(id: "object", direction: .input, type: .object, defaultValue: .object([:])),
                PortDefinition(id: "key", direction: .input, type: .string, defaultValue: ""),
                PortDefinition(id: "value", direction: .output),
                PortDefinition(id: "found", direction: .output, type: .bool),
            ],
            isPure: true)
        ) { ctx in
            let fields = try fields(ctx, "object")
            guard let value = fields[try ctx.string("key")] else { return ["found": .bool(false)] }
            return ["value": value, "found": .bool(true)]
        }

        nodes.register(NodeDefinition(
            typeID: "object.set", displayName: "Set Field", category: "Object",
            ports: [
                PortDefinition(id: "object", direction: .input, type: .object, defaultValue: .object([:])),
                PortDefinition(id: "key", direction: .input, type: .string, defaultValue: ""),
                PortDefinition(id: "value", direction: .input),
                PortDefinition(id: "result", direction: .output, type: .object),
            ],
            isPure: true)
        ) { ctx in
            var fields = try fields(ctx, "object")
            fields[try ctx.string("key")] = try ctx.input("value")
            return ["result": .object(fields)]
        }

        // Fields of `b` win over fields of `a`.
        nodes.register(NodeDefinition(
            typeID: "object.merge", displayName: "Merge Objects", category: "Object",
            ports: [
                PortDefinition(id: "a", direction: .input, type: .object, defaultValue: .object([:])),
                PortDefinition(id: "b", direction: .input, type: .object, defaultValue: .object([:])),
                PortDefinition(id: "result", direction: .output, type: .object),
            ],
            isPure: true)
        ) { ctx in
            ["result": .object(try fields(ctx, "a").merging(try fields(ctx, "b")) { _, new in new })]
        }

        // Sorted, so the result does not depend on dictionary order.
        nodes.register(NodeDefinition(
            typeID: "object.keys", displayName: "Field Names", category: "Object",
            ports: [
                PortDefinition(id: "object", direction: .input, type: .object, defaultValue: .object([:])),
                PortDefinition(id: "result", direction: .output, type: .array),
            ],
            isPure: true)
        ) { ctx in ["result": .array(try fields(ctx, "object").keys.sorted().map(GraphValue.string))] }

        nodes.register(NodeDefinition(
            typeID: "object.parseJson", displayName: "Parse JSON", category: "Object",
            ports: [
                PortDefinition(id: "text", direction: .input, type: .string, defaultValue: "null"),
                PortDefinition(id: "result", direction: .output),
            ],
            isPure: true)
        ) { ctx in
            let text = try ctx.string("text")
            do {
                let json = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
                return ["result": GraphValue(json: json)]
            } catch {
                throw NodeExecutionError.failed("Not valid JSON")
            }
        }

        // Numbers, text, booleans, arrays and objects only; colors, matrices, data and handles
        // have no JSON form here and fail.
        nodes.register(NodeDefinition(
            typeID: "object.toJson", displayName: "To JSON", category: "Object",
            ports: [
                PortDefinition(id: "value", direction: .input),
                PortDefinition(id: "result", direction: .output, type: .string),
            ],
            isPure: true)
        ) { ctx in
            guard let json = try ctx.input("value").json else {
                throw NodeExecutionError.failed("This value has no JSON form")
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return ["result": .string(String(decoding: try encoder.encode(json), as: UTF8.self))]
        }

        // MARK: Conversions

        // bool is 0 or 1, text is parsed, a one-element vector is its element.
        nodes.register(NodeDefinition(
            typeID: "convert.toNumber", displayName: "To Number", category: "Convert",
            ports: [
                PortDefinition(id: "value", direction: .input),
                PortDefinition(id: "result", direction: .output, type: .number),
            ],
            isPure: true)
        ) { ctx in
            let value = try ctx.input("value")
            switch value {
            case .int, .double: return ["result": .double(value.numberValue ?? 0)]
            case .bool(let flag): return ["result": .double(flag ? 1 : 0)]
            case .string(let text):
                guard let number = Double(text.trimmingCharacters(in: .whitespaces)), number.isFinite else {
                    throw NodeExecutionError.failed("\"\(text)\" is not a number")
                }
                return ["result": .double(number)]
            default: throw NodeExecutionError.invalidInput("value", expected: "number, bool or text")
            }
        }

        // A number is true unless zero; text is "true"/"false" (any case), "1" or "0".
        nodes.register(NodeDefinition(
            typeID: "convert.toBool", displayName: "To Bool", category: "Convert",
            ports: [
                PortDefinition(id: "value", direction: .input),
                PortDefinition(id: "result", direction: .output, type: .bool),
            ],
            isPure: true)
        ) { ctx in
            let value = try ctx.input("value")
            switch value {
            case .bool: return ["result": value]
            case .int(let number): return ["result": .bool(number != 0)]
            case .double(let number): return ["result": .bool(number != 0)]
            case .string(let text):
                switch text.trimmingCharacters(in: .whitespaces).lowercased() {
                case "true", "1": return ["result": .bool(true)]
                case "false", "0": return ["result": .bool(false)]
                default: throw NodeExecutionError.failed("\"\(text)\" is not true or false")
                }
            default: throw NodeExecutionError.invalidInput("value", expected: "number, bool or text")
            }
        }

        nodes.register(NodeDefinition(
            typeID: "convert.toInt", displayName: "To Integer", category: "Convert",
            ports: [
                PortDefinition(id: "value", direction: .input, type: .number, defaultValue: 0.0),
                PortDefinition(id: "result", direction: .output, type: .number),
            ],
            properties: [PropertyDefinition(
                id: "rounding", displayName: "Rounding",
                kind: .choice([
                    PropertyChoice(value: "nearest", label: "Nearest"),
                    PropertyChoice(value: "down", label: "Down"),
                    PropertyChoice(value: "up", label: "Up"),
                    PropertyChoice(value: "towardZero", label: "Toward Zero"),
                ]),
                defaultValue: "nearest")],
            isPure: true)
        ) { ctx in
            let number = try ctx.number("value")
            let rule: FloatingPointRoundingRule = switch try ctx.property("rounding").stringValue {
            case "down": .down
            case "up": .up
            case "towardZero": .towardZero
            default: .toNearestOrAwayFromZero
            }
            let rounded = number.rounded(rule)
            guard let integer = Int64(exactly: rounded) else {
                throw NodeExecutionError.failed("\(number) does not fit an integer")
            }
            return ["result": .int(integer)]
        }
    }

    // MARK: Helpers

    /// The elements of an array input; a vector reads as numbers.
    private static func items(_ ctx: NodeContext, _ port: PortID) throws -> [GraphValue] {
        switch try ctx.input(port) {
        case .array(let list): return list
        case .vector(let numbers): return numbers.map(GraphValue.double)
        default: throw NodeExecutionError.invalidInput(port, expected: "array")
        }
    }

    private static func fields(_ ctx: NodeContext, _ port: PortID) throws -> [String: GraphValue] {
        guard case .object(let fields) = try ctx.input(port) else {
            throw NodeExecutionError.invalidInput(port, expected: "object")
        }
        return fields
    }

    /// A whole number from a number input (a double with no fraction is accepted).
    private static func index(_ ctx: NodeContext, _ port: PortID) throws -> Int {
        let number = try ctx.number(port)
        guard let value = Int(exactly: number) else {
            throw NodeExecutionError.invalidInput(port, expected: "whole number")
        }
        return value
    }
}

extension GraphValue {
    init(json: JSONValue) {
        switch json {
        case .null: self = .null
        case .bool(let value): self = .bool(value)
        case .int(let value): self = .int(value)
        case .double(let value): self = .double(value)
        case .string(let value): self = .string(value)
        case .array(let items): self = .array(items.map(GraphValue.init(json:)))
        case .object(let fields): self = .object(fields.mapValues(GraphValue.init(json:)))
        }
    }

    /// The JSON form, or nil for kinds JSON cannot hold here (color, matrix, data, handle, and
    /// non-finite numbers).
    var json: JSONValue? {
        switch self {
        case .null: return .null
        case .bool(let value): return .bool(value)
        case .int(let value): return .int(value)
        case .double(let value): return value.isFinite ? .double(value) : nil
        case .string(let value): return .string(value)
        case .vector(let numbers):
            return numbers.allSatisfy(\.isFinite) ? .array(numbers.map(JSONValue.double)) : nil
        case .array(let items):
            let converted = items.compactMap(\.json)
            return converted.count == items.count ? .array(converted) : nil
        case .object(let fields):
            let converted = fields.compactMapValues(\.json)
            return converted.count == fields.count ? .object(converted) : nil
        case .matrix, .color, .data, .handle: return nil
        }
    }
}
