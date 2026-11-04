import Foundation
import Testing
@testable import NodeGraphCore

private func property(_ kind: PropertyKind, default value: GraphValue) -> PropertyDefinition {
    PropertyDefinition(id: "p", displayName: "P", kind: kind, defaultValue: value)
}

@Test func intRangeIsEnforced() throws {
    let p = property(.int(min: 0, max: 10), default: 5)
    try p.validate(.int(0))
    try p.validate(.int(10))
    #expect(throws: PropertyValidationError.outOfRange) { try p.validate(.int(11)) }
    #expect(throws: PropertyValidationError.outOfRange) { try p.validate(.int(-1)) }
}

@Test func numericKindsAreStrict() {
    let int = property(.int(), default: 0)
    let double = property(.double(), default: 0.0)
    #expect(!int.isValid(.double(1)))
    #expect(!double.isValid(.int(1)))
    #expect(int.isValid(.int(1)))
    #expect(double.isValid(.double(1)))
}

@Test func doubleRejectsNonFiniteAndOutOfRange() {
    let p = property(.double(min: 0, max: 1), default: 0.5)
    #expect(p.isValid(.double(0.5)))
    #expect(!p.isValid(.double(1.5)))
    #expect(!p.isValid(.double(.nan)))
    #expect(!property(.double(), default: 0.0).isValid(.double(.infinity)))
}

@Test func choiceMustBeListed() throws {
    let p = property(.choice([PropertyChoice(value: "a", label: "A")]), default: "a")
    try p.validate("a")
    #expect(throws: PropertyValidationError.notAChoice("b")) { try p.validate("b") }
}

@Test func vectorDimensionIsChecked() {
    let p = property(.vector(dimension: 3), default: .vector([0, 0, 0]))
    #expect(p.isValid(.vector([1, 2, 3])))
    #expect(throws: PropertyValidationError.wrongDimension(expected: 3, actual: 2)) {
        try p.validate(.vector([1, 2]))
    }
}

@Test func typeMismatchReportsExpectedType() {
    let p = property(.bool, default: false)
    #expect(throws: PropertyValidationError.typeMismatch(expected: "bool")) {
        try p.validate("yes")
    }
}

@Test func customKindAcceptsAnyValue() {
    let p = property(.custom("curve"), default: .null)
    #expect(p.isValid(.null))
    #expect(p.isValid([1, 2]))
}

@Test func clampLimitsNumbers() {
    let i = property(.int(min: 0, max: 10), default: 0)
    #expect(i.clamped(.int(99)) == .int(10))
    #expect(i.clamped(.int(-5)) == .int(0))
    let d = property(.double(min: 0, max: 1), default: 0.0)
    #expect(d.clamped(.double(2)) == .double(1))
    #expect(d.clamped("x") == "x")
}

@Test func definitionRoundTripsThroughJSON() throws {
    let p = PropertyDefinition(
        id: "gain", displayName: "Gain",
        kind: .double(min: 0, max: 10, step: 0.5), defaultValue: .double(1))
    let data = try JSONEncoder().encode(p)
    #expect(try JSONDecoder().decode(PropertyDefinition.self, from: data) == p)
}
