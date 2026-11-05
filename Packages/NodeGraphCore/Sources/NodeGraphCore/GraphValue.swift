import Foundation

/// Identifies a large or opaque payload (a video frame, a point cloud) held outside the graph.
public struct HandleID: GraphIdentifier {
    public let uuid: UUID
    public init(uuid: UUID) { self.uuid = uuid }
}

/// A dense row-major matrix of doubles.
public struct GraphMatrix: Hashable, Sendable, Codable {
    public var rows: Int
    public var columns: Int
    /// Row-major elements; `elements.count == rows * columns`.
    public var elements: [Double]

    public init(rows: Int, columns: Int, elements: [Double]) {
        precondition(rows >= 0 && columns >= 0 && elements.count == rows * columns,
                     "GraphMatrix element count must equal rows * columns")
        self.rows = rows
        self.columns = columns
        self.elements = elements
    }
}

/// A runtime value that flows through data ports and is stored in node properties.
///
/// Integers and doubles are distinct cases and never convert implicitly. The `Codable`
/// form is tagged (`{"type": "int", "value": 1}`), so `1`, `1.0` and `true` always decode
/// back to the case they were encoded from, and `Int64` values are exact.
///
/// Because `.double` can hold NaN, `==` follows IEEE rules for that case.
public enum GraphValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case vector([Double])
    case matrix(GraphMatrix)
    case color(RGBAColor)
    case array([GraphValue])
    case object([String: GraphValue])
    /// Small inline binary payload. Large data should use ``handle(_:)``.
    case data(Data)
    case handle(HandleID)
}

// MARK: - Typed access

extension GraphValue {
    public var boolValue: Bool? {
        if case .bool(let v) = self { v } else { nil }
    }

    public var intValue: Int64? {
        if case .int(let v) = self { v } else { nil }
    }

    /// The value of a `.double` only. See ``numberValue`` to accept integers too.
    public var doubleValue: Double? {
        if case .double(let v) = self { v } else { nil }
    }

    /// The value of a `.double` or `.int` as a `Double`. Integers beyond 2^53 lose precision.
    public var numberValue: Double? {
        switch self {
        case .double(let v): v
        case .int(let v): Double(v)
        default: nil
        }
    }

    public var stringValue: String? {
        if case .string(let v) = self { v } else { nil }
    }
}

// MARK: - Codable

extension GraphValue: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case value
    }

    private enum Tag: String, Codable {
        case null, bool, int, double, string, vector, matrix, color, array, object, data, handle
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Tag.self, forKey: .type) {
        case .null: self = .null
        case .bool: self = .bool(try container.decode(Bool.self, forKey: .value))
        case .int: self = .int(try container.decode(Int64.self, forKey: .value))
        case .double: self = .double(try Self.decodeDouble(from: container))
        case .string: self = .string(try container.decode(String.self, forKey: .value))
        case .vector: self = .vector(try Self.decodeDoubles(from: container))
        case .matrix:
            let matrix = try container.decode(GraphMatrix.self, forKey: .value)
            guard matrix.rows >= 0, matrix.columns >= 0,
                  matrix.elements.count == matrix.rows * matrix.columns
            else {
                throw DecodingError.dataCorruptedError(
                    forKey: .value, in: container,
                    debugDescription: "Matrix element count does not match rows * columns")
            }
            self = .matrix(matrix)
        case .color: self = .color(try container.decode(RGBAColor.self, forKey: .value))
        case .array: self = .array(try container.decode([GraphValue].self, forKey: .value))
        case .object: self = .object(try container.decode([String: GraphValue].self, forKey: .value))
        case .data: self = .data(try container.decode(Data.self, forKey: .value))
        case .handle: self = .handle(try container.decode(HandleID.self, forKey: .value))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .null: try container.encode(Tag.null, forKey: .type)
        case .bool(let v): try encode(.bool, v, in: &container)
        case .int(let v): try encode(.int, v, in: &container)
        case .double(let v):
            try container.encode(Tag.double, forKey: .type)
            try container.encode(Self.encodedDouble(v), forKey: .value)
        case .string(let v): try encode(.string, v, in: &container)
        case .vector(let v):
            try container.encode(Tag.vector, forKey: .type)
            try container.encode(v.map(Self.encodedDouble), forKey: .value)
        case .matrix(let v): try encode(.matrix, v, in: &container)
        case .color(let v): try encode(.color, v, in: &container)
        case .array(let v): try encode(.array, v, in: &container)
        case .object(let v): try encode(.object, v, in: &container)
        case .data(let v): try encode(.data, v, in: &container)
        case .handle(let v): try encode(.handle, v, in: &container)
        }
    }

    private func encode<T: Encodable>(
        _ tag: Tag, _ value: T, in container: inout KeyedEncodingContainer<CodingKeys>
    ) throws {
        try container.encode(tag, forKey: .type)
        try container.encode(value, forKey: .value)
    }

    // JSON has no NaN or infinity, so non-finite doubles travel as strings.
    private enum DoubleCoding: Codable {
        case number(Double)
        case special(String)

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Double.self) {
                self = .number(number)
            } else {
                self = .special(try container.decode(String.self))
            }
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .number(let v): try container.encode(v)
            case .special(let s): try container.encode(s)
            }
        }
    }

    private static func encodedDouble(_ value: Double) -> DoubleCoding {
        if value.isNaN { return .special("nan") }
        if value.isInfinite { return .special(value < 0 ? "-inf" : "inf") }
        return .number(value)
    }

    private static func double(from coding: DoubleCoding, at key: CodingKeys,
                               in container: KeyedDecodingContainer<CodingKeys>) throws -> Double {
        switch coding {
        case .number(let v): return v
        case .special("nan"): return .nan
        case .special("inf"): return .infinity
        case .special("-inf"): return -.infinity
        case .special(let s):
            throw DecodingError.dataCorruptedError(
                forKey: key, in: container, debugDescription: "Unknown double value \"\(s)\"")
        }
    }

    private static func decodeDouble(from container: KeyedDecodingContainer<CodingKeys>) throws -> Double {
        try double(from: container.decode(DoubleCoding.self, forKey: .value), at: .value, in: container)
    }

    private static func decodeDoubles(from container: KeyedDecodingContainer<CodingKeys>) throws -> [Double] {
        try container.decode([DoubleCoding].self, forKey: .value)
            .map { try double(from: $0, at: .value, in: container) }
    }
}

// MARK: - Literals

extension GraphValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension GraphValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int64) { self = .int(value) }
}

extension GraphValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .double(value) }
}

extension GraphValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension GraphValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: GraphValue...) { self = .array(elements) }
}

extension GraphValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, GraphValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

extension GraphValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}
