import Foundation

extension GraphValue {
    /// A short, single-line description for watch displays, logs and tooltips. Strings appear
    /// as they are, doubles as Swift prints them, and anything longer than `limit` characters
    /// is cut with an ellipsis. Not a serialization format: use `Codable` for that.
    public func summary(limit: Int = 80) -> String {
        let text = describe(depth: 0)
        guard limit > 0, text.count > limit else { return text }
        return text.prefix(limit - 1) + "…"
    }

    private func describe(depth: Int) -> String {
        switch self {
        case .null: return "null"
        case .bool(let value): return value ? "true" : "false"
        case .int(let value): return String(value)
        case .double(let value): return "\(value)"
        case .string(let value): return value.replacingOccurrences(of: "\n", with: "⏎")
        case .vector(let values): return "(" + values.map { "\($0)" }.joined(separator: ", ") + ")"
        case .matrix(let matrix): return "\(matrix.rows)×\(matrix.columns) matrix"
        case .color(let color):
            func byte(_ value: Double) -> String {
                let clamped = Int((min(max(value, 0), 1) * 255).rounded())
                return (clamped < 16 ? "0" : "") + String(clamped, radix: 16, uppercase: true)
            }
            let alpha = color.alpha < 1 ? byte(color.alpha) : ""
            return "#" + byte(color.red) + byte(color.green) + byte(color.blue) + alpha
        case .array(let items):
            // Inner strings are quoted so ["a, b"] is not read as two items.
            guard depth < 3 else { return "[…]" }
            return "[" + items.map { $0.element(depth: depth + 1) }.joined(separator: ", ") + "]"
        case .object(let fields):
            guard depth < 3 else { return "{…}" }
            return "{" + fields.sorted { $0.key < $1.key }
                .map { "\($0.key): \($0.value.element(depth: depth + 1))" }.joined(separator: ", ") + "}"
        case .data(let data): return "\(data.count) bytes"
        case .handle: return "handle"
        }
    }

    private func element(depth: Int) -> String {
        if case .string(let text) = self { return "\"" + text.replacingOccurrences(of: "\n", with: "⏎") + "\"" }
        return describe(depth: depth)
    }
}
