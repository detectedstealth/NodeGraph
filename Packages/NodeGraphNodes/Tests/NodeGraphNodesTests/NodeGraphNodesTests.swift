import Foundation
import NodeGraphCore
import Testing
@testable import NodeGraphNodes

// MARK: Helpers (public API only, the way an app would use the packs)

private func standardRegistries() -> (NodeRegistry, TypeRegistry) {
    var nodes = NodeRegistry()
    var types = TypeRegistry()
    StandardPack.register(nodes: &nodes, types: &types)
    return (nodes, types)
}

/// Runs one node in isolation.
private func evaluate(
    _ type: NodeTypeID, _ inputs: [PortID: GraphValue] = [:], properties: [PropertyID: GraphValue] = [:]
) async throws -> NodeRunResult {
    let (nodes, _) = standardRegistries()
    let node = Node(typeID: type, properties: properties)
    let definition = try #require(nodes.definition(for: node))
    let context = NodeContext(node: node, definition: definition, linkedInputs: inputs)
    return await NodeInvocation.run(node: node, registry: nodes, context: context)
}

private func result(_ type: NodeTypeID, _ inputs: [PortID: GraphValue] = [:], properties: [PropertyID: GraphValue] = [:]) async throws -> GraphValue? {
    try await evaluate(type, inputs, properties: properties).outputs?["result"]
}

private func failure(_ type: NodeTypeID, _ inputs: [PortID: GraphValue] = [:]) async throws -> String? {
    if case .failure(let failure) = try await evaluate(type, inputs).outcome { failure.message } else { nil }
}

/// Builds graphs through the editor and runs them.
private struct Rig {
    let editor: GraphEditor

    init() {
        let (nodes, types) = standardRegistries()
        editor = GraphEditor(nodes: nodes, types: types)
    }

    @discardableResult
    func add(_ type: NodeTypeID, _ properties: [PropertyID: GraphValue] = [:], mode: NodeMode = .always) throws -> NodeID {
        let node = Node(typeID: type, mode: mode, properties: properties)
        try editor.apply(.addNode(node: node))
        return node.id
    }

    func link(_ a: NodeID, _ out: PortID, _ b: NodeID, _ input: PortID) throws {
        try editor.connect(ConnectionProposal(
            source: PortAddress(node: a, port: out, direction: .output),
            target: PortAddress(node: b, port: input, direction: .input)))
    }

    func runner() throws -> GraphRunner {
        try GraphRunner(graph: editor.graph, registry: editor.nodes)
    }

    func step() async throws -> TickResult { await (try runner()).step() }
}

// MARK: Math

struct MathCase: Sendable, CustomTestStringConvertible {
    var type: NodeTypeID
    var inputs: [PortID: GraphValue]
    var expected: Double
    var testDescription: String { "\(type) \(inputs) = \(expected)" }
}

private let mathCases: [MathCase] = [
    .init(type: "math.add", inputs: ["a": 2.0, "b": 3.0], expected: 5),
    .init(type: "math.add", inputs: ["a": .int(2), "b": 3.5], expected: 5.5),
    .init(type: "math.add", inputs: [:], expected: 0),
    .init(type: "math.subtract", inputs: ["a": 2.0, "b": 3.0], expected: -1),
    .init(type: "math.multiply", inputs: ["a": 4.0, "b": 2.5], expected: 10),
    .init(type: "math.multiply", inputs: ["a": 4.0], expected: 4),
    .init(type: "math.divide", inputs: ["a": 9.0, "b": 2.0], expected: 4.5),
    .init(type: "math.divide", inputs: ["a": 9.0], expected: 9),
    .init(type: "math.modulo", inputs: ["a": 7.0, "b": 3.0], expected: 1),
    .init(type: "math.modulo", inputs: ["a": -7.0, "b": 3.0], expected: -1),
    .init(type: "math.power", inputs: ["a": 2.0, "b": 10.0], expected: 1024),
    .init(type: "math.min", inputs: ["a": 2.0, "b": -3.0], expected: -3),
    .init(type: "math.max", inputs: ["a": 2.0, "b": -3.0], expected: 2),
    .init(type: "math.negate", inputs: ["value": 5.0], expected: -5),
    .init(type: "math.abs", inputs: ["value": -5.0], expected: 5),
    .init(type: "math.floor", inputs: ["value": 2.7], expected: 2),
    .init(type: "math.floor", inputs: ["value": -2.1], expected: -3),
    .init(type: "math.ceil", inputs: ["value": 2.1], expected: 3),
    .init(type: "math.round", inputs: ["value": 2.5], expected: 3),
    .init(type: "math.round", inputs: ["value": -2.5], expected: -3),
    .init(type: "math.sqrt", inputs: ["value": 9.0], expected: 3),
    .init(type: "math.sin", inputs: ["value": 0.0], expected: 0),
    .init(type: "math.cos", inputs: ["value": 0.0], expected: 1),
    .init(type: "math.clamp", inputs: ["value": 5.0, "min": 0.0, "max": 3.0], expected: 3),
    .init(type: "math.clamp", inputs: ["value": -5.0, "min": 0.0, "max": 3.0], expected: 0),
    .init(type: "math.clamp", inputs: ["value": 2.0, "min": 0.0, "max": 3.0], expected: 2),
    .init(type: "math.lerp", inputs: ["a": 10.0, "b": 20.0, "t": 0.25], expected: 12.5),
    .init(type: "math.lerp", inputs: ["a": 10.0, "b": 20.0, "t": 2.0], expected: 30),
]

@Test(arguments: mathCases)
func mathNodesCompute(_ c: MathCase) async throws {
    #expect(try await result(c.type, c.inputs) == .double(c.expected))
}

@Test(arguments: [
    ("math.divide", ["a": 1.0, "b": 0.0] as [PortID: GraphValue], "Division by zero"),
    ("math.modulo", ["a": 1.0, "b": 0.0], "Modulo by zero"),
    ("math.sqrt", ["value": -1.0], "negative"),
    ("math.power", ["a": 10.0, "b": 400.0], "finite"),
    ("math.multiply", ["a": 1e308, "b": 10.0], "finite"),
    ("math.clamp", ["value": 1.0, "min": 5.0, "max": 1.0], "minimum is above"),
] as [(NodeTypeID, [PortID: GraphValue], String)])
func mathErrorsAreFailuresNotInfinities(_ type: NodeTypeID, _ inputs: [PortID: GraphValue], _ message: String) async throws {
    let text = try #require(try await failure(type, inputs))
    #expect(text.contains(message))
}

@Test func mathRejectsNonNumbers() async throws {
    let text = try #require(try await failure("math.add", ["a": "five"]))
    #expect(text.contains("invalidInput"))
}

// MARK: Logic

@Test(arguments: [
    ("logic.and", true, true, true), ("logic.and", true, false, false), ("logic.and", false, false, false),
    ("logic.or", false, false, false), ("logic.or", true, false, true), ("logic.or", true, true, true),
    ("logic.xor", true, true, false), ("logic.xor", true, false, true), ("logic.xor", false, false, false),
] as [(NodeTypeID, Bool, Bool, Bool)])
func booleanOperatorsFollowTheirTruthTables(_ type: NodeTypeID, _ a: Bool, _ b: Bool, _ expected: Bool) async throws {
    #expect(try await result(type, ["a": .bool(a), "b": .bool(b)]) == .bool(expected))
}

@Test func notInvertsAndDefaultsToFalse() async throws {
    #expect(try await result("logic.not", ["value": true]) == false)
    #expect(try await result("logic.not") == true)
}

@Test(arguments: [
    ("==", 1.0, 1.0, true), ("==", 1.0, 2.0, false), ("!=", 1.0, 2.0, true), ("!=", 1.0, 1.0, false),
    ("<", 1.0, 2.0, true), ("<", 2.0, 2.0, false), ("<=", 2.0, 2.0, true), ("<=", 3.0, 2.0, false),
    (">", 3.0, 2.0, true), (">", 2.0, 2.0, false), (">=", 2.0, 2.0, true), (">=", 1.0, 2.0, false),
] as [(String, Double, Double, Bool)])
func compareImplementsEveryOperator(_ op: String, _ a: Double, _ b: Double, _ expected: Bool) async throws {
    #expect(try await result("logic.compare", ["a": .double(a), "b": .double(b)], properties: ["operator": .string(op)]) == .bool(expected))
}

@Test func compareRejectsAnUnknownOperatorAndTheDefinitionLimitsTheChoices() async throws {
    let message: String? = if case .failure(let f) = try await evaluate("logic.compare", properties: ["operator": "~"]).outcome { f.message } else { nil }
    #expect(message?.contains("Unknown comparison") == true)
    let (nodes, _) = standardRegistries()
    let property = try #require(nodes.definition(for: "logic.compare")?.property("operator"))
    #expect(!property.isValid("~") && property.isValid("<="))
}

@Test func selectReadsOnlyTheChosenBranch() async throws {
    #expect(try await result("logic.select", ["condition": true, "ifTrue": "yes"]) == "yes")
    #expect(try await result("logic.select", ["condition": false, "ifFalse": 7.0]) == 7.0)
    #expect(try await failure("logic.select", ["condition": true, "ifFalse": 1.0])?.contains("missingInput") == true)
}

// MARK: String

@Test func stringNodesTransformText() async throws {
    #expect(try await result("string.concat", ["a": "foo", "b": "bar"]) == "foobar")
    #expect(try await result("string.concat", ["a": "foo"]) == "foo")
    #expect(try await result("string.uppercase", ["value": "héllo"]) == "HÉLLO")
    #expect(try await result("string.lowercase", ["value": "ABC"]) == "abc")
    #expect(try await result("string.trim", ["value": "  hi \n"]) == "hi")
    #expect(try await result("string.replace", ["value": "a-b-c", "find": "-", "replacement": "+"]) == "a+b+c")
    #expect(try await result("string.length", ["value": "héllo 👍"]) == 7.0)
    #expect(try await result("string.contains", ["value": "hello", "search": "ell"]) == true)
    #expect(try await result("string.contains", ["value": "hello", "search": "xyz"]) == false)
    #expect(try await result("string.contains", ["value": "hello"]) == true)
}

@Test func replaceNeedsSomethingToFind() async throws {
    #expect(try await failure("string.replace", ["value": "abc"])?.contains("Nothing to find") == true)
}

@Test func parseNumberAcceptsNumbersAndRejectsText() async throws {
    #expect(try await result("string.parseNumber", ["value": " 3.5 "]) == 3.5)
    #expect(try await result("string.parseNumber", ["value": "-2e3"]) == -2000.0)
    #expect(try await result("string.parseNumber") == 0.0)
    #expect(try await failure("string.parseNumber", ["value": "abc"])?.contains("not a number") == true)
    #expect(try await failure("string.parseNumber", ["value": "inf"])?.contains("not a number") == true)
}

@Test(arguments: [
    (GraphValue.double(3), "3"), (.double(3.5), "3.5"), (.int(-7), "-7"), (.bool(true), "true"),
    (.string("s"), "s"), (.null, "null"), (.array([1.0, "a"]), "[1, a]"), (.vector([1, 2.5]), "[1, 2.5]"),
    (.object(["b": 1.0, "a": true]), "{a: true, b: 1}"),
] as [(GraphValue, String)])
func toStringDescribesAnyValue(_ value: GraphValue, _ expected: String) async throws {
    #expect(try await result("string.format", ["value": value]) == .string(expected))
}

// MARK: Utility

@Test func constantsOutputTheirProperty() async throws {
    #expect(try await evaluate("util.number", properties: ["value": 4.5]).outputs == ["value": 4.5])
    #expect(try await evaluate("util.bool", properties: ["value": true]).outputs == ["value": true])
    #expect(try await evaluate("util.string", properties: ["value": "x"]).outputs == ["value": "x"])
    #expect(try await evaluate("util.number").outputs == ["value": 0.0], "the definition's default applies")
}

@Test func rerouteAndNoteBehaveAsAdvertised() async throws {
    #expect(try await result("util.reroute", ["value": .array([1.0, "two"])]) == .array([1.0, "two"]))
    #expect(try await evaluate("util.note", properties: ["text": "remember"]).outputs == .empty)
    let (nodes, _) = standardRegistries()
    let note = try #require(nodes.definition(for: "util.note"))
    #expect(note.ports.isEmpty && note.property("text")?.kind == .string(multiline: true))
}

// MARK: Flow

@Test func delayLetsAGraphAccumulateOverPasses() async throws {
    let rig = Rig()
    let one = try rig.add("util.number", ["value": 1.0])
    let sum = try rig.add("math.add"), memory = try rig.add("flow.delay")
    try rig.link(one, "value", sum, "a")
    try rig.link(sum, "result", memory, "value")
    try rig.link(memory, "result", sum, "b")        // the previous pass's total
    let runner = try rig.runner()
    var totals: [GraphValue?] = []
    for _ in 0..<5 { totals.append(await runner.step().outputs(of: sum)?["result"]) }
    #expect(totals == [1.0, 2.0, 3.0, 4.0, 5.0])
}

@Test func everyFiresOnTheConfiguredPasses() async throws {
    let rig = Rig()
    let pulse = try rig.add("flow.every", ["interval": .int(3)]), asBool = try rig.add("flow.triggerToBool")
    try rig.link(pulse, "fire", asBool, "trigger")
    var ticks: [TickResult] = []
    for await tick in try rig.runner().run(.deterministic(fixedDelta: .milliseconds(1), ticks: 7)) { ticks.append(tick) }
    #expect(ticks.map { $0.outputs(of: asBool)?["result"] } == [true, false, false, true, false, false, true])
}

@Test func gateOnlyPassesTriggersWhileOpen() async throws {
    func fired(open: Bool) async throws -> GraphValue? {
        let rig = Rig()
        let pulse = try rig.add("flow.every"), gate = try rig.add("flow.gate")
        let flag = try rig.add("util.bool", ["value": .bool(open)]), asBool = try rig.add("flow.triggerToBool")
        try rig.link(pulse, "fire", gate, "trigger")
        try rig.link(flag, "value", gate, "open")
        try rig.link(gate, "fire", asBool, "trigger")
        return try await rig.step().outputs(of: asBool)?["result"]
    }
    #expect(try await fired(open: true) == true)
    #expect(try await fired(open: false) == false)
}

@Test func boolToTriggerFiresOnTrue() async throws {
    let rig = Rig()
    let flag = try rig.add("util.bool", ["value": true]), toTrigger = try rig.add("flow.boolToTrigger")
    let back = try rig.add("flow.triggerToBool")
    try rig.link(flag, "value", toTrigger, "value")
    try rig.link(toTrigger, "fire", back, "trigger")
    #expect(try await rig.step().outputs(of: back)?["result"] == true)
}

// MARK: Whole graphs

@Test func aSmallFormulaEvaluatesThroughTheEditorAndRunner() async throws {
    // (2 + 3) * 4
    let rig = Rig()
    let two = try rig.add("util.number", ["value": 2.0]), three = try rig.add("util.number", ["value": 3.0])
    let four = try rig.add("util.number", ["value": 4.0])
    let add = try rig.add("math.add"), multiply = try rig.add("math.multiply")
    try rig.link(two, "value", add, "a"); try rig.link(three, "value", add, "b")
    try rig.link(add, "result", multiply, "a"); try rig.link(four, "value", multiply, "b")
    let tick = try await rig.step()
    #expect(tick.succeeded)
    #expect(tick.outputs(of: multiply)?["result"] == 20.0)
}

@Test func conditionalsAndTextCompose() async throws {
    // "big" if 7 > 5 else "small", then shouted.
    let rig = Rig()
    let seven = try rig.add("util.number", ["value": 7.0]), five = try rig.add("util.number", ["value": 5.0])
    let compare = try rig.add("logic.compare", ["operator": ">"]), select = try rig.add("logic.select")
    let big = try rig.add("util.string", ["value": "big"]), small = try rig.add("util.string", ["value": "small"])
    let shout = try rig.add("string.uppercase"), length = try rig.add("string.length")
    try rig.link(seven, "value", compare, "a"); try rig.link(five, "value", compare, "b")
    try rig.link(compare, "result", select, "condition")
    try rig.link(big, "value", select, "ifTrue"); try rig.link(small, "value", select, "ifFalse")
    try rig.link(select, "result", shout, "value")
    try rig.link(shout, "result", length, "value")
    let tick = try await rig.step()
    #expect(tick.outputs(of: shout)?["result"] == "BIG")
    #expect(tick.outputs(of: length)?["result"] == 3.0)
}

@Test func theEditorRejectsMismatchedTypesBetweenPacks() throws {
    let rig = Rig()
    let text = try rig.add("util.string"), add = try rig.add("math.add")
    #expect(throws: GraphEditError.self) { try rig.link(text, "value", add, "a") }
    let number = try rig.add("util.number"), reroute = try rig.add("util.reroute")
    try rig.link(number, "value", reroute, "value")           // `any` accepts everything
    try rig.link(reroute, "result", add, "a")                  // and feeds anything
}

@Test func aPackGraphSurvivesSaveAndLoad() async throws {
    let rig = Rig()
    let a = try rig.add("util.number", ["value": 6.0]), square = try rig.add("math.multiply")
    try rig.link(a, "value", square, "a"); try rig.link(a, "value", square, "b")
    let before = try await rig.step()

    let data = try GraphDocument(graph: rig.editor.graph).encoded()
    let loaded = try GraphDocument.decode(from: data)
    let (nodes, types) = standardRegistries()
    #expect(GraphValidator().validate(ValidationContext(graph: loaded.graph, nodes: nodes, types: types)).isEmpty)
    let after = await (try GraphRunner(graph: loaded.graph, registry: nodes)).step()
    #expect(after.outputs(of: square) == before.outputs(of: square))
    #expect(after.outputs(of: square)?["result"] == 36.0)
}

// MARK: Pack hygiene

@Test func everyDefinitionIsWellFormedAndRunnable() throws {
    let (nodes, types) = standardRegistries()
    let all = nodes.registeredDefinitions
    #expect(all.count >= 40)
    #expect(Set(all.map(\.typeID)).count == all.count, "type ids must be unique")
    for definition in all {
        #expect(definition.problems.isEmpty, "\(definition.typeID): \(definition.problems)")
        #expect(nodes.executor(for: definition.typeID) != nil, "\(definition.typeID) has no executor")
        #expect(definition.category.lowercased().hasPrefix(definition.typeID.rawValue.split(separator: ".")[0]), "\(definition.typeID) vs \(definition.category)")
        for port in definition.ports where port.kind == .data && port.type != .any {
            #expect(types.info(for: port.type) != nil, "\(definition.typeID).\(port.id) uses an unregistered type")
        }
        for group in definition.dynamicPorts where group.kind == .data && group.type != .any {
            #expect(types.info(for: group.type) != nil, "\(definition.typeID).\(group.id) uses an unregistered type")
        }
    }
}

@Test func onlyTimeDependentNodesAreImpure() throws {
    let (nodes, _) = standardRegistries()
    let impure = nodes.registeredDefinitions.filter { !$0.isPure }.map(\.typeID)
    #expect(impure == ["flow.every"])
}

@Test func definitionsExportAsJSON() throws {
    let (nodes, _) = standardRegistries()
    let data = try JSONEncoder().encode(nodes.registeredDefinitions)
    #expect(try JSONDecoder().decode([NodeDefinition].self, from: data) == nodes.registeredDefinitions)
}

@Test func packsComposeAndMayBeRegisteredTwice() {
    var nodes = NodeRegistry(), types = TypeRegistry()
    MathPack.register(nodes: &nodes, types: &types)
    #expect(nodes.registeredDefinitions.allSatisfy { $0.category == "Math" })
    #expect(types.registeredTypes.map(\.type) == [.number, .bool, .string])
    let count = nodes.registeredDefinitions.count
    MathPack.register(nodes: &nodes, types: &types)
    #expect(nodes.registeredDefinitions.count == count)
    LogicPack.register(nodes: &nodes, types: &types)
    #expect(nodes.definition(for: "logic.and") != nil && types.registeredTypes.count == 3)
}

@Test func everyNodeRunsOnItsDefaultsOrFailsCleanly() async throws {
    // A graph of one node of each type: nothing may crash or hang, and any failure must be a
    // clean `.failure`, never an undeclared-output or wrong-kind error from our own packs.
    let rig = Rig()
    for definition in rig.editor.nodes.registeredDefinitions { try rig.add(definition.typeID) }
    let tick = try await rig.step()
    for (id, run) in tick.results {
        if case .failure(let failure) = run.outcome {
            #expect(!failure.message.contains("undeclaredOutput") && !failure.message.contains("wrongPortKind"),
                    "\(rig.editor.graph.nodes[id]!.typeID): \(failure.message)")
        }
    }
    #expect(tick.results.count == rig.editor.nodes.registeredDefinitions.count)
}

// MARK: Variadic nodes

private func inputIDs(_ rig: Rig, _ node: NodeID) -> [String] {
    rig.editor.nodes.definition(for: rig.editor.graph.nodes[node]!)!.inputs.map(\.id.rawValue)
}

@Test func sumGrowsAnInputEachTimeTheLastOneIsConnected() async throws {
    let rig = Rig()
    let sum = try rig.add("math.sum")
    #expect(inputIDs(rig, sum) == ["in_1", "in_2"])
    var expected = 0.0
    for (n, value) in [1.0, 2.0, 3.0, 4.0].enumerated() {
        let constant = try rig.add("util.number", ["value": .double(value)])
        try rig.link(constant, "value", sum, PortID("in_\(n + 1)"))
        expected += value
        #expect(inputIDs(rig, sum).count == max(2, n + 2), "one free input after the last linked one, and never fewer than two")
    }
    let tick = try await rig.step()
    #expect(tick.succeeded && tick.outputs(of: sum)?["result"] == .double(expected))
    #expect(expected == 10)
}

@Test func sumIgnoresFreeInputsAndRejectsNonNumbers() async throws {
    #expect(try await result("math.sum") == 0.0)
    let text = try await failure("math.sum", ["in_1": "five"])
    #expect(text?.contains("needs numbers") == true)
}

@Test func joinConcatenatesInPortOrderWithASeparator() async throws {
    let rig = Rig()
    let join = try rig.add("string.join", ["separator": ", "])
    for (n, word) in ["alpha", "beta", "gamma"].enumerated() {
        let constant = try rig.add("util.string", ["value": .string(word)])
        try rig.link(constant, "value", join, PortID("in_\(n + 1)"))
    }
    let tick = try await rig.step()
    #expect(tick.outputs(of: join)?["result"] == "alpha, beta, gamma")
    #expect(try await result("string.join", ["in_2": "b"], properties: ["separator": "-"]) == "b", "a free port is skipped")
}

@Test func variadicNodesAreEditedUndoneAndSavedLikeAnyOther() async throws {
    let rig = Rig()
    let history = GraphHistory(editor: rig.editor)
    let sum = try rig.add("math.sum")
    let constant = try rig.add("util.number", ["value": 5.0])
    let before = rig.editor.graph
    try history.connect(ConnectionProposal(
        source: PortAddress(node: constant, port: "value", direction: .output),
        target: PortAddress(node: sum, port: "in_2", direction: .input)))
    #expect(inputIDs(rig, sum).count == 3)
    try history.undo()
    #expect(rig.editor.graph == before)
    try history.redo()

    let loaded = try GraphDocument.decode(from: rig.editor.makeDocument().encoded())
    #expect(loaded.graph == rig.editor.graph)
    let (nodes, types) = standardRegistries()
    #expect(GraphValidator().validate(ValidationContext(graph: loaded.graph, nodes: nodes, types: types)).isEmpty)
    let after = await (try GraphRunner(document: loaded, registry: nodes)).step()
    #expect(after.outputs(of: sum)?["result"] == 5.0)
}
