import NodeGraphCore
import Testing
@testable import TemperaturePack

@Test func numbersFeedTemperaturesAndTemperaturesFeedNumbers() {
    var types = TypeRegistry()
    registerTemperatureType(in: &types)
    #expect(types.connectability(from: .init("number"), to: .temperature) == .accepted)
    #expect(types.connectability(from: .temperature, to: .init("number")) == .converted)
    #expect(types.connectability(from: .temperature, to: .init("string")) == .incompatible)
}
