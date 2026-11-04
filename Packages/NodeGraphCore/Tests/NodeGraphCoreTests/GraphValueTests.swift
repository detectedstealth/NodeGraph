import Foundation
import Testing
@testable import NodeGraphCore

private func roundTrip(_ value: GraphValue) throws -> GraphValue {
    let data = try JSONEncoder().encode(value)
    return try JSONDecoder().decode(GraphValue.self, from: data)
}

@Test func integersDoublesAndBoolsNeverCollapse() throws {
    #expect(try roundTrip(.int(1)) == .int(1))
    #expect(try roundTrip(.double(1.0)) == .double(1.0))
    #expect(try roundTrip(.bool(true)) == .bool(true))
    #expect(try roundTrip(.int(1)) != .double(1.0))
    #expect(try roundTrip(.int(1)) != .bool(true))
    #expect(try roundTrip(.int(0)) != .bool(false))
}

@Test(arguments: [Int64.max, Int64.min, 9_007_199_254_740_993, 0, -1])
func int64RoundTripsExactly(_ value: Int64) throws {
    #expect(try roundTrip(.int(value)) == .int(value))
}

@Test(arguments: [0.1, Double.pi, Double.greatestFiniteMagnitude, Double.leastNonzeroMagnitude, -2.5e-300, 1e22])
func doubleRoundTripsExactly(_ value: Double) throws {
    guard case .double(let decoded) = try roundTrip(.double(value)) else {
        Issue.record("Decoded to a different case")
        return
    }
    #expect(decoded.bitPattern == value.bitPattern)
}

@Test func negativeZeroKeepsItsSign() throws {
    guard case .double(let decoded) = try roundTrip(.double(-0.0)) else {
        Issue.record("Decoded to a different case")
        return
    }
    #expect(decoded.sign == .minus)
}

@Test func nonFiniteDoublesRoundTrip() throws {
    #expect(try roundTrip(.double(.infinity)) == .double(.infinity))
    #expect(try roundTrip(.double(-.infinity)) == .double(-.infinity))
    guard case .double(let nan) = try roundTrip(.double(.nan)) else {
        Issue.record("Decoded to a different case")
        return
    }
    #expect(nan.isNaN)
    #expect(try roundTrip(.vector([1, .infinity, -.infinity])) == .vector([1, .infinity, -.infinity]))
}

@Test func compositeValuesRoundTrip() throws {
    let value: GraphValue = [
        .null,
        .string("héllo \u{1F600}"),
        .vector([1, 2.5, -3]),
        .matrix(GraphMatrix(rows: 2, columns: 2, elements: [1, 0, 0, 1])),
        .color(RGBAColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 0.4)),
        .data(Data([0, 1, 2, 255])),
        .handle(HandleID()),
        ["nested": [1, 2.0, true], "empty": []],
    ]
    #expect(try roundTrip(value) == value)
}

@Test func encodedFormIsTagged() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    #expect(String(decoding: try encoder.encode(GraphValue.int(1)), as: UTF8.self)
            == #"{"type":"int","value":1}"#)
    #expect(String(decoding: try encoder.encode(GraphValue.null), as: UTF8.self)
            == #"{"type":"null"}"#)
}

@Test func encodingIsDeterministicWithSortedKeys() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let value: GraphValue = ["b": 1, "a": 2, "c": 3]
    let first = try encoder.encode(value)
    for _ in 0..<10 { #expect(try encoder.encode(value) == first) }
}

@Test func malformedInputThrows() {
    let decoder = JSONDecoder()
    #expect(throws: DecodingError.self) {
        try decoder.decode(GraphValue.self, from: Data(#"{"type":"bogus"}"#.utf8))
    }
    #expect(throws: DecodingError.self) {
        try decoder.decode(GraphValue.self, from: Data(#"{"type":"int","value":1.5}"#.utf8))
    }
    #expect(throws: DecodingError.self) {
        try decoder.decode(GraphValue.self, from: Data(#"{"type":"double","value":"huge"}"#.utf8))
    }
    #expect(throws: DecodingError.self) {
        try decoder.decode(
            GraphValue.self,
            from: Data(#"{"type":"matrix","value":{"rows":2,"columns":2,"elements":[1]}}"#.utf8))
    }
}

@Test func literalsMapToExpectedCases() {
    #expect(GraphValue.int(3) == 3)
    #expect(GraphValue.double(3) == 3.0)
    #expect(GraphValue.bool(true) == true)
    #expect(GraphValue.string("x") == "x")
    #expect(GraphValue.null == nil)
}
