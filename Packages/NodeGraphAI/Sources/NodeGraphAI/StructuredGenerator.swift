import FoundationModels

/// The steps of staged generation, named so a generator can log, route or script by step.
public enum GenerationStage: Hashable, Sendable {
    case pickNodes
    case setProperties(alias: String)
    /// Choosing what feeds one input, written `alias.port`.
    case chooseSource(input: String)
}

/// Produces one piece of schema-constrained output. The generation loop depends on this, not on a
/// session, so tests can script the answers and a router can pick a model per stage (decision 228).
public protocol StructuredGenerator: Sendable {
    func generate(stage: GenerationStage, prompt: String, schema: GenerationSchema) async throws -> GeneratedContent
}

/// Produces free text, for narrating facts the code has already established.
public protocol TextGenerator: Sendable {
    func narrate(prompt: String) async throws -> String
}

/// Answers each stage with a fresh `LanguageModelSession`.
///
/// Every prompt carries all the context its stage needs, so no session is reused: a 4K model
/// would otherwise fill up with earlier stages and repair rounds.
public struct SessionGenerator: StructuredGenerator, TextGenerator {
    private let makeSession: @Sendable () -> LanguageModelSession

    public init(makeSession: @escaping @Sendable () -> LanguageModelSession) {
        self.makeSession = makeSession
    }

    static let instructions = "You help with node graphs. Use only the options and facts you are given."

    /// Apple's on-device model.
    public static var onDevice: SessionGenerator {
        SessionGenerator { LanguageModelSession(model: SystemLanguageModel.default, instructions: instructions) }
    }

    public func generate(stage: GenerationStage, prompt: String, schema: GenerationSchema) async throws -> GeneratedContent {
        try await makeSession().respond(to: prompt, schema: schema).content
    }

    public func narrate(prompt: String) async throws -> String {
        try await makeSession().respond(to: prompt).content
    }
}
