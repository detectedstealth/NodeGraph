import Foundation
import FoundationModels
import NodeGraphAssistant
import NodeGraphCore

/// What staged generation produced.
public struct GenerationOutcome: Sendable {
    /// The graph as the model chose it.
    public var spec: GraphSpec
    /// The proposal to preview. Nothing has been applied (decision 211).
    public var change: PendingChange
    /// What was left out and why, in words for the person.
    public var notes: [String]
}

/// A small worked example for the node-picking prompt: a task and the node types that do it.
///
/// A small model picks far better after seeing one (docs/ASSISTANT.md; decision 233). The
/// generator knows no node types itself, so a pack or the app supplies examples, and an example
/// naming a type the registry lacks is not used.
public struct GenerationExample: Hashable, Sendable {
    public var task: String
    /// Node type ids, in any order; a type can repeat when a task needs two of something.
    public var types: [String]
    /// What each type is for, in a phrase, such as "a number, the number 2, the multiply node, and
    /// a node that shows the result". It helped the on-device model noticeably.
    public var explanation: String?

    public init(task: String, types: [String], explanation: String? = nil) {
        self.task = task
        self.types = types
        self.explanation = explanation
    }
}

public enum GenerationError: Error, Hashable, Sendable, CustomStringConvertible {
    case noNodes

    public var description: String {
        switch self {
        case .noNodes: "The model did not choose any node type that exists."
        }
    }
}

/// Builds a graph in small, constrained steps so a model with a 4K context can do it (decisions 228 and 233).
///
/// 1. Pick node types, from the best matches for the request, after a worked example if one is given.
/// 2. Set each node's properties, one small request per node. Text is kept only if the request says it.
/// 3. Choose the source of each input in turn, from the links the editor would accept given the
///    ones already chosen, or none.
///
/// Because every choice is checked against the links before it, the result needs no repair: nothing
/// that was chosen is rejected later. Aliases are assigned here (`number1`, `add1`), so the model
/// cannot write an invalid one. Every request carries its own context, so the generator needs no memory.
public struct GraphGenerator: Sendable {
    public var workspace: AssistantWorkspace
    public var generator: any StructuredGenerator
    public var maxNodes: Int
    /// Worked examples for the node-picking prompt. The first usable one is shown.
    public var examples: [GenerationExample]

    public init(
        workspace: AssistantWorkspace, generator: any StructuredGenerator, maxNodes: Int = 10,
        examples: [GenerationExample] = []
    ) {
        self.workspace = workspace
        self.generator = generator
        self.maxNodes = maxNodes
        self.examples = examples
    }

    public func generate(_ request: String) async throws -> GenerationOutcome {
        var notes: [String] = []
        var specs = try await pickNodes(request, notes: &notes)
        for index in specs.indices {
            specs[index].properties = try await properties(of: specs[index], request: request, notes: &notes)
        }
        let links = try await chooseLinks(request, nodes: specs)
        let spec = GraphSpec(nodes: specs, links: links)
        let change = workspace.proposeGeneration(spec, title: "Generate: " + request)
        return GenerationOutcome(spec: spec, change: change, notes: notes)
    }

    // MARK: Stage 1

    private func pickNodes(_ request: String, notes: inout [String]) async throws -> [GraphSpec.NodeSpec] {
        let candidates = workspace.candidateNodeTypes(for: request)
        // The example's types must be choosable, or the example teaches something the schema forbids.
        let example = examples.first { example in
            example.types.allSatisfy { workspace.nodes.definition(for: NodeTypeID($0)) != nil }
        }
        var ids = candidates.map(\.typeID.rawValue)
        for type in example?.types ?? [] where !ids.contains(type) { ids.append(type) }
        var listing = candidates.map(\.rendered)
        for type in ids.dropFirst(candidates.count) {
            if let summary = workspace.searchNodes(type, limit: 1).first { listing.append(summary.rendered) }
        }
        // The wording is tuned on the real on-device model (decision 233): a longer instruction
        // ("choose the types needed to do this task...") made it pick worse, not better.
        let exampleText = example.map { example in
            let list = example.types.map { "\"\($0)\"" }.joined(separator: ", ")
            return " Example: for the task \"\(example.task)\" the list is [\(list)]" + (example.explanation.map { ": \($0)." } ?? ".")
        } ?? ""
        let prompt = """
            Task: \(request)
            Choose node types as a list.\(exampleText)
            Node types:
            \(listing.joined(separator: "\n"))
            """
        let content = try await generator.generate(
            stage: .pickNodes, prompt: prompt, schema: try StageSchemas.nodePick(types: ids, maxNodes: maxNodes))
        let chosen = try content.value([String].self)
        var counts: [String: Int] = [:]
        var specs: [GraphSpec.NodeSpec] = []
        for type in chosen.prefix(maxNodes) {
            guard ids.contains(type) else {
                notes.append("Ignored \"\(type)\": not one of the offered node types.")
                continue
            }
            let base = Self.baseAlias(of: type)
            counts[base, default: 0] += 1
            specs.append(.init(alias: "\(base)\(counts[base]!)", type: type))
        }
        if specs.isEmpty { throw GenerationError.noNodes }
        return specs
    }

    // MARK: Stage 2

    private func properties(
        of node: GraphSpec.NodeSpec, request: String, notes: inout [String]
    ) async throws -> [String: JSONValue] {
        let slots = workspace.propertySlots(type: node.type)
        guard !slots.isEmpty else { return [:] }
        let prompt = """
            Task: \(request)
            \(node.alias) is a \(node.type) node. Give a value only for a setting the task needs.
            Settings:
            \(slots.map { "- \($0.id): \($0.title)" }.joined(separator: "\n"))
            """
        let content = try await generator.generate(
            stage: .setProperties(alias: node.alias), prompt: prompt, schema: try StageSchemas.properties(for: slots))
        let decoded: [String: JSONValue]
        do {
            decoded = try JSONDecoder().decode([String: JSONValue].self, from: Data(content.jsonString.utf8))
        } catch {
            notes.append("Left \(node.alias) at its defaults: its properties could not be read.")
            return [:]
        }
        var kept: [String: JSONValue] = [:]
        let requestText = request.lowercased()
        for slot in slots {
            guard let value = decoded[slot.id], value != .null else { continue }
            // A small model fills text settings with whatever is in front of it, including the
            // prompt. Text is the person's own words, so keep it only if the request contains it.
            if slot.shape == .text, case .string(let text) = value,
               text.isEmpty || !requestText.contains(text.lowercased()) {
                if !text.isEmpty { notes.append("Left \(node.alias) \(slot.id) at its default: \"\(text)\" is not in the request.") }
                continue
            }
            kept[slot.id] = value
        }
        return kept
    }

    // MARK: Stage 3

    /// Asks for the source of each input that something could feed, one input at a time.
    ///
    /// A node's output is offered only once it means something: the node makes a value itself (no
    /// inputs), or something already feeds it. Without that rule a small model feeds an input from
    /// a node that has nothing in it yet. Because that depends on what was chosen earlier, an input
    /// is asked again in a later round if more sources have become eligible since (at most three
    /// rounds, and only when its choices changed).
    private func chooseLinks(_ request: String, nodes: [GraphSpec.NodeSpec]) async throws -> [GraphSpec.LinkSpec] {
        let candidates = workspace.linkCandidates(among: nodes)
        guard !candidates.isEmpty else { return [] }
        let listing = nodes.map { node in
            let settings = node.properties.sorted { $0.key < $1.key }.map { "\($0.key)=\(Self.text(of: $0.value))" }
            return "- \(node.alias) (\(node.type))" + (settings.isEmpty ? "" : " " + settings.joined(separator: ", "))
        }.joined(separator: "\n")
        let makesValues = Set(nodes.filter(isSource).map(\.alias))

        // Inputs in the order their nodes were picked.
        let order = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($1.alias, $0) })
        var targets: [String] = []
        for link in candidates where !targets.contains(link.to) { targets.append(link.to) }
        targets.sort { (order[Self.alias(of: $0)] ?? 0) < (order[Self.alias(of: $1)] ?? 0) }

        var kept: [GraphSpec.LinkSpec] = []
        var asked: [String: Set<String>] = [:]
        for _ in 0..<3 {
            var progressed = false
            for target in targets where !kept.contains(where: { $0.to == target }) {
                let fed = Set(kept.map { Self.alias(of: $0.to) })
                // Only links that still fit with the ones chosen so far, from a node that means something.
                let options = candidates.filter { link in
                    link.to == target
                        && (makesValues.contains(Self.alias(of: link.from)) || fed.contains(Self.alias(of: link.from)))
                        && accepts(kept + [link], nodes: nodes)
                }
                let offered = Set(options.map(\.from))
                guard !options.isEmpty, asked[target] != offered else { continue }
                asked[target] = offered
                progressed = true

                let chosenSoFar = kept.isEmpty ? "none yet" : kept.map(Self.text(of:)).joined(separator: "; ")
                let prompt = """
                    Task: \(request)
                    Nodes:
                    \(listing)
                    Links so far: \(chosenSoFar)
                    Which output should feed \(target)? Choose one, or "none" if it should not be linked. \
                    The two inputs of one node usually take different outputs.
                    """
                let content = try await generator.generate(
                    stage: .chooseSource(input: target), prompt: prompt, schema: try StageSchemas.source(from: options.map(\.from)))
                let answer = try content.value(String.self)
                if let link = options.first(where: { $0.from == answer }) { kept.append(link) }
            }
            if !progressed { break }
        }
        return kept
    }

    /// Whether a node makes a value without any input, like a constant.
    private func isSource(_ node: GraphSpec.NodeSpec) -> Bool {
        guard let definition = workspace.nodes.definition(for: NodeTypeID(node.type)) else { return false }
        return !definition.inputs.contains { $0.kind == .data } && !definition.dynamicPorts.contains { $0.direction == .input }
    }

    /// Whether `links` all compile cleanly between the nodes (properties left out: they are not link problems).
    private func accepts(_ links: [GraphSpec.LinkSpec], nodes: [GraphSpec.NodeSpec]) -> Bool {
        let compiler = GraphSpecCompiler(
            nodes: workspace.nodes, types: workspace.types, connectionValidator: workspace.connectionValidator)
        let bare = nodes.map { GraphSpec.NodeSpec(alias: $0.alias, type: $0.type) }
        return compiler.compile(GraphSpec(nodes: bare, links: links)).isClean
    }

    // MARK: Text

    static func text(of link: GraphSpec.LinkSpec) -> String { "\(link.from) -> \(link.to)" }

    /// The alias in `alias.port`.
    static func alias(of reference: String) -> String { String(reference.split(separator: ".").first ?? "") }

    /// A property value as the JSON a model would write it.
    static func text(of value: JSONValue) -> String {
        (try? JSONEncoder().encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "?"
    }

    /// `math.add` becomes `add`, `util.number` becomes `number`; letters and digits only.
    static func baseAlias(of type: String) -> String {
        let last = type.split(separator: ".").last.map(String.init) ?? type
        let cleaned = last.filter { $0.isLetter || $0.isNumber }
        return cleaned.isEmpty ? "node" : cleaned
    }
}
