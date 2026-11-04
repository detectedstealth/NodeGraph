import Testing
@testable import NodeGraphCore

private let gray = RGBAColor(red: 0.5, green: 0.5, blue: 0.5)

private func makeRegistry() -> TypeRegistry {
    var types = TypeRegistry()
    types.register(PortTypeInfo(type: "number", displayName: "Number", color: gray, acceptsFrom: ["int"]))
    types.register(PortTypeInfo(type: "int", displayName: "Integer", color: gray))
    types.register(PortTypeInfo(type: "string", displayName: "String", color: gray))
    types.registerConversion(from: "number", to: "string")
    return types
}

@Test func identicalTypesConnect() {
    #expect(makeRegistry().connectability(from: "string", to: "string") == .identical)
}

@Test func unregisteredTypesOnlyMatchThemselves() {
    let types = TypeRegistry()
    #expect(types.connectability(from: "x", to: "x") == .identical)
    #expect(types.connectability(from: "x", to: "y") == .incompatible)
}

@Test func anyConnectsBothWays() {
    let types = makeRegistry()
    #expect(types.connectability(from: .any, to: "int") == .identical)
    #expect(types.connectability(from: "string", to: .any) == .identical)
}

@Test func acceptsFromIsDirectional() {
    let types = makeRegistry()
    #expect(types.connectability(from: "int", to: "number") == .accepted)
    #expect(types.connectability(from: "number", to: "int") == .incompatible)
}

@Test func conversionIsDirectional() {
    let types = makeRegistry()
    #expect(types.connectability(from: "number", to: "string") == .converted)
    #expect(types.connectability(from: "string", to: "number") == .incompatible)
    #expect(Connectability.converted.isConnectable)
    #expect(!Connectability.incompatible.isConnectable)
}

@Test func registrationOrderIsPreservedAndReplaceKeepsPosition() {
    var types = makeRegistry()
    #expect(types.registeredTypes.map(\.type) == ["number", "int", "string"])
    types.register(PortTypeInfo(type: "int", displayName: "Whole", color: gray))
    #expect(types.registeredTypes.map(\.type) == ["number", "int", "string"])
    #expect(types.info(for: "int")?.displayName == "Whole")
}
