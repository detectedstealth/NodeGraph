import Foundation
import Testing
import NodeGraphCore
import NodeGraphNodes
import NodeGraphRobotics
import NodeGraphVideo
@testable import NodeGraphAssistant

private typealias N = GraphSpec.NodeSpec
private typealias L = GraphSpec.LinkSpec

private let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private func registries() -> (NodeRegistry, TypeRegistry) {
    var nodes = NodeRegistry()
    var types = TypeRegistry()
    StandardPack.register(nodes: &nodes, types: &types)
    RoboticsPack.register(nodes: &nodes, types: &types)
    VideoPack.register(nodes: &nodes, types: &types)
    return (nodes, types)
}

private func log(_ alias: String, _ label: String, _ level: String) -> N {
    N(alias: alias, type: "util.log", properties: ["label": .string(label), "level": .string(level)])
}

/// A sensor monitor that exercises the console: every log level, a node that fails and the node
/// skipped after it, a trigger-driven counter, and variables that fix the failure.
///
/// Built from `GraphSpec`s, one per cluster, so each cluster is laid out and framed by itself.
/// Regenerate the file with `NODEGRAPH_WRITE_EXAMPLES=1 swift test --filter ConsoleExampleTests`.
///
/// The checked-in file was then adjusted by hand in the editor so each group encloses its nodes as
/// they are drawn: the generator sizes groups from the registry's default node sizes, and the editor
/// draws some nodes taller (ports, widgets). Regenerating loses that adjustment.
private func makeConsoleExample() throws -> GraphDocument {
    let (nodes, types) = registries()
    let editor = GraphEditor(nodes: nodes, types: types)
    let number = PortType("number")
    try editor.apply(.addVariable(variable: GraphVariable(
        name: "limit", type: number, value: 30.0, summary: "The temperature that raises the alarm.")))
    try editor.apply(.addVariable(variable: GraphVariable(
        name: "margin", type: number, value: 0.0,
        summary: "Divides the reading in the fault cluster. While it is 0 the Divide node fails; set it above 0 to clear the error.")))

    struct Cluster {
        var title: String
        var spec: GraphSpec
    }
    let clusters: [Cluster] = [
        Cluster(title: "Sensor", spec: GraphSpec(
            nodes: [
                N(alias: "sensor", type: "robotics.signal", title: "Temperature sensor", properties: [
                    "waveform": .string("sine"), "amplitude": .int(8), "frequency": .double(0.2),
                    "offset": .int(25), "noise": .double(1.5), "seed": .int(7)]),
                log("raw", "raw", "debug"),
                N(alias: "smooth", type: "robotics.lowPass", title: "Smoother", properties: ["tau": .double(1)]),
                log("smoothed", "smoothed", "info"),
                N(alias: "shown", type: "util.watch", title: "Temperature"),
            ],
            links: [
                L(from: "sensor.value", to: "raw.value"), L(from: "raw.result", to: "smooth.value"),
                L(from: "smooth.result", to: "smoothed.value"), L(from: "smoothed.result", to: "shown.value"),
            ])),
        Cluster(title: "Alarm", spec: GraphSpec(
            nodes: [
                N(alias: "limit", type: "util.variable", title: "Alarm limit", properties: ["name": .string("limit")]),
                N(alias: "over", type: "logic.compare", title: "Over the limit?", properties: ["operator": .string(">")]),
                N(alias: "alarm", type: "util.string", properties: ["value": .string("ALARM")]),
                N(alias: "ok", type: "util.string", properties: ["value": .string("normal")]),
                N(alias: "state", type: "logic.select", title: "State"),
                log("status", "alarm state", "warning"),
            ],
            links: [
                L(from: "limit.value", to: "over.b"), L(from: "over.result", to: "state.condition"),
                L(from: "alarm.value", to: "state.ifTrue"), L(from: "ok.value", to: "state.ifFalse"),
                L(from: "state.result", to: "status.value"),
            ])),
        Cluster(title: "Report", spec: GraphSpec(
            nodes: [
                N(alias: "text", type: "util.string", properties: ["value": .string("Temperature")]),
                N(alias: "fixed", type: "string.toFixed", title: "One decimal", properties: ["decimals": .int(1)]),
                N(alias: "line", type: "string.join", title: "Report line", properties: ["separator": .string(": ")]),
                log("report", "report", "info"),
            ],
            links: [
                L(from: "text.value", to: "line.in_1"), L(from: "fixed.result", to: "line.in_2"),
                L(from: "line.result", to: "report.value"),
            ])),
        Cluster(title: "Heartbeat: a trigger every 3rd pass", spec: GraphSpec(
            nodes: [
                N(alias: "every", type: "flow.every", title: "Every 3 passes", properties: ["interval": .int(3)]),
                N(alias: "beats", type: "flow.counter", title: "Beats"),
                log("beat", "heartbeat", "info"),
            ],
            links: [L(from: "every.fire", to: "beats.increment"), L(from: "beats.count", to: "beat.value")])),
        Cluster(title: "Fault injection: set the variable margin above 0 to clear the error", spec: GraphSpec(
            nodes: [
                N(alias: "margin", type: "util.variable", title: "Margin", properties: ["name": .string("margin")]),
                N(alias: "normalise", type: "math.divide", title: "Normalise (fails while margin is 0)"),
                log("normalised", "normalised", "info"),
            ],
            links: [L(from: "margin.value", to: "normalise.b"), L(from: "normalise.result", to: "normalised.value")])),
    ]

    var ids: [String: NodeID] = [:]
    var top = 0.0
    for cluster in clusters {
        let compilation = GraphSpecCompiler(nodes: nodes, types: types).compile(cluster.spec)
        #expect(compilation.isClean, "\(cluster.title): \(compilation.errors)")
        let paste = try compilation.pasteCommand(into: editor, at: GraphPoint(x: 0, y: top))
        try editor.apply(paste.command)
        // The paste numbers the new nodes in the order of the fragment, which is the spec's order.
        for (spec, id) in zip(cluster.spec.nodes, paste.nodes) { ids[spec.alias] = id }
        let frames = paste.nodes.compactMap { editor.graph.nodes[$0] }.map(nodes.frame(of:))
        let minX = frames.map(\.minX).min()!, maxX = frames.map(\.maxX).max()!
        let minY = frames.map(\.minY).min()!, maxY = frames.map(\.maxY).max()!
        try editor.apply(.addGroup(group: NodeGroup(
            title: cluster.title,
            bounds: GraphRect(x: minX - 24, y: minY - 52, width: maxX - minX + 48, height: maxY - minY + 80))))
        top = maxY + 140
    }

    // The links between clusters: everything downstream reads the smoothed reading.
    for (from, to, port) in [("smoothed", "over", "a"), ("smoothed", "fixed", "value"), ("smoothed", "normalise", "a")] {
        try editor.connect(ConnectionProposal(
            source: PortAddress(node: ids[from]!, port: "result", direction: .output),
            target: PortAddress(node: ids[to]!, port: PortID(port), direction: .input)))
    }
    return editor.makeDocument()
}

private func load() throws -> GraphDocument {
    try GraphDocument.decode(from: Data(contentsOf: repositoryRoot.appendingPathComponent("examples/console.nodegraph")))
}

@Suite struct ConsoleExampleTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NODEGRAPH_WRITE_EXAMPLES"] != nil))
    func writeTheExample() throws {
        try makeConsoleExample().encoded().write(to: repositoryRoot.appendingPathComponent("examples/console.nodegraph"))
    }

    @Test func theFileLoadsAndIsValid() throws {
        let document = try load()
        let (nodes, types) = registries()
        #expect(document.missingNodeTypes(in: nodes).isEmpty)
        let editor = GraphEditor(document: document, nodes: nodes, types: types)
        let space = AssistantWorkspace(editor: editor)
        #expect(space.diagnostics().isEmpty)
        #expect(document.graph.nodes.count == 21 && document.graph.groups.count == 5)
        #expect(Array(document.graph.variables.keys) == ["limit", "margin"])
        // No lint problems: every finding is a hint, and the log nodes' outputs are pass-throughs.
        let problems = space.lint().filter { $0.level == .problem }
        #expect(problems.isEmpty, "\(space.render(problems))")
    }

    @Test func eachClusterIsFramedByItsOwnGroup() throws {
        let document = try load()
        let (nodes, _) = registries()
        let graph = document.graph
        var seen = Set<NodeID>()
        for group in graph.groups.values {
            let members = graph.members(of: group, frame: nodes.frame(of:))
            #expect(!members.isEmpty, "\(group.title) has no nodes")
            #expect(seen.isDisjoint(with: members), "\(group.title) shares a node with another group")
            seen.formUnion(members)
        }
        #expect(seen.count == graph.nodes.count)
    }

    @Test func runningItGivesTheConsoleEveryLevelAFailureAndASkippedNode() async throws {
        let document = try load()
        let (nodes, _) = registries()
        let runner = try GraphRunner(document: document, registry: nodes)
        let result = await runner.step()

        let byTitle = Dictionary(uniqueKeysWithValues: document.graph.nodes.values.map { ($0.id, $0) })
        let failed = result.failedNodes.compactMap { byTitle[$0] }
        #expect(failed.map(\.typeID) == ["math.divide"])
        guard case .failure(let failure)? = result.results[failed[0].id]?.outcome else { return }
        #expect(failure.message == "Division by zero")
        // The log node after it is skipped, which the console reports as a debug line.
        let skipped = result.results.values.filter { $0.outcome == .skipped(.upstreamFailed) }
        #expect(skipped.count == 1 && byTitle[skipped[0].node]?.typeID == "util.log")

        let levels = document.graph.nodes.values.filter { $0.typeID == "util.log" }
            .map { $0.properties["level"]?.stringValue ?? "info" }  // info is the default, so it is not stored
        #expect(Set(levels) == ["debug", "info", "warning"])
        #expect(levels.count == 6)

        // The rest of the graph ran: the sensor reading reached the report.
        let report = document.graph.nodes.values.first { $0.properties["label"]?.stringValue == "report" }!
        #expect(result.outputs(of: report.id)?.values["result"]?.stringValue?.hasPrefix("Temperature: ") == true)
    }

    @Test func raisingTheMarginClearsTheFailure() async throws {
        let document = try load()
        let (nodes, _) = registries()
        let runner = try GraphRunner(document: document, registry: nodes, variables: ["margin": 5.0])
        let result = await runner.step()
        #expect(result.failedNodes.isEmpty && result.succeeded)
    }

    @Test func theAlarmFollowsTheLimit() async throws {
        let document = try load()
        let (nodes, _) = registries()
        let state = document.graph.nodes.values.first { $0.title == "State" }!
        // At time zero the sensor reads about its offset (25), under the default limit of 30.
        let quiet = await (try GraphRunner(document: document, registry: nodes)).step()
        #expect(quiet.outputs(of: state.id)?.values["result"] == .string("normal"))
        let alarm = await (try GraphRunner(document: document, registry: nodes, variables: ["limit": 10.0])).step()
        #expect(alarm.outputs(of: state.id)?.values["result"] == .string("ALARM"))
    }
}
