import Testing
@testable import NodeGraphCore

@Test func schemaVersionStartsAtOne() {
    #expect(NodeGraphCore.documentSchemaVersion == 1)
}
