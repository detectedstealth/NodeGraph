import Foundation
import NodeGraphAssistant
import NodeGraphCore
import NodeGraphNodes
@testable import NodeGraphAI

/// What a golden task expects of the graph a model produced. Checks look at the graph that results
/// from applying the proposal (and running it), never at the model's wording, so they hold for any
/// provider and any prompt.
enum EvalCheck: Hashable, Sendable {
    /// The compiler and the editor rejected nothing.
    case noErrors
    /// The result holds at least one node of each type.
    case usesTypes([String])
    /// The result holds none of these types (padding the model is known to add).
    case avoidsTypes([String])
    /// At most this many nodes were added.
    case addsAtMost(Int)
    /// When more than one node was added, every added node is linked to something.
    case noStrayNodes
    /// The graph runs and no node fails.
    case runsCleanly
    /// Some node publishes this number (within 1e-9) when the graph runs.
    case publishesNumber(Double)
    /// Some node publishes this string when the graph runs.
    case publishesString(String)
    /// A link goes from a node of the first type to a node of the second.
    case linksTypes(from: String, to: String)
    /// Every node of the starting graph is still there and unchanged in type.
    case keepsStartingNodes

    var summary: String {
        switch self {
        case .noErrors: "no errors"
        case .usesTypes(let types): "uses \(types.joined(separator: ", "))"
        case .avoidsTypes(let types): "avoids \(types.joined(separator: ", "))"
        case .addsAtMost(let count): "adds at most \(count) nodes"
        case .noStrayNodes: "no stray nodes"
        case .runsCleanly: "runs cleanly"
        case .publishesNumber(let value): "publishes \(value)"
        case .publishesString(let text): "publishes \"\(text)\""
        case .linksTypes(let from, let to): "links \(from) to \(to)"
        case .keepsStartingNodes: "keeps the starting nodes"
        }
    }
}

/// A prompt, optionally a graph to start from, and what a good answer looks like.
struct EvalTask: Sendable {
    var name: String
    var request: String
    /// A graph the document already holds when the request is made.
    var start: GraphSpec?
    var checks: [EvalCheck]

    init(_ name: String, request: String, start: GraphSpec? = nil, checks: [EvalCheck]) {
        self.name = name
        self.request = request
        self.start = start
        self.checks = checks
    }
}

/// How one check came out on one attempt.
struct EvalVerdict: Sendable {
    var check: EvalCheck
    var passed: Bool
    var detail: String?
}

/// One attempt at one task.
struct EvalAttempt: Sendable {
    var verdicts: [EvalVerdict]
    /// The provider's failure, when it produced no proposal at all.
    var failure: String?
    var seconds: Double
    var nodes: [String]
    var notes: [String]

    var passed: Bool { failure == nil && verdicts.allSatisfy(\.passed) }
}

/// Everything the harness needs besides a model: the registry and the way to judge a proposal.
struct EvalEnvironment: Sendable {
    var nodes: NodeRegistry
    var types: TypeRegistry

    init() {
        var nodes = NodeRegistry()
        var types = TypeRegistry()
        StandardPack.register(nodes: &nodes, types: &types)
        self.nodes = nodes
        self.types = types
    }

    /// A fresh editor holding the task's starting graph.
    func startingEditor(for task: EvalTask) throws -> GraphEditor {
        let editor = GraphEditor(nodes: nodes, types: types)
        guard let start = task.start else { return editor }
        let compiler = GraphSpecCompiler(nodes: nodes, types: types, connectionValidator: editor.connectionValidator)
        let compilation = compiler.compile(start)
        guard compilation.isClean else {
            throw EvalSetupError("The starting graph of \"\(task.name)\" does not compile: \(compilation.errors)")
        }
        try editor.apply(try compilation.pasteCommand(into: editor).command)
        return editor
    }

    /// Judges a proposal made against `editor` (still holding only the starting graph).
    func judge(_ outcome: GenerationOutcome, for task: EvalTask, startingFrom editor: GraphEditor) async -> [EvalVerdict] {
        let startNodes = editor.graph.nodes
        var applyError: String?
        if !outcome.change.isEmpty {
            do { try outcome.change.apply(to: editor) } catch { applyError = "\(error)" }
        }
        let graph = editor.graph
        let space = AssistantWorkspace(editor: editor)
        let report = try? await space.run()
        let added = graph.nodes.values.filter { startNodes[$0.id] == nil }
        let linked = Set(graph.links.values.flatMap { [$0.source.node, $0.target.node] })

        return task.checks.map { check in
            switch check {
            case .noErrors:
                let problems = outcome.change.errors + (applyError.map { [$0] } ?? [])
                return EvalVerdict(check: check, passed: problems.isEmpty && !outcome.change.isEmpty,
                                   detail: outcome.change.isEmpty ? "the proposal is empty" : problems.first)
            case .usesTypes(let types):
                let missing = types.filter { type in !graph.nodes.values.contains { $0.typeID.rawValue == type } }
                return EvalVerdict(check: check, passed: missing.isEmpty, detail: missing.isEmpty ? nil : "missing \(missing.joined(separator: ", "))")
            case .avoidsTypes(let types):
                let found = types.filter { type in added.contains { $0.typeID.rawValue == type } }
                return EvalVerdict(check: check, passed: found.isEmpty, detail: found.isEmpty ? nil : "has \(found.joined(separator: ", "))")
            case .addsAtMost(let count):
                return EvalVerdict(check: check, passed: added.count <= count, detail: added.count <= count ? nil : "added \(added.count)")
            case .noStrayNodes:
                let strays = added.filter { !linked.contains($0.id) }
                let applies = added.count > 1
                return EvalVerdict(check: check, passed: !applies || strays.isEmpty,
                                   detail: strays.isEmpty ? nil : "unlinked: \(strays.map { $0.typeID.rawValue }.joined(separator: ", "))")
            case .runsCleanly:
                guard let report else { return EvalVerdict(check: check, passed: false, detail: "the graph cannot run") }
                return EvalVerdict(check: check, passed: report.failures.isEmpty, detail: report.failures.values.first)
            case .publishesNumber(let expected):
                let published = Self.published(in: report)
                let hit = published.contains { ($0.numberValue.map { abs($0 - expected) < 1e-9 }) ?? false }
                return EvalVerdict(check: check, passed: hit, detail: hit ? nil : "no node published it")
            case .publishesString(let expected):
                let hit = Self.published(in: report).contains { $0.stringValue == expected }
                return EvalVerdict(check: check, passed: hit, detail: hit ? nil : "no node published it")
            case .linksTypes(let from, let to):
                let hit = graph.links.values.contains {
                    graph.nodes[$0.source.node]?.typeID.rawValue == from && graph.nodes[$0.target.node]?.typeID.rawValue == to
                }
                return EvalVerdict(check: check, passed: hit, detail: hit ? nil : "no such link")
            case .keepsStartingNodes:
                let kept = startNodes.values.allSatisfy { graph.nodes[$0.id]?.typeID == $0.typeID }
                return EvalVerdict(check: check, passed: kept, detail: kept ? nil : "a starting node is gone")
            }
        }
    }

    private static func published(in report: RunReport?) -> [GraphValue] {
        guard let report else { return [] }
        return report.values.nodes.values.flatMap { $0.values }
    }
}

struct EvalSetupError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

/// Runs the golden tasks against one provider and renders the results.
struct EvalRunner: Sendable {
    var environment = EvalEnvironment()

    /// One attempt: builds the graph with `builder` and judges it.
    func attempt(_ task: EvalTask, build: @Sendable (AssistantWorkspace) async throws -> GenerationOutcome) async -> EvalAttempt {
        let started = Date()
        do {
            let editor = try environment.startingEditor(for: task)
            let space = AssistantWorkspace(editor: editor)
            let outcome = try await build(space)
            let verdicts = await environment.judge(outcome, for: task, startingFrom: editor)
            let names = outcome.spec.nodes.map(\.type)
            return EvalAttempt(verdicts: verdicts, failure: nil, seconds: Date().timeIntervalSince(started), nodes: names, notes: outcome.notes)
        } catch {
            return EvalAttempt(verdicts: [], failure: "\(error)", seconds: Date().timeIntervalSince(started), nodes: [], notes: [])
        }
    }

    /// A markdown section for ASSISTANT.md: one row per task, then the failing checks.
    static func markdown(
        model: String, promptVersion: String, date: String, results: [(task: EvalTask, attempts: [EvalAttempt])]
    ) -> String {
        var lines = ["### \(model), prompts \(promptVersion), \(date)", "", "| Task | Passed | Seconds | Nodes (last attempt) |", "| --- | --- | --- | --- |"]
        var failures: [String] = []
        for (task, attempts) in results {
            let passed = attempts.filter(\.passed).count
            let seconds = attempts.isEmpty ? 0 : attempts.map(\.seconds).reduce(0, +) / Double(attempts.count)
            lines.append("| \(task.name) | \(passed)/\(attempts.count) | \(String(format: "%.1f", seconds)) | \(attempts.last?.nodes.joined(separator: ", ") ?? "") |")
            for (index, attempt) in attempts.enumerated() where !attempt.passed {
                if let failure = attempt.failure {
                    failures.append("- \(task.name) #\(index + 1): provider failed: \(failure)")
                }
                for verdict in attempt.verdicts where !verdict.passed {
                    failures.append("- \(task.name) #\(index + 1): \(verdict.check.summary)" + (verdict.detail.map { " (\($0))" } ?? ""))
                }
            }
        }
        let total = results.flatMap(\.attempts)
        lines.append("")
        lines.append("Total: \(total.filter(\.passed).count)/\(total.count) attempts passed.")
        if !failures.isEmpty { lines += ["", "Failed checks:"] + failures }
        return lines.joined(separator: "\n")
    }
}

/// The golden tasks for Generate. Small ones every model should manage, then ones that need
/// arithmetic through a run, text, an array, and an edit of a graph that already exists.
enum GoldenTasks {
    static let generate: [EvalTask] = [
        EvalTask("show a number", request: "show a number", checks: [.noErrors, .addsAtMost(2), .runsCleanly]),
        EvalTask("one string node", request: "create a string with the value hello",
                 checks: [.noErrors, .addsAtMost(1), .publishesString("hello")]),
        EvalTask("add two numbers", request: "add 2 and 3 and show the sum",
                 checks: [.noErrors, .usesTypes(["math.add"]), .noStrayNodes, .runsCleanly, .publishesNumber(5)]),
        EvalTask("multiply by three", request: "multiply 4 by three and show the result",
                 checks: [.noErrors, .usesTypes(["math.multiply"]), .noStrayNodes, .runsCleanly, .publishesNumber(12)]),
        EvalTask("join text", request: "join the text hello and world with a space between and show it",
                 checks: [.noErrors, .noStrayNodes, .runsCleanly, .publishesString("hello world")]),
        EvalTask("running total", request: "keep a running total of a number",
                 checks: [.noErrors, .usesTypes(["math.accumulate"]), .noStrayNodes]),
        EvalTask("append to array", request: "add 2 and 3 together then append the sum to an array containing [1, 2, 3, 4]",
                 checks: [.noErrors, .usesTypes(["math.add", "array.append"]), .noStrayNodes, .runsCleanly]),
        EvalTask(
            "link a log to an existing node", request: "connect a log to the append node",
            start: GraphSpec(
                nodes: [
                    .init(alias: "list", type: "array.make"),
                    .init(alias: "item", type: "util.number"),
                    .init(alias: "append", type: "array.append"),
                ],
                links: [.init(from: "list.result", to: "append.array"), .init(from: "item.value", to: "append.value")]),
            checks: [.noErrors, .keepsStartingNodes, .addsAtMost(1), .usesTypes(["util.log"]), .linksTypes(from: "array.append", to: "util.log")]),
    ]
}
