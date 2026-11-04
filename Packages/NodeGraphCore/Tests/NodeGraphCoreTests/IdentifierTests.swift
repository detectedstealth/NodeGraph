import Foundation
import Testing
@testable import NodeGraphCore

@Test func identifiersAreUnique() {
    #expect(NodeID() != NodeID())
}

@Test func identifierRoundTripsAsBareUUIDString() throws {
    let id = NodeID(uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    let data = try JSONEncoder().encode([id])
    #expect(String(decoding: data, as: UTF8.self) == "[\"00000000-0000-0000-0000-000000000001\"]")
    #expect(try JSONDecoder().decode([NodeID].self, from: data) == [id])
}

@Test func identifiersSortDeterministically() {
    let a = LinkID(uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    let b = LinkID(uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
    #expect([b, a].sorted() == [a, b])
}

@Test func portIDAndTypeEncodeAsBareStrings() throws {
    let data = try JSONEncoder().encode(["a": PortID("in"), "b": PortID("out")])
    let decoded = try JSONDecoder().decode([String: PortID].self, from: data)
    #expect(decoded["a"] == "in")
    let type = try JSONDecoder().decode([PortType].self, from: Data("[\"number\"]".utf8))
    #expect(type == ["number"])
}

@Test func portAddressRoundTrips() throws {
    let address = PortAddress(node: NodeID(), port: "value", direction: .output)
    let data = try JSONEncoder().encode(address)
    #expect(try JSONDecoder().decode(PortAddress.self, from: data) == address)
}
