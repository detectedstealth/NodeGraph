import Foundation
import Testing
import NodeGraphAssistant
import NodeGraphCore
import NodeGraphNodes
@testable import NodeGraphAI

/// Checks the harness itself with proposals written by hand, so it can be trusted before a model
/// is judged by it. Runs in the normal test run.
@Suite struct EvalHarnessTests {
    private let environment = EvalEnvironment()

    private func judge(_ task: EvalTask, answer: GraphSpec) async throws -> [EvalVerdict] {
        let editor = try environment.startingEditor(for: task)
        let space = AssistantWorkspace(editor: editor)
        let change = space.proposeGeneration(answer, title: task.name)
        let outcome = GenerationOutcome(spec: answer, change: change, notes: [])
        return await environment.judge(outcome, for: task, startingFrom: editor)
    }

    private func node(_ alias: String, _ type: String, _ properties: [String: JSONValue] = [:]) -> GraphSpec.NodeSpec {
        .init(alias: alias, type: type, properties: properties)
    }

    @Test func rightAnswerPassesEveryCheck() async throws {
        let task = try #require(GoldenTasks.generate.first { $0.name == "add two numbers" })
        let answer = GraphSpec(
            nodes: [node("a", "util.number", ["value": .int(2)]), node("b", "util.number", ["value": .int(3)]), node("sum", "math.add"), node("show", "util.watch")],
            links: [.init(from: "a.value", to: "sum.a"), .init(from: "b.value", to: "sum.b"), .init(from: "sum.result", to: "show.value")])
        let verdicts = try await judge(task, answer: answer)
        #expect(verdicts.allSatisfy { $0.passed }, "\(verdicts.filter { !$0.passed })")
    }

    @Test func wrongValueAndStrayNodeFail() async throws {
        let task = try #require(GoldenTasks.generate.first { $0.name == "add two numbers" })
        let answer = GraphSpec(
            nodes: [node("a", "util.number", ["value": .int(2)]), node("b", "util.number", ["value": .int(9)]), node("sum", "math.add"), node("lost", "util.watch")],
            links: [.init(from: "a.value", to: "sum.a"), .init(from: "b.value", to: "sum.b")])
        let failed = try await judge(task, answer: answer).filter { !$0.passed }.map(\.check)
        #expect(failed.contains(.publishesNumber(5)))
        #expect(failed.contains(.noStrayNodes))
        #expect(!failed.contains(.usesTypes(["math.add"])))
    }

    @Test func bothAnswersFromUseAreAcceptedForTheJoinTasks() async throws {
        // What the hosted model returned, as specs: a chain of two concats, and one join with a separator.
        let chain = GraphSpec(
            nodes: [node("a", "util.string", ["value": .string("Hello")]), node("b", "util.string", ["value": .string(" ")]),
                    node("c", "util.string", ["value": .string("world")]), node("x", "string.concat"), node("y", "string.concat")],
            links: [.init(from: "a.value", to: "x.a"), .init(from: "b.value", to: "x.b"),
                    .init(from: "x.result", to: "y.a"), .init(from: "c.value", to: "y.b")])
        let first = try #require(GoldenTasks.generate.first { $0.name == "join with a space (concat)" })
        var verdicts = try await judge(first, answer: chain)
        // The last concat's output has no reader, which the checks do not mind; the final node is not a stray.
        #expect(verdicts.allSatisfy { $0.passed }, "\(verdicts.filter { !$0.passed })")

        var join = node("j", "string.join", ["separator": .string(" ")])
        join.portCounts = ["in": 3]
        let one = GraphSpec(
            nodes: [node("a", "util.string", ["value": .string("Hello")]), node("b", "util.string", ["value": .string("World")]), join, node("w", "util.watch")],
            links: [.init(from: "a.value", to: "j.in_1"), .init(from: "b.value", to: "j.in_2"), .init(from: "j.result", to: "w.value")])
        let second = try #require(GoldenTasks.generate.first { $0.name == "join with a space (join)" })
        verdicts = try await judge(second, answer: one)
        #expect(verdicts.allSatisfy { $0.passed }, "\(verdicts.filter { !$0.passed })")
    }

    @Test func emptyProposalFailsNoErrors() async throws {
        let task = try #require(GoldenTasks.generate.first { $0.name == "show a number" })
        let verdicts = try await judge(task, answer: GraphSpec())
        #expect(verdicts.first { $0.check == .noErrors }?.passed == false)
    }

    @Test func startingGraphIsKeptAndLinkedTo() async throws {
        let task = try #require(GoldenTasks.generate.first { $0.name == "link a log to an existing node" })
        // The model's answer is applied on top of the starting graph, so a lone new log is not linked.
        let verdicts = try await judge(task, answer: GraphSpec(nodes: [node("log", "util.log")]))
        let failed = verdicts.filter { !$0.passed }.map(\.check)
        #expect(failed == [.linksTypes(from: "array.append", to: "util.log")])
    }

    @Test func everyGoldenTaskStartsFromAGraphThatCompiles() throws {
        for task in GoldenTasks.generate { _ = try environment.startingEditor(for: task) }
    }

    private struct FixedNarrator: TextGenerator {
        var text: String
        func narrate(prompt: String) async throws -> String { text }
    }

    @Test func aNarrationThatCarriesTheFactsPassesExplainChecks() async throws {
        let task = try #require(GoldenExplainTasks.all.first { $0.name == "a sum" })
        let attempt = await EvalRunner().attempt(task, narrator: FixedNarrator(text: "It is 12 because four plus eight."), contextTokens: 4_096)
        #expect(attempt.passed, "\(attempt.verdicts.filter { !$0.passed })")
    }

    @Test func aNarrationThatMissesOrInventsFailsExplainChecks() async throws {
        let task = try #require(GoldenExplainTasks.all.first { $0.name == "a failed division" })
        let attempt = await EvalRunner().attempt(task, narrator: FixedNarrator(text: "The result is 10 and all is well."), contextTokens: 4_096)
        let failed = attempt.verdicts.filter { !$0.passed }.map(\.check)
        #expect(failed == [.narrationMentions("zero"), .narrationAvoids("result is 10")])
        let silent = await EvalRunner().attempt(task, narrator: FixedNarrator(text: "  "), contextTokens: 4_096)
        #expect(silent.verdicts.contains { $0.check == .narrationNotEmpty && !$0.passed })
    }

    @Test func everyExplainTaskNamesAPortThatExistsAndThePromptCarriesTheFacts() async throws {
        for task in GoldenExplainTasks.all {
            let space = try await environment.ranWorkspace(for: task)
            let explanation = try await ValueExplainer(workspace: space, generator: FixedNarrator(text: "x"), contextTokens: 4_096).explain(task.port)
            for phrase in task.mustMention {
                // The computed summary is what the model is given; the phrases come from facts in it or the trace.
                #expect((explanation.summary + explanation.trace).lowercased().contains(phrase.lowercased()), "\(task.name): \(phrase)")
            }
        }
    }

    @Test func reportListsFailedChecks() {
        let task = EvalTask("demo", request: "x", checks: [.noErrors])
        let good = EvalAttempt(verdicts: [.init(check: .noErrors, passed: true)], failure: nil, seconds: 1, nodes: ["util.number"], notes: [])
        let bad = EvalAttempt(verdicts: [.init(check: .noErrors, passed: false, detail: "boom")], failure: nil, seconds: 3, nodes: [], notes: [])
        let text = EvalRunner.markdown(model: "Test", promptVersion: "p1", date: "2026-11-13", results: [(task, [good, bad])])
        #expect(text.contains("| demo | 1/2 | 2.0 |"))
        #expect(text.contains("- demo #2: no errors (boom)"))
        #expect(text.contains("Total: 1/2"))
    }
}

/// Runs the golden tasks against real providers. Not part of the normal run: it needs the models
/// and, for hosted ones, a key; answers vary, so each task can be repeated.
///
///     NODEGRAPH_EVAL=apple swift test --package-path Packages/NodeGraphAI --filter RealProviderEval
///
/// - `NODEGRAPH_EVAL`: providers, separated by `;`: `apple`, `claude` or `claude:<model>`, and
///   `compat:<base URL>@<model>` for an OpenAI-compatible server.
/// - `NODEGRAPH_EVAL_KEY`: API key for the hosted providers (else the Keychain entry the app saved).
/// - `NODEGRAPH_EVAL_RUNS`: attempts per task (default 1). `NODEGRAPH_EVAL_ONLY`: a task name fragment.
/// - `NODEGRAPH_EVAL_PROMPT`: a label for the prompt version being judged, written into the report.
/// - `NODEGRAPH_EVAL_OUT`: a file to append the markdown report to (it is always printed).
@Suite struct RealProviderEval {
    static let environment = ProcessInfo.processInfo.environment
    static let enabled = environment["NODEGRAPH_EVAL"] != nil

    /// Parses `NODEGRAPH_EVAL` into endpoints; a word it does not know is reported, not skipped.
    static func endpoints(from text: String) -> [ModelEndpoint] {
        text.split(separator: ";").compactMap { part in
            let item = part.trimmingCharacters(in: .whitespaces)
            if item == "apple" { return .appleOnDevice }
            if item == "claude" { return .claude() }
            if item.hasPrefix("claude:") { return .claude(model: String(item.dropFirst(7))) }
            if item.hasPrefix("compat:") {
                let rest = item.dropFirst(7)
                if let at = rest.lastIndex(of: "@"), let url = URL(string: String(rest[..<at])) {
                    return .openAICompatible(
                        name: "\(rest[rest.index(after: at)...])", baseURL: url, model: String(rest[rest.index(after: at)...]),
                        contextTokens: 32_768, keyAccount: "eval")
                }
            }
            print("EVAL does not know the provider \"\(item)\"")
            return nil
        }
    }

    @Test(.enabled(if: RealProviderEval.enabled))
    func goldenTasksOnEachProvider() async throws {
        let wanted = Self.environment["NODEGRAPH_EVAL"] ?? ""
        let runs = max(1, Int(Self.environment["NODEGRAPH_EVAL_RUNS"] ?? "") ?? 1)
        let only = Self.environment["NODEGRAPH_EVAL_ONLY"]
        let tasks = GoldenTasks.generate.filter { only == nil || $0.name.localizedCaseInsensitiveContains(only!) }
        let secrets = InMemorySecretStore()
        let keychain = KeychainSecretStore()
        let key = Self.environment["NODEGRAPH_EVAL_KEY"]
        for account in ["claude", "eval"] {
            try secrets.setSecret(key ?? keychain.secret(for: account), for: account)
        }
        let date = ISO8601DateFormatter().string(from: Date()).prefix(10)
        let runner = EvalRunner()

        for endpoint in Self.endpoints(from: wanted) {
            guard let generator = endpoint.makeGenerator(secrets: secrets) else {
                print("EVAL \(endpoint.name) unavailable: \(endpoint.availability(secrets: secrets).summary)")
                continue
            }
            // The same choices the demo panel makes, so the eval judges what a person would get.
            let small = endpoint.contextTokens <= 4_096
            var results: [(task: EvalTask, attempts: [EvalAttempt])] = []
            for task in tasks {
                var attempts: [EvalAttempt] = []
                for _ in 0..<runs {
                    attempts.append(await runner.attempt(task) { space in
                        try await GraphGenerator(
                            workspace: space, generator: generator, maxNodes: small ? 8 : 12,
                            examples: Self.examples, allowsRepeatedOperations: !small,
                            strategy: small ? .staged : .oneShot,
                            digestTokenBudget: min(max(endpoint.contextTokens / 5, 500), 6_000)
                        ).generate(task.request)
                    })
                }
                results.append((task, attempts))
            }
            var explainResults: [(task: EvalTask, attempts: [EvalAttempt])] = []
            var narrations: [String] = []
            for task in GoldenExplainTasks.all where only == nil || task.name.localizedCaseInsensitiveContains(only!) {
                var attempts: [EvalAttempt] = []
                for _ in 0..<runs {
                    let attempt = await runner.attempt(task, narrator: generator, contextTokens: endpoint.contextTokens)
                    narrations += attempt.notes.map { "\(task.name): \($0)" }
                    attempts.append(attempt)
                }
                explainResults.append((EvalTask("explain: " + task.name, request: "", checks: []), attempts))
            }
            results += explainResults
            let label = endpoint.modelName.map { "\(endpoint.name) (\($0))" } ?? endpoint.name
            let report = EvalRunner.markdown(
                model: label, promptVersion: Self.environment["NODEGRAPH_EVAL_PROMPT"] ?? "unlabelled",
                date: String(date), results: results)
            print("EVAL\n\(report)")
            if !narrations.isEmpty { print("EVAL narrations:\n" + narrations.map { "- " + $0 }.joined(separator: "\n")) }
            if let path = Self.environment["NODEGRAPH_EVAL_OUT"] {
                let handle = FileHandle(forWritingAtPath: path) ?? {
                    FileManager.default.createFile(atPath: path, contents: nil)
                    return FileHandle(forWritingAtPath: path)
                }()
                _ = try? handle?.seekToEnd()
                try? handle?.write(contentsOf: Data((report + "\n\n").utf8))
                try? handle?.close()
            }
        }
    }

    /// The panel's worked examples (`AssistantPanel.generationExamples`), repeated here because the
    /// panel is in the app target.
    static let examples = [
        GenerationExample(
            task: "double a number and show it", types: ["util.number", "util.number", "math.multiply", "util.watch"],
            explanation: "a number, the number 2, the multiply node, and a node that shows the result"),
        GenerationExample(
            task: "make a number with the value 7", types: ["util.number"],
            explanation: "just the number node, nothing else"),
    ]
}
