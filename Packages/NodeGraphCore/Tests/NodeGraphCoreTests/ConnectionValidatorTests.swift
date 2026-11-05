import Foundation
import Testing
@testable import NodeGraphCore

private let gray = RGBAColor(red: 0.5, green: 0.5, blue: 0.5)

private struct Fixture {
    var context: ValidationContext
    var validator = ConnectionValidator()

    init() {
        var types = TypeRegistry()
        types.register(PortTypeInfo(type: "number", displayName: "Number", color: gray, acceptsFrom: ["int"]))
        types.register(PortTypeInfo(type: "int", displayName: "Int", color: gray))
        types.register(PortTypeInfo(type: "string", displayName: "String", color: gray))
        var nodes = NodeRegistry()
        nodes.register(NodeDefinition(typeID: "pass", displayName: "Pass", ports: [
            PortDefinition(id: "in", direction: .input, type: "number"),
            PortDefinition(id: "out", direction: .output, type: "number"),
            PortDefinition(id: "int", direction: .output, type: "int"),
            PortDefinition(id: "text", direction: .output, type: "string"),
            PortDefinition(id: "fire", direction: .output, kind: .trigger),
            PortDefinition(id: "go", direction: .input, kind: .trigger),
            PortDefinition(id: "many", direction: .input, type: "number", allowsMultipleLinks: true),
            PortDefinition(id: "solo", direction: .output, type: "number", allowsMultipleLinks: false),
        ]))
        context = ValidationContext(graph: Graph(), nodes: nodes, types: types)
    }

    mutating func addNode() -> NodeID {
        let node = Node(typeID: "pass")
        context.graph.insert(node)
        return node.id
    }

    @discardableResult
    mutating func link(_ a: NodeID, _ out: PortID, _ b: NodeID, _ input: PortID) -> LinkID {
        let link = Link(sourceNode: a, sourcePort: out, targetNode: b, targetPort: input)
        context.graph.insert(link)
        return link.id
    }

    func proposal(_ a: NodeID, _ out: PortID, _ b: NodeID, _ input: PortID) -> ConnectionProposal {
        ConnectionProposal(
            source: PortAddress(node: a, port: out, direction: .output),
            target: PortAddress(node: b, port: input, direction: .input))
    }

    func check(_ a: NodeID, _ out: PortID, _ b: NodeID, _ input: PortID) -> ConnectionCheck {
        validator.check(proposal(a, out, b, input), in: context)
    }
}

private func codes(_ check: ConnectionCheck) -> [DiagnosticCode] { check.diagnostics.map(\.code) }

@Test func validConnectionIsAllowed() {
    var f = Fixture()
    let a = f.addNode(), b = f.addNode()
    let result = f.check(a, "out", b, "in")
    #expect(result.isAllowed && result.diagnostics.isEmpty && result.replacedLinks.isEmpty)
}

@Test func missingNodeAndPortAreReported() {
    var f = Fixture()
    let a = f.addNode()
    #expect(codes(f.check(a, "out", NodeID(), "in")) == [.missingNode])
    #expect(codes(f.check(a, "nope", a, "in")).contains(.missingPort))
}

@Test func unregisteredTypeIsReported() {
    var f = Fixture()
    let a = f.addNode()
    let ghost = Node(typeID: "ghost")
    f.context.graph.insert(ghost)
    #expect(codes(f.check(a, "out", ghost.id, "in")) == [.unknownNodeType])
}

@Test func wrongDirectionIsRejectedAndOrientedFixesIt() {
    var f = Fixture()
    let a = f.addNode(), b = f.addNode()
    let reversed = ConnectionProposal(
        source: PortAddress(node: b, port: "in", direction: .input),
        target: PortAddress(node: a, port: "out", direction: .output))
    #expect(f.validator.check(reversed, in: f.context).diagnostics.map(\.code) == [.wrongDirection, .wrongDirection])
    #expect(f.validator.check(reversed.oriented(), in: f.context).isAllowed)
}

@Test func selfLinkIsRejectedOnceWithoutCycleNoise() {
    var f = Fixture()
    let a = f.addNode()
    #expect(codes(f.check(a, "out", a, "in")) == [.selfLink])
}

@Test func kindAndTypeMismatchAreRejected() {
    var f = Fixture()
    let a = f.addNode(), b = f.addNode()
    #expect(codes(f.check(a, "fire", b, "in")) == [.kindMismatch])
    #expect(codes(f.check(a, "text", b, "in")) == [.typeMismatch])
    #expect(f.check(a, "int", b, "in").isAllowed)
    #expect(f.check(a, "fire", b, "go").isAllowed)
}

@Test func duplicateLinkIsRejected() {
    var f = Fixture()
    let a = f.addNode(), b = f.addNode()
    let existing = f.link(a, "out", b, "in")
    let result = f.check(a, "out", b, "in")
    #expect(codes(result) == [.duplicateLink])
    #expect(result.diagnostics.first?.link == existing)
}

@Test func cyclesAreRejectedIncludingIndirectOnes() {
    var f = Fixture()
    let a = f.addNode(), b = f.addNode(), c = f.addNode()
    f.link(a, "out", b, "in")
    f.link(b, "out", c, "in")
    #expect(codes(f.check(c, "out", a, "in")) == [.cycle])
    #expect(f.check(a, "out", c, "many").isAllowed)
}

@Test func singleInputReplacesExistingLink() {
    var f = Fixture()
    let a = f.addNode(), b = f.addNode(), c = f.addNode()
    let existing = f.link(a, "out", c, "in")
    let result = f.check(b, "out", c, "in")
    #expect(result.isAllowed)
    #expect(result.replacedLinks == [existing])
}

@Test func multiLinkInputKeepsExistingLinks() {
    var f = Fixture()
    let a = f.addNode(), b = f.addNode(), c = f.addNode()
    f.link(a, "out", c, "many")
    #expect(f.check(b, "out", c, "many").replacedLinks.isEmpty)
}

@Test func singleLinkOutputReplacesItsExistingLink() {
    var f = Fixture()
    let a = f.addNode(), b = f.addNode(), c = f.addNode()
    let existing = f.link(a, "solo", b, "in")
    #expect(f.check(a, "solo", c, "in").replacedLinks == [existing])
}

@Test func rejectedConnectionReplacesNothing() {
    var f = Fixture()
    let a = f.addNode(), b = f.addNode()
    f.link(a, "out", b, "in")
    #expect(f.check(a, "text", b, "in").replacedLinks.isEmpty)
}

// MARK: Custom rules

private struct ForbidNodePair: ConnectionRule {
    let id = "forbidPair"
    let summary = "Nodes a and b may not be linked."
    var a: NodeID
    var b: NodeID

    func check(_ proposal: ConnectionProposal, in context: ValidationContext) -> [GraphDiagnostic] {
        proposal.source.node == a && proposal.target.node == b
            ? [GraphDiagnostic(code: "domain.forbidden", message: "Not allowed here.", node: b)]
            : []
    }
}

@Test func domainRulesAddToAndReplaceStandardRules() {
    var f = Fixture()
    let a = f.addNode(), b = f.addNode()
    f.validator = f.validator.adding(ForbidNodePair(a: a, b: b))
    #expect(codes(f.check(a, "out", b, "in")) == ["domain.forbidden"])
    #expect(f.check(b, "out", a, "in").isAllowed)

    // A domain that allows cycles drops the cycle rule.
    f.validator = ConnectionValidator().removing(ruleID: "noCycle")
    f.link(a, "out", b, "in")
    #expect(f.check(b, "out", a, "in").isAllowed)
}

@Test func warningsDoNotBlockAConnection() {
    struct Warn: ConnectionRule {
        let id = "warn"
        let summary = "Always warns."
        func check(_ proposal: ConnectionProposal, in context: ValidationContext) -> [GraphDiagnostic] {
            [GraphDiagnostic(severity: .warning, code: "domain.warn", message: "Careful.")]
        }
    }
    var f = Fixture()
    let a = f.addNode(), b = f.addNode()
    f.validator = f.validator.adding(Warn())
    let result = f.check(a, "out", b, "in")
    #expect(result.isAllowed && result.diagnostics.count == 1)
}

// MARK: Whole-graph validation

private struct RequiresTwoNodes: GraphRule {
    let id = "twoNodes"
    let summary = "A graph needs at least two nodes."
    func check(in context: ValidationContext) -> [GraphDiagnostic] {
        context.graph.nodes.count < 2
            ? [GraphDiagnostic(code: "domain.tooSmall", message: "Add more nodes.")] : []
    }
}

@Test func cleanGraphHasNoDiagnostics() {
    var f = Fixture()
    let a = f.addNode(), b = f.addNode()
    f.link(a, "out", b, "in")
    #expect(GraphValidator().validate(f.context).isEmpty)
}

@Test func graphValidationFindsBadLinksWithLinkReferences() {
    var f = Fixture()
    let a = f.addNode(), b = f.addNode(), c = f.addNode()
    f.link(a, "out", b, "in")
    let bad = f.link(c, "text", b, "in")
    let found = GraphValidator().validate(f.context)
    #expect(found.contains { $0.code == .typeMismatch && $0.link == bad })
}

@Test func graphValidationFlagsEveryLinkIntoAFullSingleLinkInput() {
    var f = Fixture()
    let a = f.addNode(), b = f.addNode(), c = f.addNode()
    f.link(a, "out", c, "in")
    f.link(b, "out", c, "in")
    #expect(GraphValidator().validate(f.context).filter { $0.code == .tooManyLinks }.count == 2)
}

@Test func graphValidationFindsExistingCycles() {
    var f = Fixture()
    let a = f.addNode(), b = f.addNode()
    f.link(a, "out", b, "in")
    f.link(b, "out", a, "in")
    #expect(GraphValidator().validate(f.context).contains { $0.code == .cycle })
}

@Test func graphValidationChecksNodeTypesAndProperties() {
    var f = Fixture()
    f.context.graph.insert(Node(typeID: "ghost"))
    f.context.graph.insert(Node(typeID: "pass", properties: ["nope": true]))
    var registry = f.context.nodes
    registry.register(NodeDefinition(
        typeID: "gain", displayName: "Gain",
        properties: [PropertyDefinition(id: "g", displayName: "G", kind: .int(min: 0, max: 5), defaultValue: 1)]))
    f.context.nodes = registry
    f.context.graph.insert(Node(typeID: "gain", properties: ["g": 99]))
    let found = GraphValidator().validate(f.context)
    #expect(found.map(\.code) == [.unknownNodeType, .unknownProperty, .invalidProperty])
}

@Test func graphRulesRunAndDiagnosticsRoundTrip() throws {
    var f = Fixture()
    _ = f.addNode()
    let found = GraphValidator(graphRules: [RequiresTwoNodes()]).validate(f.context)
    #expect(found.map(\.code) == ["domain.tooSmall"])
    let data = try JSONEncoder().encode(found)
    #expect(try JSONDecoder().decode([GraphDiagnostic].self, from: data) == found)
}

// MARK: Feedback nodes

private func feedbackFixture() -> (Fixture, add: NodeID, memory: NodeID) {
    var f = Fixture()
    f.context.nodes.register(NodeDefinition(typeID: "memory", displayName: "Memory", ports: [
        PortDefinition(id: "in", direction: .input, type: "number"),
        PortDefinition(id: "out", direction: .output, type: "number"),
    ], isFeedback: true))
    let add = f.addNode()
    let memory = Node(typeID: "memory")
    f.context.graph.insert(memory)
    return (f, add, memory.id)
}

@Test func aLoopThroughAFeedbackNodeIsAllowed() {
    var (f, add, memory) = feedbackFixture()
    f.link(add, "out", memory, "in")
    // memory -> add would close add -> memory -> add, but memory's output is the previous pass.
    #expect(f.check(memory, "out", add, "in").isAllowed)
    f.link(memory, "out", add, "in")
    #expect(GraphValidator().validate(f.context).isEmpty)
}

@Test func aLoopWithoutAFeedbackNodeIsStillRejected() {
    var (f, add, _) = feedbackFixture()
    let other = f.addNode()
    f.link(add, "out", other, "in")
    #expect(codes(f.check(other, "out", add, "in")) == [.cycle])
}

@Test func feedbackDoesNotHideAnUnrelatedCycle() {
    var (f, a, memory) = feedbackFixture()
    let b = f.addNode(), c = f.addNode()
    f.link(a, "out", b, "in"); f.link(b, "out", c, "in")
    f.link(memory, "out", a, "in")
    #expect(codes(f.check(c, "out", a, "in")) == [.cycle])
}
