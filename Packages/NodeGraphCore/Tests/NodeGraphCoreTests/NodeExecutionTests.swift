import Foundation
import Synchronization
import Testing
@testable import NodeGraphCore

private let addDefinition = NodeDefinition(
    typeID: "add", displayName: "Add",
    ports: [
        PortDefinition(id: "a", direction: .input, defaultValue: 0.0),
        PortDefinition(id: "b", direction: .input),
        PortDefinition(id: "go", direction: .input, kind: .trigger, defaultValue: true),
        PortDefinition(id: "sum", direction: .output),
    ],
    properties: [
        PropertyDefinition(id: "scale", displayName: "Scale", kind: .double(), defaultValue: 1.0),
        PropertyDefinition(id: "label", displayName: "Label", kind: .string(), defaultValue: "x"),
    ])

private func context(
    linked: [PortID: GraphValue] = [:],
    properties: [PropertyID: GraphValue] = [:],
    services: ServiceContainer = ServiceContainer(),
    onProgress: @escaping @Sendable (NodeProgress) -> Void = { _ in }
) -> NodeContext {
    NodeContext(
        node: Node(typeID: "add", properties: properties), definition: addDefinition,
        linkedInputs: linked, services: services, onProgress: onProgress)
}

// MARK: Context

@Test func inputsFallBackToDataPortDefaultsOnly() {
    let ctx = context(linked: ["b": 2.0])
    #expect(ctx.inputs["a"] == 0.0)      // default
    #expect(ctx.inputs["b"] == 2.0)      // linked
    #expect(ctx.inputs["go"] == nil)     // trigger ports carry no default value
}

@Test func linkedValuesBeatDefaults() {
    #expect(context(linked: ["a": 5.0]).inputs["a"] == 5.0)
}

@Test func propertiesMergeOverridesOverDefaults() throws {
    let ctx = context(properties: ["scale": 3.0])
    #expect(try ctx.property("scale") == 3.0)
    #expect(try ctx.property("label") == "x")
    #expect(throws: NodeExecutionError.missingProperty("nope")) { try ctx.property("nope") }
}

@Test func typedInputAccessorsAcceptTheRightKindsOnly() throws {
    let ctx = context(linked: ["a": .int(4), "b": 2.5, "c": "hi", "d": true])
    #expect(try ctx.number("a") == 4 && ctx.number("b") == 2.5)
    #expect(try ctx.string("c") == "hi" && ctx.bool("d"))
    #expect(throws: NodeExecutionError.invalidInput("c", expected: "number")) { try ctx.number("c") }
    #expect(throws: NodeExecutionError.invalidInput("a", expected: "bool")) { try ctx.bool("a") }
    #expect(throws: NodeExecutionError.invalidInput("a", expected: "string")) { try ctx.string("a") }
    #expect(throws: NodeExecutionError.missingInput("zzz")) { try ctx.input("zzz") }
    #expect(throws: NodeExecutionError.missingInput("b")) { try context().input("b") }
}

@Test func graphValueTypedAccessIsStrictExceptNumber() {
    #expect(GraphValue.int(1).intValue == 1 && GraphValue.int(1).doubleValue == nil)
    #expect(GraphValue.int(1).numberValue == 1 && GraphValue.double(2).numberValue == 2)
    #expect(GraphValue.double(2).intValue == nil && GraphValue.bool(true).numberValue == nil)
    #expect(GraphValue.bool(true).boolValue == true && GraphValue.string("s").stringValue == "s")
    #expect(GraphValue.null.stringValue == nil && GraphValue.string("s").boolValue == nil)
}

@Test func timeConvertsToSeconds() {
    let time = ExecutionTime(tick: 2, elapsed: .milliseconds(1500), delta: .milliseconds(250))
    #expect(time.elapsedSeconds == 1.5 && time.deltaSeconds == 0.25)
}

private struct Clock: Sendable { var value: Int }

@Test func servicesAreLookedUpByType() {
    var services = ServiceContainer()
    services.register(Clock(value: 7))
    services.register("a string service")
    #expect(services[Clock.self]?.value == 7)
    #expect(services[String.self] == "a string service")
    #expect(services[Int.self] == nil)
    services.register(Clock(value: 8))
    #expect(services[Clock.self]?.value == 8)
    #expect(context(services: services).services[Clock.self]?.value == 8)
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [NodeProgress] = []
    func add(_ p: NodeProgress) { lock.lock(); items.append(p); lock.unlock() }
    var all: [NodeProgress] { lock.lock(); defer { lock.unlock() }; return items }
}

@Test func progressIsClampedAndTaggedWithTheNode() async {
    let log = ProgressLog()
    let ctx = context(onProgress: { log.add($0) })
    ctx.reportProgress(0.5, message: "half")
    ctx.reportProgress(-1)
    ctx.reportProgress(7)
    ctx.reportProgress(.nan)
    #expect(log.all.map(\.fraction) == [0.5, 0, 1, 0])
    #expect(log.all.first?.message == "half" && log.all.allSatisfy { $0.node == ctx.nodeID })
}

// MARK: Invocation

@Test func successReturnsOutputsAndTime() async {
    let ctx = context(linked: ["a": 1.0, "b": 2.0])
    let result = await NodeInvocation.run({ ctx in
        try await Task.sleep(for: .milliseconds(20))
        return ["sum": .double(try ctx.number("a") + ctx.number("b"))]
    }, context: ctx)
    #expect(result.outputs == ["sum": 3.0])
    #expect(result.duration >= .milliseconds(15))
    #expect(result.node == ctx.nodeID)
}

@Test func thrownErrorsBecomeFailures() async {
    let result = await NodeInvocation.run({ ctx in _ = try ctx.input("b"); return [:] }, context: context())
    guard case .failure(let failure) = result.outcome else { Issue.record("expected failure"); return }
    #expect(failure.message.contains("missingInput"))
    #expect(result.outputs == nil)
}

@Test func localizedErrorsUseTheirDescription() async {
    struct Friendly: LocalizedError { var errorDescription: String? { "Be nice." } }
    let result = await NodeInvocation.run({ _ in throw Friendly() }, context: context())
    #expect(result.outcome == .failure(NodeFailure(message: "Be nice.")))
}

@Test func undeclaredOutputsFail() async {
    let result = await NodeInvocation.run({ _ in ["sum": 1, "typo": 2] }, context: context())
    guard case .failure(let failure) = result.outcome else { Issue.record("expected failure"); return }
    #expect(failure.message.contains("undeclaredOutput") && failure.message.contains("typo"))
}

@Test func missingOutputsAreAllowed() async {
    let result = await NodeInvocation.run({ _ in [:] }, context: context())
    #expect(result.outputs == [:])
}

@Test func cancellingBeforeStartSkipsTheExecutor() async {
    let ran = Mutex(false)
    let task = Task {
        try? await Task.sleep(for: .seconds(5))   // cancelled while sleeping
        return await NodeInvocation.run({ _ in ran.withLock { $0 = true }; return [:] }, context: context())
    }
    task.cancel()
    #expect(await task.value.outcome == .cancelled)
    #expect(!ran.withLock { $0 })
}

@Test func cancellingDuringExecutionIsReportedAsCancelled() async {
    let started = AsyncStream<Void>.makeStream()
    let task = Task {
        await NodeInvocation.run({ ctx in
            started.continuation.yield()
            while true {
                try ctx.checkCancellation()
                try await Task.sleep(for: .milliseconds(5))
            }
        }, context: context())
    }
    for await _ in started.stream { break }
    task.cancel()
    #expect(await task.value.outcome == .cancelled)
}

@Test func aNodeThatThrowsCancellationErrorIsCancelledNotFailed() async {
    let result = await NodeInvocation.run({ _ in throw CancellationError() }, context: context())
    #expect(result.outcome == .cancelled)
}

// MARK: Registry

@Test func registryStoresExecutorsBesideDefinitions() async {
    var registry = NodeRegistry()
    registry.register(addDefinition) { _ in ["sum": 42] }
    let node = Node(typeID: "add")
    let result = await NodeInvocation.run(
        node: node, registry: registry,
        context: NodeContext(node: node, definition: addDefinition))
    #expect(result.outputs == ["sum": 42])

    // Re-registering without an executor clears the old one.
    registry.register(addDefinition)
    #expect(registry.executor(for: "add") == nil)
    let missing = await NodeInvocation.run(
        node: node, registry: registry, context: NodeContext(node: node, definition: addDefinition))
    guard case .failure(let failure) = missing.outcome else { Issue.record("expected failure"); return }
    #expect(failure.message.contains("notExecutable"))
}

@Test func placeholderDefinitionsHaveNoExecutor() {
    var graph = Graph()
    graph.insert(Node(typeID: "ghost"))
    let registry = NodeRegistry().addingPlaceholders(for: graph)
    #expect(registry.definition(for: "ghost") != nil && registry.executor(for: "ghost") == nil)
}

// MARK: Help text

@Test func setHelpKeepsTheExecutorAndOldDefinitionsDecodeWithoutHelp() throws {
    var nodes = NodeRegistry()
    nodes.register(NodeDefinition(typeID: "t", displayName: "T")) { _ in .empty }
    nodes.setHelp("Does a thing.", for: "t")
    #expect(nodes.definition(for: "t")?.help == "Does a thing.")
    #expect(nodes.executor(for: "t") != nil)
    nodes.setHelp("ignored", for: "missing")
    #expect(nodes.definition(for: "missing") == nil)

    var plain = try #require(nodes.definition(for: "t"))
    plain.help = nil
    let json = String(decoding: try JSONEncoder().encode(plain), as: UTF8.self)
    #expect(!json.contains("help"))
    #expect(try JSONDecoder().decode(NodeDefinition.self, from: Data(json.utf8)) == plain)
}
