#if !os(tvOS) && !os(watchOS)
import NodeGraphAssistant

/// An answer to "why is this value what it is", in two parts the UI shows apart.
public struct Explanation: Sendable {
    /// What the port holds and where its inputs came from, worked out without a model. Fact.
    public var summary: String
    /// What the last run did, step by step. Computed from run values, so it is fact.
    public var trace: String
    /// A model's plain-language reading of the trace. A suggestion: it can be wrong.
    public var narration: String
}

/// Explains a value by tracing it upstream and asking a model to put the trace in words (decision
/// 229). The code finds the answer and the model only phrases it, so the explanation cannot name a
/// step that is not in the trace, and the trace is shown next to it to check.
public struct ValueExplainer: Sendable {
    public var workspace: AssistantWorkspace
    public var generator: any TextGenerator
    /// The most prompt text sent, from the model's context size, so a long trace cannot overflow it.
    public var maxPromptCharacters: Int

    /// `contextTokens` is the model's window; the prompt gets about 40% of it, at 3 characters a token.
    public init(workspace: AssistantWorkspace, generator: any TextGenerator, contextTokens: Int) {
        self.workspace = workspace
        self.generator = generator
        maxPromptCharacters = max(contextTokens * 3 * 2 / 5, 600)
    }

    /// Throws `AssistantToolError` for a port that does not exist, worded for a person.
    public func explain(_ port: String) async throws -> Explanation {
        let found = try workspace.traceUpstream(port)
        let trace = found.rendered(aliases: workspace.aliases)
        let summary = found.summary(aliases: workspace.aliases)
        let prompt = Self.prompt(port: port, summary: summary, trace: trace, limit: maxPromptCharacters)
        let narration = try await generator.narrate(prompt: prompt)
        return Explanation(summary: summary, trace: trace, narration: narration.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func prompt(port: String, summary: String, trace: String, limit: Int) -> String {
        let head = """
            A node graph was run. These facts about \(port) are correct:
            \(summary)

            In two or three plain sentences, say what this means and, if something went wrong, what \
            could be changed to fix it. Do not contradict the facts. Do not mention any node, value or \
            input that is not in the facts or the trace. Name nodes as they are named there.
            Trace, for detail:

            """
        let room = max(limit - head.count, 0)
        guard trace.count > room else { return head + trace }
        // Keep the start: it is the value being explained. Say that the rest was cut.
        return head + String(trace.prefix(room)) + "\n(the rest of the trace is left out)"
    }
}
#endif
