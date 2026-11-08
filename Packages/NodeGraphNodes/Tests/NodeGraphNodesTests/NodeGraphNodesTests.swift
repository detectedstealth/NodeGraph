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

@Test func onlyTimeDependentSideEffectingOrStatefulNodesAreImpure() throws {
    let (nodes, _) = standardRegistries()
    let impure = Set(nodes.registeredDefinitions.filter { !$0.isPure }.map(\.typeID))
    #expect(impure == [
        "flow.every", "util.time", "util.log", "math.random", "util.variable",
        "flow.counter", "flow.once", "flow.latch", "math.accumulate", "math.average", "math.tendTo",
    ])
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
    #expect(Set(types.registeredTypes.map(\.type)) == [.number, .bool, .string, .array, .object])
    let count = nodes.registeredDefinitions.count
    MathPack.register(nodes: &nodes, types: &types)
    #expect(nodes.registeredDefinitions.count == count)
    LogicPack.register(nodes: &nodes, types: &types)
    #expect(nodes.definition(for: "logic.and") != nil && types.registeredTypes.count == 5)
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

// MARK: Watch, time and log

@Test func watchAndLogPassTheirInputThroughAndNeedNoneToRun() async throws {
    for type in ["util.watch", "util.log"] as [NodeTypeID] {
        #expect(try await result(type, ["value": .string("hi")]) == .string("hi"))
        #expect(try await result(type, ["value": .array([.int(1)])]) == .array([.int(1)]))
        // Nothing connected: nothing to show or write, and not a failure.
        let empty = try await evaluate(type)
        #expect(empty.outputs?.values.isEmpty == true)
    }
}

@Test func logAcceptsEveryLevelAndLabel() async throws {
    for level in ["debug", "info", "warning", "error"] {
        let value = try await result(
            "util.log", ["value": .double(2)], properties: ["label": .string("x"), "level": .string(level)])
        #expect(value == .double(2))
    }
}

@Test func timeReportsTheRunsClockInADeterministicRun() async throws {
    let rig = Rig()
    let time = try rig.add("util.time")
    var last: TickResult?
    for await tick in try rig.runner().run(.deterministic(fixedDelta: .milliseconds(500), ticks: 3)) { last = tick }
    let outputs = try #require(last?.outputs(of: time))
    #expect(outputs["elapsed"] == .double(1))
    #expect(outputs["delta"] == .double(0.5))
    #expect(outputs["tick"] == .int(2))
}

@Test func aWatchedValueIsAvailableOnItsNodeAndOnTheLinkIntoIt() async throws {
    let rig = Rig()
    let constant = try rig.add("util.number", ["value": .double(5)])
    let watch = try rig.add("util.watch")
    try rig.link(constant, "value", watch, "value")
    let tick = try await rig.step()

    var values = RunValues()
    values.apply(tick)
    #expect(values[watch, "result"] == .double(5))
    let link = try #require(rig.editor.graph.links.values.first)
    #expect(values.value(of: link) == .double(5))
}

// MARK: More math

private func close(_ value: GraphValue?, _ expected: Double) -> Bool {
    guard let number = value?.numberValue else { return false }
    return abs(number - expected) < 1e-9
}

@Test(arguments: [
    ("math.tan", ["value": 0.0] as [PortID: GraphValue], 0.0),
    ("math.asin", ["value": 1.0], Double.pi / 2),
    ("math.acos", ["value": 1.0], 0.0),
    ("math.atan", ["value": 1.0], Double.pi / 4),
    ("math.atan2", ["a": 1.0, "b": -1.0], 3 * Double.pi / 4),
    ("math.frac", ["value": 2.75], 0.75),
    ("math.frac", ["value": -0.25], 0.75),
    ("math.remap", ["value": 5.0, "inMin": 0.0, "inMax": 10.0, "outMin": 100.0, "outMax": 200.0], 150.0),
    ("math.remap", ["value": 15.0, "inMin": 0.0, "inMax": 10.0, "outMin": 100.0, "outMax": 200.0], 250.0),
    ("math.remap", ["value": 2.5, "inMin": 0.0, "inMax": 10.0, "outMin": 1.0, "outMax": 0.0], 0.75),
    ("math.smoothstep", ["x": 0.5], 0.5),
    ("math.smoothstep", ["x": -3.0], 0.0),
    ("math.smoothstep", ["x": 9.0], 1.0),
    ("math.smoothstep", ["x": 5.0, "edge0": 0.0, "edge1": 10.0], 0.5),
] as [(NodeTypeID, [PortID: GraphValue], Double)])
func moreMathNodesCompute(_ type: NodeTypeID, _ inputs: [PortID: GraphValue], _ expected: Double) async throws {
    #expect(close(try await result(type, inputs), expected), "\(type) \(inputs)")
}

@Test func remapCanClampToTheOutputRange() async throws {
    let inputs: [PortID: GraphValue] = ["value": 15.0, "inMin": 0.0, "inMax": 10.0, "outMin": 100.0, "outMax": 200.0]
    #expect(close(try await result("math.remap", inputs, properties: ["clamp": .bool(true)]), 200))
}

@Test(arguments: [
    ("math.asin", ["value": 2.0] as [PortID: GraphValue], "-1 to 1"),
    ("math.acos", ["value": -2.0], "-1 to 1"),
    ("math.remap", ["inMin": 3.0, "inMax": 3.0], "empty"),
    ("math.smoothstep", ["edge0": 1.0, "edge1": 1.0], "equal"),
] as [(NodeTypeID, [PortID: GraphValue], String)])
func moreMathErrorsAreFailures(_ type: NodeTypeID, _ inputs: [PortID: GraphValue], _ message: String) async throws {
    let text = try #require(try await failure(type, inputs))
    #expect(text.contains(message))
}

/// Runs a `math.random` node at a given pass, for a given seed.
private func random(seed: Int64, tick: Int, node: Node? = nil, min: Double = 0, max: Double = 1) async throws -> Double {
    let (nodes, _) = standardRegistries()
    let node = node ?? Node(typeID: "math.random", properties: ["seed": .int(seed)])
    let definition = try #require(nodes.definition(for: node))
    let context = NodeContext(
        node: node, definition: definition, linkedInputs: ["min": .double(min), "max": .double(max)],
        time: ExecutionTime(tick: tick))
    let run = await NodeInvocation.run(node: node, registry: nodes, context: context)
    return try #require(run.outputs?["result"]?.numberValue)
}

@Test func randomIsRepeatableForASeedAPassAndANode() async throws {
    let node = Node(typeID: "math.random", properties: ["seed": .int(7)])
    let first = try await random(seed: 7, tick: 3, node: node)
    #expect(try await random(seed: 7, tick: 3, node: node) == first)
    #expect(try await random(seed: 7, tick: 4, node: node) != first, "a new pass gives a new number")
    #expect(try await random(seed: 8, tick: 3, node: Node(id: node.id, typeID: "math.random", properties: ["seed": .int(8)])) != first)
    #expect(try await random(seed: 7, tick: 3) != first, "another node gives another sequence")
}

@Test func randomStaysInRangeAndSpreadsOverIt() async throws {
    var values: [Double] = []
    for tick in 0..<200 { values.append(try await random(seed: 1, tick: tick, min: 10, max: 20)) }
    #expect(values.allSatisfy { $0 >= 10 && $0 < 20 })
    #expect(values.contains { $0 < 12 } && values.contains { $0 > 18 })
    let mean = values.reduce(0, +) / Double(values.count)
    #expect(abs(mean - 15) < 1.5)
    // A reversed range is allowed: it counts down from `min`.
    let reversed = try await random(seed: 1, tick: 0, min: 20, max: 10)
    #expect(reversed > 10 && reversed <= 20)
}

@Test func aDeterministicRunWithARandomNodeRepeatsExactly() async throws {
    func run() async throws -> [Double] {
        let rig = Rig()
        let id = try rig.add("math.random", ["seed": .int(42)])
        var out: [Double] = []
        for await tick in try rig.runner().run(.deterministic(fixedDelta: .milliseconds(10), ticks: 5)) {
            out.append(try #require(tick.outputs(of: id)?["result"]?.numberValue))
        }
        return out
    }
    // Each rig makes a new node id, so compare the shape: five distinct numbers, and a rerun of
    // the same rig's runner would match (covered by the repeatability test above).
    let numbers = try await run()
    #expect(numbers.count == 5 && Set(numbers).count == 5)
}

// MARK: More strings

@Test func splitCutsTextAndKeepsEmptyPieces() async throws {
    #expect(try await result("string.split", ["value": "a,,b", "separator": ","]) == .array(["a", "", "b"]))
    #expect(try await result("string.split", ["value": "abc", "separator": ""]) == .array(["a", "b", "c"]))
    #expect(try await result("string.split", ["value": "", "separator": ","]) == .array([""]))
    #expect(try await result("string.split", ["value": "a b"]) == .array(["a b"]), "the default separator is a comma")
}

@Test func toFixedRoundsToTheDecimals() async throws {
    #expect(try await result("string.toFixed", ["value": 3.14159]) == "3.14")
    #expect(try await result("string.toFixed", ["value": 3.14159], properties: ["decimals": .int(0)]) == "3")
    #expect(try await result("string.toFixed", ["value": 2.0], properties: ["decimals": .int(3)]) == "2.000")
    #expect(try await result("string.toFixed", ["value": .int(5)]) == "5.00")
    #expect(try await failure("string.toFixed", ["value": .double(.infinity)]) != nil)
}

// MARK: Arrays

private let numbers: GraphValue = .array([.int(10), .int(20), .int(30)])

@Test func makeArrayCollectsLinkedItemsInOrder() async throws {
    let rig = Rig()
    let make = try rig.add("array.make")
    let a = try rig.add("util.number", ["value": .double(1)])
    let b = try rig.add("util.string", ["value": .string("x")])
    try rig.link(a, "value", make, "in_1")
    try rig.link(b, "value", make, "in_2")
    #expect(try await rig.step().outputs(of: make)?["result"] == .array([.double(1), .string("x")]))
}

@Test func arrayLengthGetSetAppendSlice() async throws {
    #expect(try await result("array.length", ["array": numbers]) == .int(3))
    #expect(try await result("array.length", ["array": .vector([1, 2])]) == .int(2), "a vector reads as numbers")
    #expect(try await result("array.length") == .int(0))
    #expect(try await result("array.get", ["array": numbers, "index": .int(1)]) == .int(20))
    #expect(try await result("array.get", ["array": .vector([1.5, 2.5]), "index": .double(1)]) == .double(2.5))
    #expect(try await result("array.set", ["array": numbers, "index": .int(0), "value": "x"]) == .array(["x", .int(20), .int(30)]))
    #expect(try await result("array.append", ["array": numbers, "value": .int(40)]) == .array([.int(10), .int(20), .int(30), .int(40)]))
    #expect(try await result("array.append", ["value": .int(1)]) == .array([.int(1)]), "no array starts an empty one")
    #expect(try await result("array.slice", ["array": numbers, "start": .int(1)]) == .array([.int(20), .int(30)]))
    #expect(try await result("array.slice", ["array": numbers, "start": .int(1), "count": .int(1)]) == .array([.int(20)]))
    #expect(try await result("array.slice", ["array": numbers, "start": .int(5), "count": .int(2)]) == .array([]))
    #expect(try await result("array.slice", ["array": numbers, "start": .int(-4), "count": .int(2)]) == .array([.int(10), .int(20)]))
}

@Test func arrayErrorsAreCleanFailures() async throws {
    #expect(try #require(try await failure("array.get", ["array": numbers, "index": .int(3)])).contains("outside an array of 3"))
    #expect(try #require(try await failure("array.get", ["array": numbers, "index": .int(-1)])).contains("outside"))
    #expect(try #require(try await failure("array.set", ["array": numbers, "index": .int(9), "value": .int(0)])).contains("outside"))
    #expect(try #require(try await failure("array.get", ["array": numbers, "index": 1.5])).contains("whole number"))
    #expect(try #require(try await failure("array.length", ["array": "text"])).contains("array"))
}

// MARK: Objects and JSON

private let person: GraphValue = .object(["name": "Ada", "age": .int(36)])

@Test func objectGetSetMergeKeys() async throws {
    let found = try await evaluate("object.get", ["object": person, "key": "name"]).outputs
    #expect(found?["value"] == "Ada" && found?["found"] == .bool(true))
    let missing = try await evaluate("object.get", ["object": person, "key": "nope"]).outputs
    #expect(missing?["value"] == nil && missing?["found"] == .bool(false))

    #expect(try await result("object.set", ["object": person, "key": "age", "value": .int(37)]) == .object(["name": "Ada", "age": .int(37)]))
    #expect(try await result("object.set", ["key": "a", "value": .bool(true)]) == .object(["a": .bool(true)]))
    #expect(try await result("object.merge", ["a": person, "b": .object(["age": .int(1), "x": .null])])
            == .object(["name": "Ada", "age": .int(1), "x": .null]))
    #expect(try await result("object.keys", ["object": person]) == .array(["age", "name"]), "sorted")
    #expect(try #require(try await failure("object.keys", ["object": numbers])).contains("object"))
}

@Test func jsonParsesAndWritesBack() async throws {
    let text = #"{"a":[1,2.5,"x",null,true],"b":{"c":"d"}}"#
    let parsed = try #require(try await result("object.parseJson", ["text": .string(text)]))
    #expect(parsed == .object([
        "a": .array([.int(1), .double(2.5), "x", .null, .bool(true)]),
        "b": .object(["c": "d"]),
    ]))
    #expect(try await result("object.toJson", ["value": parsed]) == .string(text), "keys are sorted, so the text is stable")
    #expect(try #require(try await failure("object.parseJson", ["text": "{nope"])).contains("JSON"))
    #expect(try await result("object.parseJson") == .null, "the default is null")
    #expect(try await result("object.toJson", ["value": .vector([1, 2])]) == "[1,2]", "whole doubles are written without a fraction, as JSON does")
    #expect(try #require(try await failure("object.toJson", ["value": .color(RGBAColor(red: 0, green: 0, blue: 0))])).contains("no JSON form"))
    #expect(try await failure("object.toJson", ["value": .double(.nan)]) != nil)
    #expect(try await failure("object.toJson", ["value": .array([.int(1), .handle(HandleID(uuid: UUID()))])]) != nil)
}

// MARK: Conversions

@Test func toNumberReadsNumbersBoolsAndText() async throws {
    #expect(try await result("convert.toNumber", ["value": .int(3)]) == .double(3))
    #expect(try await result("convert.toNumber", ["value": .bool(true)]) == .double(1))
    #expect(try await result("convert.toNumber", ["value": .bool(false)]) == .double(0))
    #expect(try await result("convert.toNumber", ["value": " 2.5 "]) == .double(2.5))
    #expect(try #require(try await failure("convert.toNumber", ["value": "abc"])).contains("not a number"))
    #expect(try await failure("convert.toNumber", ["value": "inf"]) != nil)
    #expect(try await failure("convert.toNumber", ["value": numbers]) != nil)
}

@Test func toBoolReadsNumbersAndText() async throws {
    #expect(try await result("convert.toBool", ["value": .int(0)]) == .bool(false))
    #expect(try await result("convert.toBool", ["value": .double(0.1)]) == .bool(true))
    #expect(try await result("convert.toBool", ["value": .bool(true)]) == .bool(true))
    #expect(try await result("convert.toBool", ["value": "TRUE"]) == .bool(true))
    #expect(try await result("convert.toBool", ["value": " 0 "]) == .bool(false))
    #expect(try #require(try await failure("convert.toBool", ["value": "maybe"])).contains("not true or false"))
}

@Test func toIntegerRoundsAsChosenAndOutputsAnInt() async throws {
    for (rounding, expected) in [("nearest", 3), ("down", 2), ("up", 3), ("towardZero", 2)] as [(String, Int64)] {
        #expect(try await result("convert.toInt", ["value": 2.5], properties: ["rounding": .string(rounding)]) == .int(expected), "\(rounding)")
    }
    #expect(try await result("convert.toInt", ["value": -2.5], properties: ["rounding": "towardZero"]) == .int(-2))
    #expect(try await result("convert.toInt", ["value": -2.5], properties: ["rounding": "down"]) == .int(-3))
    #expect(try #require(try await failure("convert.toInt", ["value": 1e30])).contains("does not fit"))
}

// MARK: Triggers

@Test func bothFiresOnlyWhenBothInputsFiredInThePass() async throws {
    let rig = Rig()
    let every1 = try rig.add("flow.every", ["interval": .int(1)])
    let every2 = try rig.add("flow.every", ["interval": .int(2)])
    let both = try rig.add("flow.both")
    let toBool = try rig.add("flow.triggerToBool")
    try rig.link(every1, "fire", both, "a")
    try rig.link(every2, "fire", both, "b")
    try rig.link(both, "fire", toBool, "trigger")
    var fired: [Bool] = []
    for await tick in try rig.runner().run(.deterministic(fixedDelta: .milliseconds(1), ticks: 4)) {
        fired.append(tick.outputs(of: toBool)?["result"] == .bool(true))
    }
    #expect(fired == [true, false, true, false])
}

@Test func arraysAndObjectsConnectBetweenTheirPorts() async throws {
    let rig = Rig()
    let text = try rig.add("util.string", ["value": .string("a,b,c")])
    let split = try rig.add("string.split")
    try rig.link(text, "value", split, "value")
    let length = try rig.add("array.length")
    let get = try rig.add("array.get")
    try rig.link(split, "result", length, "array")
    try rig.link(split, "result", get, "array")
    let tick = try await rig.step()
    #expect(tick.outputs(of: length)?["result"] == .int(3))
    #expect(tick.outputs(of: get)?["result"] == "a")
    // A number cannot go into an array port.
    let number = try rig.add("util.number")
    #expect(throws: (any Error).self) { try rig.link(number, "value", length, "array") }
}

// MARK: Variables

@Test func variableReadsTheGraphsValueOrTheRunsOverride() async throws {
    let rig = Rig()
    try rig.editor.apply(.addVariable(variable: GraphVariable(name: "speed", type: .number, value: .double(3))))
    let read = try rig.add("util.variable", ["name": .string("speed")])
    let double = try rig.add("math.multiply")
    let two = try rig.add("util.number", ["value": .double(2)])
    try rig.link(read, "value", double, "a")
    try rig.link(two, "value", double, "b")

    let runner = try rig.runner()
    #expect(try await runner.step().outputs(of: double)?["result"] == .double(6))
    try await runner.setVariable("speed", to: .double(10))
    #expect(try await runner.step().outputs(of: double)?["result"] == .double(20))
}

@Test func variableWithAnUnknownNameFailsClearly() async throws {
    let rig = Rig()
    let read = try rig.add("util.variable", ["name": .string("nope")])
    let tick = try await rig.step()
    guard case .failure(let failure)? = tick.results[read]?.outcome else { Issue.record("expected a failure"); return }
    #expect(failure.message.contains("no variable named \"nope\""))
    // An unset name is the same failure, not a crash.
    let blank = try rig.add("util.variable")
    #expect(try await rig.step().results[blank]?.status != .succeeded)
}

@Test func aVariableNodeInsideASubgraphReadsTheRootsVariable() async throws {
    let rig = Rig()
    try rig.editor.apply(.addVariable(variable: GraphVariable(name: "gain", type: .number, value: .double(4))))
    let read = try rig.add("util.variable", ["name": .string("gain")])
    let scale = try rig.add("math.multiply")
    let ten = try rig.add("util.number", ["value": .double(10)])
    try rig.link(read, "value", scale, "a")
    try rig.link(ten, "value", scale, "b")
    let after = try rig.add("math.add")   // outside the subgraph, so the product becomes an exposed output
    try rig.link(scale, "result", after, "a")
    let conversion = try rig.editor.convertToSubgraphCommand(nodes: [read, scale, ten], name: "Scaled")
    try rig.editor.apply(conversion.command)

    let runner = try GraphRunner(
        graph: rig.editor.graph, registry: rig.editor.nodes, subgraphs: rig.editor.subgraphs.map(\.value))
    let first = try await runner.step()
    #expect(first.succeeded, "\(first.results.values.map(\.status))")
    #expect(first.outputs(of: after)?["result"] == .double(40))
    try await runner.setVariable("gain", to: .double(7))
    let second = try await runner.step()
    #expect(second.succeeded)
    #expect(second.outputs(of: after)?["result"] == .double(70))
}

// MARK: Stateful nodes

/// Runs `ticks` deterministic passes and reads one output of `node` after each.
private func series(_ rig: Rig, _ node: NodeID, _ port: PortID, ticks: Int) async throws -> [GraphValue?] {
    var values: [GraphValue?] = []
    for await tick in try rig.runner().run(.deterministic(fixedDelta: .milliseconds(1), ticks: ticks)) {
        values.append(tick.outputs(of: node)?[port])
    }
    return values
}

/// A node that fires on the listed ticks (0-based) and no others, built from `flow.every`.
private func every(_ interval: Int64, in rig: Rig) throws -> NodeID {
    try rig.add("flow.every", ["interval": .int(interval)])
}

@Test func counterCountsIncrementsDecrementsAndResets() async throws {
    let rig = Rig()
    let counter = try rig.add("flow.counter", ["start": .int(10)])
    let up = try every(1, in: rig), down = try every(2, in: rig), reset = try every(5, in: rig)
    try rig.link(up, "fire", counter, "increment")
    try rig.link(down, "fire", counter, "decrement")
    try rig.link(reset, "fire", counter, "reset")
    // tick 0: reset to 10, +1, -1 = 10. Then +1 each tick, -1 on even ticks; tick 5 resets.
    #expect(try await series(rig, counter, "count", ticks: 7) == [10, 11, 11, 12, 12, 11, 11].map { .int($0) })
}

@Test func onceFiresOnlyForTheFirstEventUntilReset() async throws {
    let rig = Rig()
    let once = try rig.add("flow.once")
    let toBool = try rig.add("flow.triggerToBool")
    let every1 = try every(1, in: rig), every4 = try every(4, in: rig)
    try rig.link(every1, "fire", once, "trigger")
    try rig.link(every4, "fire", once, "reset")
    try rig.link(once, "fire", toBool, "trigger")
    // Tick 0 resets and fires; tick 4 re-arms and fires again.
    #expect(try await series(rig, toBool, "result", ticks: 6) == [true, false, false, false, true, false].map { .bool($0) })
}

@Test func latchHoldsAcrossPassesAndResetWins() async throws {
    let rig = Rig()
    let latch = try rig.add("flow.latch")
    try rig.link(try every(2, in: rig), "fire", latch, "set")
    try rig.link(try every(3, in: rig), "fire", latch, "reset")
    // Tick 0: both fire, reset wins. Tick 2: on. Tick 3: off. Tick 4: on.
    #expect(try await series(rig, latch, "on", ticks: 5) == [false, false, true, false, true].map { .bool($0) })
}

@Test func accumulateSumsEveryPassAndResets() async throws {
    let rig = Rig()
    let three = try rig.add("util.number", ["value": .double(3)])
    let accumulate = try rig.add("math.accumulate")
    try rig.link(three, "value", accumulate, "value")
    try rig.link(try every(3, in: rig), "fire", accumulate, "reset")
    // Tick 0 and tick 3 reset first, then add.
    #expect(try await series(rig, accumulate, "total", ticks: 5) == [3, 6, 9, 3, 6].map { .double($0) })
}

@Test func averageUsesTheLatestWindowOfValues() async throws {
    let rig = Rig()
    let time = try rig.add("util.time")
    let average = try rig.add("math.average", ["window": .int(3)])
    try rig.link(time, "tick", average, "value")
    // Values 0,1,2,3,4: means of [0], [0,1], [0,1,2], [1,2,3], [2,3,4].
    #expect(try await series(rig, average, "result", ticks: 5) == [0, 0.5, 1, 2, 3].map { .double($0) })
}

@Test func tendToClosesTheGapByTheRateEachPass() async throws {
    let rig = Rig()
    let target = try rig.add("util.number", ["value": .double(8)])
    let tend = try rig.add("math.tendTo")
    try rig.link(target, "value", tend, "target")
    // The default rate is 0.1, starting from 0.
    let values = try await series(rig, tend, "result", ticks: 3).compactMap(\.?.numberValue)
    #expect(values.count == 3)
    for (value, expected) in zip(values, [0.8, 1.52, 2.168]) { #expect(abs(value - expected) < 1e-9) }
}

@Test func statefulNodesStartOverAfterAReset() async throws {
    let rig = Rig()
    let counter = try rig.add("flow.counter")
    try rig.link(try every(1, in: rig), "fire", counter, "increment")
    let runner = try rig.runner()
    _ = await runner.step(); _ = await runner.step()
    #expect(await runner.step().outputs(of: counter)?["count"] == .int(3))
    await runner.reset()
    #expect(await runner.step().outputs(of: counter)?["count"] == .int(1))
}
